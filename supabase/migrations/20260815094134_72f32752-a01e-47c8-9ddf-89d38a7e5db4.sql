-- 1) Auto-refund the overpaid difference when voiding a line on a paid order
CREATE OR REPLACE FUNCTION public.void_order_item(_order_item_id uuid, _reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _profile uuid := public.current_profile_id(); _oi public.order_items; _o public.orders;
  _before numeric; _after numeric; _active integer;
  _paid numeric := 0; _already numeric := 0; _over numeric := 0; _tax_share numeric := 0;
  _refund_id uuid;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('pos.void_item') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF _reason IS NULL OR length(btrim(_reason)) < 3 THEN RAISE EXCEPTION 'A reason is required'; END IF;

  SELECT * INTO _oi FROM public.order_items WHERE id = _order_item_id;
  IF _oi.id IS NULL THEN RAISE EXCEPTION 'Order line not found'; END IF;
  IF _oi.status = 'voided' THEN RAISE EXCEPTION 'This line is already voided'; END IF;

  SELECT * INTO _o FROM public.orders WHERE id = _oi.order_id;
  IF NOT public.can_access_branch(_o.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _o.status IN ('cancelled','refunded') THEN RAISE EXCEPTION 'Order is already closed'; END IF;

  _before := _o.total;
  UPDATE public.order_items SET status = 'voided', void_reason = _reason WHERE id = _order_item_id;
  PERFORM public.return_line_stock(_order_item_id);
  PERFORM public.recalc_order_totals(_oi.order_id);
  SELECT total INTO _after FROM public.orders WHERE id = _oi.order_id;

  SELECT count(*) INTO _active FROM public.order_items
   WHERE order_id = _oi.order_id AND status = 'active';

  -- Money already collected above the new total must come back to the guest.
  SELECT COALESCE(SUM(amount),0) INTO _paid FROM public.order_payments WHERE order_id = _oi.order_id;
  SELECT COALESCE(SUM(amount),0) INTO _already
    FROM public.order_refunds WHERE order_id = _oi.order_id AND status = 'active';
  _over := round(_paid - _already - COALESCE(_after,0), 2);

  IF _over > 0 THEN
    IF _paid > 0 AND COALESCE(_o.tax_amount,0) > 0 THEN
      _tax_share := round(_o.tax_amount * LEAST(_over / _paid, 1), 2);
    END IF;
    INSERT INTO public.order_refunds (company_id, branch_id, order_id, shift_id, kind, amount,
      tax_amount, method_key, reason, created_by)
    VALUES (_o.company_id, _o.branch_id, _o.id, _o.shift_id,
      CASE WHEN _active = 0 THEN 'full' ELSE 'partial' END, _over,
      _tax_share,
      COALESCE((SELECT p.method_key FROM public.order_payments p WHERE p.order_id = _o.id
                ORDER BY p.amount DESC LIMIT 1), 'cash'),
      'Auto refund for voided item: ' || _reason, _profile)
    RETURNING id INTO _refund_id;
  END IF;

  IF _active = 0 THEN
    UPDATE public.orders
       SET status = 'cancelled',
           cancel_reason = COALESCE(cancel_reason, 'All lines voided: ' || _reason),
           cancelled_at = COALESCE(cancelled_at, now()),
           updated_at = now()
     WHERE id = _oi.order_id;
  END IF;

  PERFORM public.log_audit('order.void_item','pos','order_items',_order_item_id,
    jsonb_build_object('line_total',_oi.line_total,'order_total',_before),
    jsonb_build_object('order_total',_after,'order_cancelled', _active = 0,
      'auto_refund', _over, 'refund_id', _refund_id), _reason, _o.branch_id);
  RETURN _order_item_id;
END $function$;

-- 2) Allow a super admin to reopen a period that was closed by mistake
CREATE OR REPLACE FUNCTION public.reopen_accounting_period(_period_id uuid, _reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _profile uuid := public.current_profile_id(); _p public.accounting_periods;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only a super admin can reopen a period'; END IF;
  IF _reason IS NULL OR length(btrim(_reason)) < 3 THEN RAISE EXCEPTION 'A reason is required'; END IF;

  SELECT * INTO _p FROM public.accounting_periods
   WHERE id = _period_id AND company_id = public.current_company_id();
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Period not found'; END IF;
  IF _p.status <> 'closed' THEN RAISE EXCEPTION 'Period is not closed'; END IF;
  IF EXISTS (SELECT 1 FROM public.profit_distributions d
              WHERE d.period_id = _period_id AND d.status <> 'cancelled') THEN
    RAISE EXCEPTION 'Cancel the profit distribution of this period first';
  END IF;

  UPDATE public.accounting_periods
     SET status = 'open', closed_at = NULL, closed_by = NULL, updated_at = now()
   WHERE id = _period_id;

  PERFORM public.log_audit('period.reopen','finance','accounting_periods',_period_id,
    jsonb_build_object('status','closed'), jsonb_build_object('status','open'), _reason, NULL);
  RETURN _period_id;
END $function$;

REVOKE ALL ON FUNCTION public.reopen_accounting_period(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reopen_accounting_period(uuid, text) TO authenticated;

-- 3) Default kitchen station so nothing disappears from the KDS
ALTER TABLE public.kitchen_stations ADD COLUMN IF NOT EXISTS is_default boolean NOT NULL DEFAULT false;

CREATE UNIQUE INDEX IF NOT EXISTS kitchen_stations_one_default
  ON public.kitchen_stations (company_id) WHERE is_default;

UPDATE public.kitchen_stations s SET is_default = true
 WHERE s.is_active
   AND NOT EXISTS (SELECT 1 FROM public.kitchen_stations d
                    WHERE d.company_id = s.company_id AND d.is_default)
   AND s.display_order = (SELECT min(x.display_order) FROM public.kitchen_stations x
                           WHERE x.company_id = s.company_id AND x.is_active);

UPDATE public.products p SET station_id = (
  SELECT s.id FROM public.kitchen_stations s
   WHERE s.company_id = p.company_id AND s.is_default LIMIT 1)
 WHERE p.station_id IS NULL;

UPDATE public.order_items oi SET station_id = COALESCE(
  (SELECT p.station_id FROM public.products p WHERE p.id = oi.product_id),
  (SELECT s.id FROM public.kitchen_stations s
    JOIN public.orders o ON o.id = oi.order_id
    WHERE s.company_id = o.company_id AND s.is_default LIMIT 1))
 WHERE oi.station_id IS NULL;

CREATE OR REPLACE FUNCTION public.set_order_item_station()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.station_id IS NULL AND NEW.product_id IS NOT NULL THEN
    SELECT p.station_id INTO NEW.station_id FROM public.products p WHERE p.id = NEW.product_id;
  END IF;
  IF NEW.station_id IS NULL THEN
    SELECT s.id INTO NEW.station_id FROM public.kitchen_stations s
     WHERE s.company_id = (SELECT o.company_id FROM public.orders o WHERE o.id = NEW.order_id)
       AND s.is_default LIMIT 1;
  END IF;
  RETURN NEW;
END;
$function$;

-- 4) Manager needs payroll visibility and cash adjustment (to close a forgotten shift)
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM public.roles r
JOIN public.permissions p
  ON p.key IN ('payroll.view','payroll.manage','reports.payroll','shifts.adjust_cash')
WHERE r.name = 'Manager'
ON CONFLICT DO NOTHING;

-- 5) Expected cash preview before the shift is closed
CREATE OR REPLACE FUNCTION public.shift_expected_cash(_shift_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _s public.shifts; _cash_in numeric := 0; _cash_out numeric := 0;
  _sales numeric := 0; _orders integer := 0;
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

  RETURN jsonb_build_object(
    'opening_cash', _s.opening_cash,
    'cash_in', _cash_in,
    'cash_refunds', _cash_out,
    'expected_cash', _s.opening_cash + _cash_in - _cash_out,
    'sales_total', _sales,
    'orders_count', _orders
  );
END $function$;

REVOKE ALL ON FUNCTION public.shift_expected_cash(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shift_expected_cash(uuid) TO authenticated;