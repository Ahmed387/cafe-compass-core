-- 1. DELETE BACKUP ENTRY RPC
CREATE OR REPLACE FUNCTION public.delete_backup_entry(p_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Unauthorized: Only Super Admin can delete backups.';
  END IF;
  DELETE FROM public.backup_history WHERE id = p_id;
  RETURN true;
END;
$$;

-- 2. MODULAR GRANULAR OPERATIONAL RESET RPC
DROP FUNCTION IF EXISTS public.execute_operational_reset(text);

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

  IF v_all OR ('shifts' = ANY(p_targets)) THEN
    TRUNCATE TABLE public.shifts RESTART IDENTITY CASCADE;
  END IF;

  IF v_all OR ('purchases' = ANY(p_targets)) THEN
    TRUNCATE TABLE
      public.purchase_payments,
      public.purchase_items,
      public.purchases
    RESTART IDENTITY CASCADE;
  END IF;

  IF v_all OR ('purchase_returns' = ANY(p_targets)) THEN
    TRUNCATE TABLE
      public.purchase_return_items,
      public.purchase_returns
    RESTART IDENTITY CASCADE;
  END IF;

  IF v_all OR ('expenses' = ANY(p_targets)) THEN
    TRUNCATE TABLE public.expenses RESTART IDENTITY CASCADE;
  END IF;

  IF v_all OR ('stock_movements' = ANY(p_targets)) THEN
    TRUNCATE TABLE public.stock_movements RESTART IDENTITY CASCADE;
    UPDATE public.branch_stock SET quantity = 0;
  END IF;

  IF v_all OR ('cash_transactions' = ANY(p_targets)) THEN
    TRUNCATE TABLE public.cash_transactions RESTART IDENTITY CASCADE;
    UPDATE public.cash_accounts SET current_balance = 0.00;
  END IF;

  IF v_all OR ('loyalty' = ANY(p_targets)) THEN
    TRUNCATE TABLE
      public.customer_points_transactions,
      public.customer_vouchers
    RESTART IDENTITY CASCADE;
    UPDATE public.customers SET points_balance = 0;
  END IF;

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

-- 3. DISASTER RECOVERY BACKUP RESTORE RPC
CREATE OR REPLACE FUNCTION public.restore_backup_snapshot(
  p_payload jsonb,
  p_confirm text DEFAULT 'RESTORE-20S'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_table text;
  v_rows jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Unauthorized: Only Super Admin can restore snapshots.';
  END IF;
  IF p_confirm <> 'RESTORE-20S' THEN
    RAISE EXCEPTION 'Confirmation code mismatch. Type RESTORE-20S.';
  END IF;

  SET LOCAL session_replication_role = 'replica';

  FOR v_table, v_rows IN SELECT * FROM jsonb_each(p_payload)
  LOOP
    IF v_table IN (
      'categories', 'products', 'product_sizes', 'modifier_groups',
      'product_recipes', 'inventory_items', 'orders', 'order_items',
      'order_item_modifiers', 'order_payments', 'shifts', 'purchases',
      'purchase_items', 'expenses', 'stock_movements', 'cash_transactions'
    ) AND jsonb_typeof(v_rows) = 'array' AND jsonb_array_length(v_rows) > 0 THEN
      EXECUTE format('TRUNCATE TABLE public.%I CASCADE;', v_table);
      EXECUTE format(
        'INSERT INTO public.%I SELECT * FROM jsonb_populate_recordset(null::public.%I, %L);',
        v_table, v_table, v_rows
      );
    END IF;
  END LOOP;

  SET LOCAL session_replication_role = 'origin';
  RETURN jsonb_build_object('success', true, 'message', 'Snapshot restored successfully');
EXCEPTION WHEN OTHERS THEN
  SET LOCAL session_replication_role = 'origin';
  RAISE;
END;
$$;

REVOKE ALL ON FUNCTION public.delete_backup_entry(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_backup_entry(uuid) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.execute_operational_reset(text, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.execute_operational_reset(text, text[]) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.restore_backup_snapshot(jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.restore_backup_snapshot(jsonb, text) TO authenticated, service_role;