CREATE OR REPLACE FUNCTION public.close_shift_handover(_shift_id uuid, _closing_cash numeric, _retained_float numeric, _shortage_mode text DEFAULT NULL::text, _shortage_staff_id uuid DEFAULT NULL::uuid, _notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _s public.shifts; _profile uuid := public.current_profile_id(); _expenses numeric;
  _expected numeric; _short numeric; _staff uuid[]; _n int; _each numeric; _i int; _amt numeric;
BEGIN
  SELECT * INTO _s FROM public.shifts WHERE id = _shift_id;
  IF _s.id IS NULL THEN RAISE EXCEPTION 'Shift not found'; END IF;
  IF _closing_cash IS NULL OR _closing_cash < 0 THEN RAISE EXCEPTION 'Counted cash is required'; END IF;
  IF _retained_float IS NULL OR _retained_float < 0 OR _retained_float > _closing_cash THEN
    RAISE EXCEPTION 'Retained float must be between 0 and the counted cash';
  END IF;

  _expenses := public.shift_expense_total(_shift_id);
  PERFORM public.close_shift(_shift_id, _closing_cash, _notes);
  SELECT expected_cash INTO _expected FROM public.shifts WHERE id = _shift_id;
  _expected := round(_expected - _expenses, 2);
  _short := round(_expected - _closing_cash, 2);

  IF _short > 0 THEN
    IF _shortage_mode IS NULL OR _shortage_mode NOT IN ('split','staff','venue') THEN
      RAISE EXCEPTION 'Shortage must be attributed';
    END IF;
    IF _shortage_mode = 'venue' AND NOT (public.is_super_admin() OR public.has_permission('expenses.approve') OR public.can_absorb_shortage()) THEN
      RAISE EXCEPTION 'Only a manager can approve venue-absorbed shortage';
    END IF;
    IF _shortage_mode = 'venue' AND (
      char_length(btrim(COALESCE(_notes, ''))) < 8
      OR char_length(regexp_replace(COALESCE(_notes, ''), '[^A-Za-zء-ي]', '', 'g')) < 5
    ) THEN
      RAISE EXCEPTION 'A clear written reason is required for venue-absorbed shortage';
    END IF;
    IF _shortage_mode = 'staff' THEN
      IF NOT EXISTS (SELECT 1 FROM public.shift_staff WHERE shift_id = _shift_id AND staff_id = _shortage_staff_id)
         AND _shortage_staff_id IS DISTINCT FROM _s.user_id THEN
        RAISE EXCEPTION 'Selected staff member is not on this shift';
      END IF;
      INSERT INTO public.staff_penalties (company_id, staff_id, amount, reason, shift_id, created_by)
      VALUES (_s.company_id, _shortage_staff_id, _short, 'عجز درج الوردية', _shift_id, _profile);
    ELSIF _shortage_mode = 'split' THEN
      SELECT array_agg(DISTINCT x) INTO _staff FROM (
        SELECT staff_id AS x FROM public.shift_staff WHERE shift_id = _shift_id
        UNION SELECT _s.user_id) q;
      _n := array_length(_staff,1);
      _each := floor(_short / _n * 100) / 100;
      FOR _i IN 1.._n LOOP
        _amt := CASE WHEN _i = _n THEN round(_short - _each * (_n - 1), 2) ELSE _each END;
        INSERT INTO public.staff_penalties (company_id, staff_id, amount, reason, shift_id, created_by)
        VALUES (_s.company_id, _staff[_i], _amt, 'عجز درج الوردية (موزع)', _shift_id, _profile);
      END LOOP;
    END IF;
  END IF;

  UPDATE public.shifts SET expected_cash = _expected, variance = round(_closing_cash - _expected, 2),
    shift_expenses = _expenses, retained_float = round(_retained_float,2),
    cash_drop = round(_closing_cash - _retained_float, 2),
    shortage_resolution = CASE WHEN _short > 0 THEN _shortage_mode END,
    shortage_staff_id = CASE WHEN _short > 0 AND _shortage_mode = 'staff' THEN _shortage_staff_id END
  WHERE id = _shift_id;

  PERFORM public.log_audit('shift.handover','pos','shifts',_shift_id,NULL,
    jsonb_build_object('expected',_expected,'counted',_closing_cash,'retained',_retained_float,
      'drawer_expenses',_expenses,'shortage',GREATEST(_short,0),'mode',_shortage_mode),_notes,_s.branch_id);
  RETURN jsonb_build_object('expected',_expected,'shortage',GREATEST(_short,0),'cash_drop',round(_closing_cash - _retained_float,2));
END $function$;