DO $$
DECLARE
  r record;
  internal_only text[] := ARRAY[
    'post_cash_txn','default_cash_account','capital_contribution_cash','assert_period_open',
    'loyalty_config','apply_stock_movement','consume_recipe_on_sale','consume_modifier_recipe_on_sale',
    'return_line_stock','return_stock_on_cancel','recalc_order_totals','set_salary_net',
    'work_day_close_at','sync_capital_contribution_ledger'
  ];
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure::text AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prokind = 'f'
      AND (p.prorettype = 'pg_catalog.trigger'::regtype OR p.proname = ANY(internal_only))
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', r.sig);
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM anon', r.sig);
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM authenticated', r.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', r.sig);
  END LOOP;
END $$;