CREATE OR REPLACE FUNCTION public.execute_operational_reset(p_confirm text DEFAULT 'RESET-20S')
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  _company uuid := public.current_company_id();
  _profile uuid := public.current_profile_id();
  _counts jsonb := '{}'::jsonb;
  _n bigint;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Not authorized: super_admin role required'; END IF;
  IF p_confirm <> 'RESET-20S' THEN RAISE EXCEPTION 'Confirmation text does not match'; END IF;
  IF _company IS NULL THEN RAISE EXCEPTION 'No company context'; END IF;

  SET LOCAL session_replication_role = 'replica';

  DELETE FROM public.order_item_modifiers m
    USING public.order_items oi, public.orders o
    WHERE m.order_item_id = oi.id AND oi.order_id = o.id AND o.company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('order_item_modifiers', _n);

  DELETE FROM public.order_refunds WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('order_refunds', _n);

  DELETE FROM public.order_payments p USING public.orders o
    WHERE p.order_id = o.id AND o.company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('order_payments', _n);

  DELETE FROM public.order_items oi USING public.orders o
    WHERE oi.order_id = o.id AND o.company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('order_items', _n);

  DELETE FROM public.customer_points_transactions WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('customer_points_transactions', _n);

  DELETE FROM public.customer_vouchers WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('customer_vouchers', _n);

  DELETE FROM public.orders WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('orders', _n);

  DELETE FROM public.order_counters
    WHERE branch_id IN (SELECT id FROM public.branches WHERE company_id = _company);
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('order_counters', _n);

  DELETE FROM public.shifts WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('shifts', _n);

  DELETE FROM public.purchase_return_items ri USING public.purchase_returns pr
    WHERE ri.purchase_return_id = pr.id AND pr.company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('purchase_return_items', _n);

  DELETE FROM public.purchase_returns WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('purchase_returns', _n);

  DELETE FROM public.purchase_payments WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('purchase_payments', _n);

  DELETE FROM public.purchase_items pi USING public.purchases pu
    WHERE pi.purchase_id = pu.id AND pu.company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('purchase_items', _n);

  DELETE FROM public.purchases WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('purchases', _n);

  DELETE FROM public.expenses WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('expenses', _n);

  DELETE FROM public.stock_movements WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('stock_movements', _n);

  DELETE FROM public.cash_transactions WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('cash_transactions', _n);

  DELETE FROM public.attendance WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('attendance', _n);

  UPDATE public.branch_stock SET quantity = 0
    WHERE branch_id IN (SELECT id FROM public.branches WHERE company_id = _company);

  UPDATE public.cash_accounts SET current_balance = 0.00, opening_balance = 0.00
    WHERE company_id = _company;

  UPDATE public.customers SET points_balance = 0 WHERE company_id = _company;

  SET LOCAL session_replication_role = 'origin';

  PERFORM public.log_audit('system.reset_operational','settings','companies',_company,NULL,_counts,NULL,NULL);
  RETURN _counts;
END $function$;

REVOKE ALL ON FUNCTION public.execute_operational_reset(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.execute_operational_reset(text) TO authenticated, service_role;