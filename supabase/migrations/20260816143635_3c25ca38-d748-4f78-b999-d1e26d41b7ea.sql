-- ============ 1) Column-level protection for products.cost ============
REVOKE SELECT ON public.products FROM authenticated;
GRANT SELECT (id, company_id, category_id, name, name_ar, description, image_url, sku,
  base_price, is_taxable, is_available, is_active, display_order, station_id,
  created_by, created_at, updated_at) ON public.products TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.products TO authenticated;
GRANT ALL ON public.products TO service_role;

CREATE OR REPLACE FUNCTION public.product_costs()
RETURNS TABLE(product_id uuid, cost numeric)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT p.id, p.cost
  FROM public.products p
  WHERE p.company_id = public.current_company_id()
    AND (public.has_permission('products.view_cost') OR public.is_super_admin());
$$;
REVOKE ALL ON FUNCTION public.product_costs() FROM public;
GRANT EXECUTE ON FUNCTION public.product_costs() TO authenticated;

-- ============ 2) Closed periods block dated entries ============
CREATE OR REPLACE FUNCTION public.assert_period_open(_company_id uuid, _date date)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF _company_id IS NULL OR _date IS NULL THEN RETURN; END IF;
  IF public.is_super_admin() THEN RETURN; END IF;
  IF EXISTS (
    SELECT 1 FROM public.accounting_periods ap
    WHERE ap.company_id = _company_id
      AND ap.status = 'closed'
      AND _date BETWEEN ap.start_date AND ap.end_date
  ) THEN
    RAISE EXCEPTION 'The accounting period covering % is closed', _date;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.block_closed_period_entry()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE _company uuid; _date date;
BEGIN
  EXECUTE format('SELECT ($1).%I::uuid, ($1).%I::date', TG_ARGV[0], TG_ARGV[1])
    INTO _company, _date USING NEW;
  PERFORM public.assert_period_open(_company, _date);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS t_orders_period_guard ON public.orders;
CREATE TRIGGER t_orders_period_guard BEFORE INSERT OR UPDATE ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.block_closed_period_entry('company_id','created_at');

DROP TRIGGER IF EXISTS t_expenses_period_guard ON public.expenses;
CREATE TRIGGER t_expenses_period_guard BEFORE INSERT OR UPDATE ON public.expenses
FOR EACH ROW EXECUTE FUNCTION public.block_closed_period_entry('company_id','expense_date');

DROP TRIGGER IF EXISTS t_purchases_period_guard ON public.purchases;
CREATE TRIGGER t_purchases_period_guard BEFORE INSERT OR UPDATE ON public.purchases
FOR EACH ROW EXECUTE FUNCTION public.block_closed_period_entry('company_id','purchase_date');

DROP TRIGGER IF EXISTS t_stock_movements_period_guard ON public.stock_movements;
CREATE TRIGGER t_stock_movements_period_guard BEFORE INSERT ON public.stock_movements
FOR EACH ROW EXECUTE FUNCTION public.block_closed_period_entry('company_id','created_at');

DROP TRIGGER IF EXISTS t_salary_payments_period_guard ON public.salary_payments;
CREATE TRIGGER t_salary_payments_period_guard BEFORE INSERT OR UPDATE ON public.salary_payments
FOR EACH ROW EXECUTE FUNCTION public.block_closed_period_entry('company_id','period_end');

DROP TRIGGER IF EXISTS t_attendance_period_guard ON public.attendance;
CREATE TRIGGER t_attendance_period_guard BEFORE INSERT OR UPDATE ON public.attendance
FOR EACH ROW EXECUTE FUNCTION public.block_closed_period_entry('company_id','work_date');

DROP TRIGGER IF EXISTS t_advances_period_guard ON public.employee_advances;
CREATE TRIGGER t_advances_period_guard BEFORE INSERT OR UPDATE ON public.employee_advances
FOR EACH ROW EXECUTE FUNCTION public.block_closed_period_entry('company_id','advance_date');

DROP TRIGGER IF EXISTS t_capital_period_guard ON public.partner_capital_contributions;
CREATE TRIGGER t_capital_period_guard BEFORE INSERT OR UPDATE ON public.partner_capital_contributions
FOR EACH ROW EXECUTE FUNCTION public.block_closed_period_entry('company_id','contribution_date');

DROP TRIGGER IF EXISTS t_refunds_period_guard ON public.order_refunds;
CREATE TRIGGER t_refunds_period_guard BEFORE INSERT ON public.order_refunds
FOR EACH ROW EXECUTE FUNCTION public.block_closed_period_entry('company_id','created_at');

-- ============ 3) Dedicated accounting-period permissions ============
INSERT INTO public.permissions (key, name, description, module) VALUES
  ('periods.view','View accounting periods','See accounting periods and their status','finance'),
  ('periods.manage','Manage accounting periods','Create, close and review accounting periods','finance')
ON CONFLICT (key) DO NOTHING;

INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM public.roles r, public.permissions p
WHERE r.key IN ('super_admin','manager','accountant') AND p.key IN ('periods.view','periods.manage')
ON CONFLICT DO NOTHING;

DROP POLICY IF EXISTS ap_select ON public.accounting_periods;
CREATE POLICY ap_select ON public.accounting_periods FOR SELECT TO authenticated
USING (company_id = public.current_company_id() AND (
  public.has_permission('periods.view') OR public.has_permission('reports.profit')
  OR public.has_permission('settings.view')));

DROP POLICY IF EXISTS ap_insert ON public.accounting_periods;
CREATE POLICY ap_insert ON public.accounting_periods FOR INSERT TO authenticated
WITH CHECK (company_id = public.current_company_id() AND (
  public.has_permission('periods.manage') OR public.has_permission('settings.manage')));

DROP POLICY IF EXISTS ap_update ON public.accounting_periods;
CREATE POLICY ap_update ON public.accounting_periods FOR UPDATE TO authenticated
USING (company_id = public.current_company_id() AND (
  public.has_permission('periods.manage') OR public.has_permission('settings.manage')))
WITH CHECK (company_id = public.current_company_id());

CREATE OR REPLACE FUNCTION public.close_accounting_period(_period_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE _profile uuid := public.current_profile_id(); _p public.accounting_periods;
  _open_shifts integer := 0; _open_orders integer := 0;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('periods.manage') OR public.has_permission('settings.manage') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT * INTO _p FROM public.accounting_periods
   WHERE id = _period_id AND company_id = public.current_company_id();
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Period not found'; END IF;
  IF _p.status = 'closed' THEN RAISE EXCEPTION 'Period is already closed'; END IF;

  SELECT count(*) INTO _open_shifts FROM public.shifts s
   WHERE s.company_id = _p.company_id AND s.status = 'open'
     AND s.opened_at::date <= _p.end_date;
  IF _open_shifts > 0 THEN
    RAISE EXCEPTION 'Close the % open shift(s) in this period first', _open_shifts;
  END IF;

  SELECT count(*) INTO _open_orders FROM public.orders o
   WHERE o.company_id = _p.company_id AND o.status = 'open'
     AND o.created_at::date BETWEEN _p.start_date AND _p.end_date;
  IF _open_orders > 0 THEN
    RAISE EXCEPTION 'Settle the % unpaid order(s) in this period first', _open_orders;
  END IF;

  UPDATE public.accounting_periods
     SET status = 'closed', closed_at = now(), closed_by = _profile
   WHERE id = _period_id;

  PERFORM public.log_audit('period.close','finance','accounting_periods',_period_id,
    jsonb_build_object('status','open'), jsonb_build_object('status','closed'), NULL, NULL);
  RETURN _period_id;
END;
$$;
