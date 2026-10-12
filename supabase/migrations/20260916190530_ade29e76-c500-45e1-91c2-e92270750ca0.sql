CREATE OR REPLACE FUNCTION public.execute_operational_reset(p_confirm text DEFAULT 'RESET-20S')
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _company uuid;
BEGIN
  -- 1. Guards: authenticated super admin with explicit confirmation
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Unauthorized: Only Super Admin can execute reset.';
  END IF;
  IF p_confirm <> 'RESET-20S' THEN
    RAISE EXCEPTION 'confirmation text does not match';
  END IF;
  _company := public.current_company_id();
  IF _company IS NULL THEN
    RAISE EXCEPTION 'no company context';
  END IF;

  -- 2. Bypass delete-guard triggers and FK constraints for this transaction
  SET LOCAL session_replication_role = 'replica';

  -- 3. Wipe operational transaction tables (no column filters, no row-level guards)
  TRUNCATE TABLE
    public.order_item_modifiers,
    public.order_items,
    public.order_payments,
    public.order_refunds,
    public.orders,
    public.order_counters,
    public.shifts,
    public.purchase_return_items,
    public.purchase_returns,
    public.purchase_payments,
    public.purchase_items,
    public.purchases,
    public.expenses,
    public.stock_movements,
    public.cash_transactions,
    public.customer_points_transactions,
    public.customer_vouchers,
    public.attendance
  RESTART IDENTITY CASCADE;

  -- 4. Zero balances
  UPDATE public.cash_accounts SET current_balance = 0.00, opening_balance = 0.00;
  UPDATE public.branch_stock SET quantity = 0;
  UPDATE public.customers SET points_balance = 0;

  -- 5. Restore normal constraint enforcement
  SET LOCAL session_replication_role = 'origin';

  PERFORM public.log_audit(
    'system.reset_operational', 'settings', 'companies', _company,
    NULL, jsonb_build_object('method', 'truncate_cascade'), NULL, NULL);

  RETURN jsonb_build_object('success', true, 'message', 'Operational data reset successfully');
EXCEPTION WHEN OTHERS THEN
  SET LOCAL session_replication_role = 'origin';
  RAISE;
END;
$$;

REVOKE ALL ON FUNCTION public.execute_operational_reset(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.execute_operational_reset(text) TO authenticated, service_role;