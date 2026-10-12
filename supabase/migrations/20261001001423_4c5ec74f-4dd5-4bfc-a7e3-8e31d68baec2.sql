CREATE OR REPLACE FUNCTION public.shift_staff_candidates()
RETURNS TABLE(id uuid, name text, job_title text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT up.id, COALESCE(NULLIF(up.display_name,''), trim(up.first_name || ' ' || COALESCE(up.last_name,''))), up.job_title
  FROM public.user_profiles up
  WHERE up.company_id = public.current_company_id() AND up.is_active
    AND public.current_profile_id() IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM public.partners pa WHERE pa.user_id = up.id AND pa.status = 'active' AND NOT pa.is_managing_staff)
    AND (up.is_managing_staff OR NOT EXISTS (
      SELECT 1 FROM public.user_roles ur JOIN public.roles r ON r.id = ur.role_id
      WHERE ur.user_id = up.id AND r.key = 'super_admin'))
  ORDER BY 2;
$$;
REVOKE ALL ON FUNCTION public.shift_staff_candidates() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.shift_staff_candidates() TO authenticated;

CREATE OR REPLACE FUNCTION public.shift_expected_cash(_shift_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE _s public.shifts; _cash_in numeric := 0; _cash_out numeric := 0;
  _sales numeric := 0; _orders integer := 0; _exp numeric := 0;
BEGIN
  IF public.current_profile_id() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO _s FROM public.shifts WHERE id = _shift_id;
  IF _s.id IS NULL THEN RAISE EXCEPTION 'Shift not found'; END IF;
  IF NOT public.can_access_branch(_s.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _s.user_id <> public.current_profile_id()
     AND NOT (public.has_permission('shifts.view') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  SELECT COALESCE(SUM(p.amount),0) INTO _cash_in
  FROM public.orders o JOIN public.order_payments p ON p.order_id = o.id
  WHERE o.shift_id = _shift_id AND o.status <> 'cancelled' AND p.method_key = 'cash';
  SELECT COALESCE(SUM(r.amount),0) INTO _cash_out
  FROM public.order_refunds r
  WHERE r.shift_id = _shift_id AND r.status = 'active' AND COALESCE(r.method_key,'cash') = 'cash';
  SELECT COALESCE(SUM(o.total),0), count(*) INTO _sales, _orders
  FROM public.orders o WHERE o.shift_id = _shift_id AND o.status <> 'cancelled';
  _exp := public.shift_expense_total(_shift_id);
  RETURN jsonb_build_object(
    'opening_cash', _s.opening_cash, 'cash_in', _cash_in, 'cash_refunds', _cash_out,
    'shift_expenses', _exp,
    'expected_cash', _s.opening_cash + _cash_in - _cash_out - _exp,
    'sales_total', _sales, 'orders_count', _orders);
END $$;