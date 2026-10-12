CREATE OR REPLACE FUNCTION public.force_close_stuck_shift(_branch_id uuid, _reason text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE _s public.shifts; _profile uuid := public.current_profile_id();
  _cash_in numeric := 0; _cash_out numeric := 0; _expected numeric; _company uuid; _acc uuid; _deposit numeric;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('shifts.close') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF NOT public.can_access_branch(_branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;

  SELECT * INTO _s FROM public.shifts
  WHERE branch_id = _branch_id AND status = 'open'
  ORDER BY opened_at ASC LIMIT 1;

  IF _s.id IS NULL THEN
    RAISE EXCEPTION 'لا توجد وردية مفتوحة على هذا الفرع';
  END IF;

  SELECT COALESCE(SUM(p.amount),0) INTO _cash_in
  FROM public.orders o JOIN public.order_payments p ON p.order_id = o.id
  WHERE o.shift_id = _s.id AND o.status <> 'cancelled' AND p.method_key = 'cash';

  SELECT COALESCE(SUM(r.amount),0) INTO _cash_out
  FROM public.order_refunds r
  WHERE r.shift_id = _s.id AND r.status = 'active' AND COALESCE(r.method_key,'cash') = 'cash';

  _expected := round(COALESCE(_s.opening_cash,0) + _cash_in - _cash_out, 2);

  UPDATE public.shifts SET
    status = 'closed',
    closing_cash = _expected,
    expected_cash = _expected,
    variance = 0,
    closed_at = now(),
    closed_by = _profile,
    notes = COALESCE(NULLIF(notes,'') || ' | ', '') ||
            'إغلاق وردية عالقة: ' || COALESCE(NULLIF(_reason,''), 'بدون سبب محدد')
  WHERE id = _s.id;

  SELECT company_id INTO _company FROM public.branches WHERE id = _s.branch_id;
  _deposit := round(_expected - COALESCE(_s.opening_cash,0), 2);
  _acc := public.default_cash_account(_company, 'cash');
  IF _acc IS NOT NULL AND _deposit > 0 THEN
    PERFORM public.post_cash_txn(_company, _acc, 'in', _deposit, 'shift_deposit', 'cash', CURRENT_DATE,
      'shift', _s.id, 'Shift cash deposit (stuck shift closure)', NULL, false);
  END IF;

  PERFORM public.log_audit('shift.force_close','pos','shifts',_s.id,NULL,
    jsonb_build_object('expected_cash', _expected, 'deposited', GREATEST(_deposit,0),
                       'shift_user_id', _s.user_id, 'closed_by', _profile),
    COALESCE(NULLIF(_reason,''),'إغلاق وردية عالقة'), _s.branch_id);

  INSERT INTO public.notifications (company_id, branch_id, required_permission, type, severity, title, body, data)
  VALUES (_company, _s.branch_id, 'shifts.view', 'shift.force_closed', 'warning',
    'إغلاق وردية عالقة',
    'تم إغلاق وردية عالقة يدويًا والنقدية المتوقعة ' || to_char(_expected,'FM999999990.00') || ' ج.م',
    jsonb_build_object('shift_id', _s.id, 'expected_cash', _expected));

  RETURN jsonb_build_object('shift_id', _s.id, 'expected_cash', _expected, 'deposited', GREATEST(_deposit,0));
END $function$;

REVOKE ALL ON FUNCTION public.force_close_stuck_shift(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.force_close_stuck_shift(uuid, text) TO authenticated, service_role;