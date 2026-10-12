CREATE OR REPLACE FUNCTION public.reassign_shift_shortage(_shift_id uuid, _mode text, _staff_id uuid DEFAULT NULL, _reason text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE _s public.shifts; _profile uuid := public.current_profile_id(); _short numeric;
  _staff uuid[]; _n int; _each numeric; _i int; _amt numeric; _old text;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.is_super_admin() OR public.has_permission('expenses.approve') OR public.can_absorb_shortage()) THEN
    RAISE EXCEPTION 'Not authorized'; END IF;
  SELECT * INTO _s FROM public.shifts WHERE id=_shift_id AND company_id=public.current_company_id() FOR UPDATE;
  IF _s.id IS NULL THEN RAISE EXCEPTION 'Shift not found'; END IF;
  IF _s.status <> 'closed' THEN RAISE EXCEPTION 'Shift must be closed'; END IF;
  PERFORM public.assert_period_open(_s.company_id, (_s.closed_at)::date);
  _short := round(GREATEST(-COALESCE(_s.variance,0),0),2);
  IF _short <= 0 THEN RAISE EXCEPTION 'This shift has no shortage'; END IF;
  IF _mode NOT IN ('split','staff','venue') THEN RAISE EXCEPTION 'Invalid bearer'; END IF;
  IF _reason IS NULL OR char_length(btrim(_reason)) < 8
     OR char_length(regexp_replace(_reason, '[^A-Za-zء-ي]', '', 'g')) < 5 THEN
    RAISE EXCEPTION 'A clear written reason is required'; END IF;
  IF EXISTS (SELECT 1 FROM public.staff_penalties WHERE shift_id=_shift_id AND reason LIKE 'عجز درج الوردية%' AND (is_settled OR payroll_id IS NOT NULL)) THEN
    RAISE EXCEPTION 'Shortage deductions were already paid in payroll'; END IF;
  _old := _s.shortage_resolution;
  DELETE FROM public.staff_penalties WHERE shift_id=_shift_id AND reason LIKE 'عجز درج الوردية%';
  IF _mode='staff' THEN
    IF _staff_id IS NULL OR (NOT EXISTS (SELECT 1 FROM public.shift_staff WHERE shift_id=_shift_id AND staff_id=_staff_id) AND _staff_id IS DISTINCT FROM _s.user_id) THEN
      RAISE EXCEPTION 'Selected staff member is not on this shift'; END IF;
    INSERT INTO public.staff_penalties(company_id,staff_id,amount,reason,shift_id,created_by)
    VALUES(_s.company_id,_staff_id,_short,'عجز درج الوردية',_shift_id,_profile);
  ELSIF _mode='split' THEN
    SELECT array_agg(DISTINCT x) INTO _staff FROM (SELECT staff_id x FROM public.shift_staff WHERE shift_id=_shift_id UNION SELECT _s.user_id) q;
    _n := array_length(_staff,1); _each := floor(_short/_n*100)/100;
    FOR _i IN 1.._n LOOP
      _amt := CASE WHEN _i=_n THEN round(_short-_each*(_n-1),2) ELSE _each END;
      INSERT INTO public.staff_penalties(company_id,staff_id,amount,reason,shift_id,created_by)
      VALUES(_s.company_id,_staff[_i],_amt,'عجز درج الوردية (موزع)',_shift_id,_profile);
    END LOOP;
  END IF;
  UPDATE public.shifts SET shortage_resolution=_mode, shortage_staff_id=CASE WHEN _mode='staff' THEN _staff_id END, updated_at=now() WHERE id=_shift_id;
  PERFORM public.log_audit('shift.shortage_reassign','pos','shifts',_shift_id,
    jsonb_build_object('mode',_old,'staff',_s.shortage_staff_id), jsonb_build_object('mode',_mode,'staff',_staff_id,'amount',_short), btrim(_reason), _s.branch_id);
  RETURN jsonb_build_object('shortage',_short,'mode',_mode);
END $$;
REVOKE EXECUTE ON FUNCTION public.reassign_shift_shortage(uuid,text,uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reassign_shift_shortage(uuid,text,uuid,text) TO authenticated;