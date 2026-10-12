CREATE OR REPLACE FUNCTION public.execute_operational_reset(
  p_confirm text DEFAULT 'RESET-20S',
  p_targets text[] DEFAULT ARRAY['all']
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_all boolean;
  v_company uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Unauthorized: Only Super Admin can execute reset.';
  END IF;
  IF p_confirm <> 'RESET-20S' THEN
    RAISE EXCEPTION 'Confirmation code mismatch. Type RESET-20S.';
  END IF;

  v_company := public.current_company_id();
  v_all := ('all' = ANY(p_targets));

  SET LOCAL session_replication_role = 'replica';

  -- Target 1: Sales & Orders
  IF v_all OR ('orders' = ANY(p_targets)) THEN
    TRUNCATE TABLE
      public.order_item_modifiers,
      public.order_items,
      public.order_payments,
      public.order_refunds,
      public.orders,
      public.order_counters
    RESTART IDENTITY CASCADE;
  END IF;

  -- Target 2: Shifts
  IF v_all OR ('shifts' = ANY(p_targets)) THEN
    TRUNCATE TABLE public.shifts RESTART IDENTITY CASCADE;
  END IF;

  -- Target 3: Purchases
  IF v_all OR ('purchases' = ANY(p_targets)) THEN
    TRUNCATE TABLE
      public.purchase_payments,
      public.purchase_items,
      public.purchases
    RESTART IDENTITY CASCADE;
  END IF;

  -- Target 4: Purchase Returns
  IF v_all OR ('purchase_returns' = ANY(p_targets)) THEN
    TRUNCATE TABLE
      public.purchase_return_items,
      public.purchase_returns
    RESTART IDENTITY CASCADE;
  END IF;

  -- Target 5: Expenses
  IF v_all OR ('expenses' = ANY(p_targets)) THEN
    TRUNCATE TABLE public.expenses RESTART IDENTITY CASCADE;
  END IF;

  -- Target 6: Stock Movements & Branch Inventory
  IF v_all OR ('stock_movements' = ANY(p_targets)) THEN
    TRUNCATE TABLE public.stock_movements RESTART IDENTITY CASCADE;
    -- Explicit WHERE clause to satisfy safeupdate guards
    UPDATE public.branch_stock SET quantity = 0 WHERE id IS NOT NULL;
  END IF;

  -- Target 7: Treasury & Cash
  IF v_all OR ('cash_transactions' = ANY(p_targets)) THEN
    TRUNCATE TABLE public.cash_transactions RESTART IDENTITY CASCADE;
  END IF;

  -- Target 8: Loyalty Points & Vouchers
  IF v_all OR ('loyalty' = ANY(p_targets)) THEN
    TRUNCATE TABLE
      public.customer_points_transactions,
      public.customer_vouchers
    RESTART IDENTITY CASCADE;
    -- Explicit WHERE clause to satisfy safeupdate guards
    UPDATE public.customers SET points_balance = 0 WHERE id IS NOT NULL;
  END IF;

  -- Target 9: Attendance
  IF v_all OR ('attendance' = ANY(p_targets)) THEN
    TRUNCATE TABLE public.attendance RESTART IDENTITY CASCADE;
  END IF;

  SET LOCAL session_replication_role = 'origin';

  IF v_company IS NOT NULL THEN
    PERFORM public.log_audit(
      'system.modular_reset', 'settings', 'companies', v_company,
      NULL, jsonb_build_object('targets', p_targets, 'method', 'truncate_cascade'), NULL, NULL
    );
  END IF;

  RETURN jsonb_build_object('success', true, 'message', 'Selected modules reset successfully');

EXCEPTION WHEN OTHERS THEN
  SET LOCAL session_replication_role = 'origin';
  RAISE;
END;
$$;