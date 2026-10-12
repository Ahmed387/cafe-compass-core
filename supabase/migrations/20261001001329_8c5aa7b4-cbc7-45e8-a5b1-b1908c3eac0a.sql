-- ===== Schema additions =====
ALTER TABLE public.shifts
  ADD COLUMN IF NOT EXISTS cash_drop numeric,
  ADD COLUMN IF NOT EXISTS retained_float numeric,
  ADD COLUMN IF NOT EXISTS shift_expenses numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS shortage_resolution text,
  ADD COLUMN IF NOT EXISTS shortage_staff_id uuid REFERENCES public.user_profiles(id);
ALTER TABLE public.expenses ADD COLUMN IF NOT EXISTS shift_id uuid REFERENCES public.shifts(id);
ALTER TABLE public.staff_penalties ADD COLUMN IF NOT EXISTS shift_id uuid REFERENCES public.shifts(id);
ALTER TABLE public.order_refunds
  ADD COLUMN IF NOT EXISTS fault text,
  ADD COLUMN IF NOT EXISTS blamed_staff_id uuid REFERENCES public.user_profiles(id);
CREATE INDEX IF NOT EXISTS expenses_shift_idx ON public.expenses(shift_id);

CREATE TABLE public.shift_staff (
  shift_id uuid NOT NULL REFERENCES public.shifts(id) ON DELETE CASCADE,
  staff_id uuid NOT NULL REFERENCES public.user_profiles(id),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  added_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (shift_id, staff_id)
);
GRANT SELECT ON public.shift_staff TO authenticated;
GRANT ALL ON public.shift_staff TO service_role;
ALTER TABLE public.shift_staff ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Branch staff can view shift roster" ON public.shift_staff FOR SELECT TO authenticated
USING (EXISTS (SELECT 1 FROM public.shifts s WHERE s.id = shift_id AND public.can_access_branch(s.branch_id)));

-- ===== Helpers =====
CREATE OR REPLACE FUNCTION public.shift_expense_total(_shift_id uuid)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(SUM(amount),0) FROM public.expenses WHERE shift_id = _shift_id AND status = 'active';
$$;

CREATE OR REPLACE FUNCTION public.last_retained_float(_branch_id uuid)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT s.retained_float FROM public.shifts s
  WHERE s.branch_id = _branch_id AND s.status = 'closed' AND public.can_access_branch(_branch_id)
  ORDER BY s.closed_at DESC NULLS LAST LIMIT 1;
$$;

-- ===== Roster =====
CREATE OR REPLACE FUNCTION public.set_shift_roster(_shift_id uuid, _staff_ids uuid[])
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _s public.shifts; _profile uuid := public.current_profile_id();
BEGIN
  SELECT * INTO _s FROM public.shifts WHERE id = _shift_id;
  IF _s.id IS NULL THEN RAISE EXCEPTION 'Shift not found'; END IF;
  IF _s.status <> 'open' THEN RAISE EXCEPTION 'Shift is closed'; END IF;
  IF NOT public.can_access_branch(_s.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _s.user_id <> _profile AND NOT (public.has_permission('shifts.adjust_cash') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(COALESCE(_staff_ids,'{}')) x(id)
             LEFT JOIN public.user_profiles up ON up.id = x.id AND up.company_id = _s.company_id AND up.is_active
             WHERE up.id IS NULL) THEN
    RAISE EXCEPTION 'Invalid staff member';
  END IF;
  DELETE FROM public.shift_staff WHERE shift_id = _shift_id AND NOT (staff_id = ANY(COALESCE(_staff_ids,'{}')));
  INSERT INTO public.shift_staff (shift_id, staff_id, company_id, added_by)
  SELECT _shift_id, x.id, _s.company_id, _profile FROM unnest(COALESCE(_staff_ids,'{}')) x(id)
  ON CONFLICT DO NOTHING;
  PERFORM public.log_audit('shift.roster','pos','shifts',_shift_id,NULL,
    jsonb_build_object('staff', to_jsonb(_staff_ids)),NULL,_s.branch_id);
END $$;

CREATE OR REPLACE FUNCTION public.open_shift_with_roster(_branch_id uuid, _opening_cash numeric, _staff_ids uuid[])
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _id uuid;
BEGIN
  _id := public.open_shift(_branch_id, _opening_cash);
  PERFORM public.set_shift_roster(_id, _staff_ids);
  RETURN _id;
END $$;

-- ===== Manager shift-linked expense (paid from drawer, never from treasury) =====
CREATE OR REPLACE FUNCTION public.create_shift_expense(_shift_id uuid, _amount numeric,
  _category_id uuid DEFAULT NULL, _description text DEFAULT NULL, _vendor text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _s public.shifts; _profile uuid := public.current_profile_id(); _id uuid;
BEGIN
  IF NOT (public.has_permission('expenses.create') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF _amount IS NULL OR _amount <= 0 THEN RAISE EXCEPTION 'Amount must be greater than zero'; END IF;
  SELECT * INTO _s FROM public.shifts WHERE id = _shift_id;
  IF _s.id IS NULL OR _s.status <> 'open' THEN RAISE EXCEPTION 'Shift must be open'; END IF;
  IF NOT public.can_access_branch(_s.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _category_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.expense_categories WHERE id = _category_id AND company_id = _s.company_id)
    THEN RAISE EXCEPTION 'Invalid expense category'; END IF;
  INSERT INTO public.expenses (company_id, branch_id, category_id, amount, expense_date, payment_method,
    vendor, description, created_by, approved_by, approved_at, shift_id)
  VALUES (_s.company_id, _s.branch_id, _category_id, round(_amount,2), CURRENT_DATE, 'shift_drawer',
    NULLIF(_vendor,''), NULLIF(_description,''), _profile, _profile, now(), _shift_id)
  RETURNING id INTO _id;
  PERFORM public.log_audit('expense.shift','finance','expenses',_id,NULL,
    jsonb_build_object('amount',round(_amount,2),'shift_id',_shift_id),NULL,_s.branch_id);
  RETURN _id;
END $$;

-- ===== Close with cash split + shortage attribution =====
CREATE OR REPLACE FUNCTION public.close_shift_handover(_shift_id uuid, _closing_cash numeric,
  _retained_float numeric, _shortage_mode text DEFAULT NULL, _shortage_staff_id uuid DEFAULT NULL,
  _notes text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
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
  -- close_shift checks auth; now subtract drawer expenses from expected.
  SELECT expected_cash INTO _expected FROM public.shifts WHERE id = _shift_id;
  _expected := round(_expected - _expenses, 2);
  _short := round(_expected - _closing_cash, 2);

  IF _short > 0 THEN
    IF _shortage_mode IS NULL OR _shortage_mode NOT IN ('split','staff','venue') THEN
      RAISE EXCEPTION 'Shortage must be attributed';
    END IF;
    IF _shortage_mode = 'venue' AND NOT (public.is_super_admin() OR public.has_permission('expenses.approve')) THEN
      RAISE EXCEPTION 'Only a manager can approve venue-absorbed shortage';
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
END $$;

-- ===== Refund fault attribution =====
CREATE OR REPLACE FUNCTION public.refund_order_items_attributed(_order_id uuid, _items jsonb,
  _method_key text, _reason text, _fault text, _staff_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _res jsonb; _ref public.order_refunds; _company uuid;
BEGIN
  IF _fault NOT IN ('staff','venue') THEN RAISE EXCEPTION 'Refund attribution is required'; END IF;
  IF _fault = 'staff' AND _staff_id IS NULL THEN RAISE EXCEPTION 'Select the responsible staff member'; END IF;
  _res := public.refund_order_items(_order_id, _items, COALESCE(_method_key,'cash'), _reason);
  SELECT * INTO _ref FROM public.order_refunds WHERE order_id = _order_id
    ORDER BY created_at DESC LIMIT 1;
  IF _fault = 'staff' AND NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE id = _staff_id AND company_id = _ref.company_id) THEN
    RAISE EXCEPTION 'Invalid staff member';
  END IF;
  UPDATE public.order_refunds SET fault = _fault, blamed_staff_id = CASE WHEN _fault='staff' THEN _staff_id END
  WHERE id = _ref.id;
  IF _fault = 'staff' THEN
    INSERT INTO public.staff_penalties (company_id, staff_id, amount, reason, order_id, shift_id, created_by)
    VALUES (_ref.company_id, _staff_id, _ref.amount, 'خطأ موظف — مرتجع: ' || _reason, _order_id, _ref.shift_id,
      public.current_profile_id());
  END IF;
  RETURN _res;
END $$;

REVOKE ALL ON FUNCTION public.shift_expense_total(uuid), public.last_retained_float(uuid),
  public.set_shift_roster(uuid, uuid[]), public.open_shift_with_roster(uuid, numeric, uuid[]),
  public.create_shift_expense(uuid, numeric, uuid, text, text),
  public.close_shift_handover(uuid, numeric, numeric, text, uuid, text),
  public.refund_order_items_attributed(uuid, jsonb, text, text, text, uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.shift_expense_total(uuid), public.last_retained_float(uuid),
  public.set_shift_roster(uuid, uuid[]), public.open_shift_with_roster(uuid, numeric, uuid[]),
  public.create_shift_expense(uuid, numeric, uuid, text, text),
  public.close_shift_handover(uuid, numeric, numeric, text, uuid, text),
  public.refund_order_items_attributed(uuid, jsonb, text, text, text, uuid) TO authenticated;