DO $$
DECLARE
  _keep_profile uuid := 'b4819888-997e-478c-82aa-c2cd12dd9f0f';
  _keep_auth uuid := '5ce37819-7435-4c53-ad8e-1eb1d6b305b9';
BEGIN
  SET LOCAL session_replication_role = 'replica';

  -- Operational data
  TRUNCATE TABLE
    public.order_item_modifiers,
    public.order_items,
    public.order_payments,
    public.order_refunds,
    public.partner_tab_orders,
    public.orders,
    public.order_counters,
    public.shifts,
    public.attendance,
    public.cash_transactions,
    public.expenses,
    public.purchase_payments,
    public.purchase_items,
    public.purchase_return_items,
    public.purchase_returns,
    public.purchases,
    public.stock_movements,
    public.branch_stock,
    public.customer_points_transactions,
    public.customer_vouchers,
    public.customers,
    public.suppliers,
    public.employee_advances,
    public.employee_salaries,
    public.salary_payments,
    public.staff_penalties,
    public.work_schedules,
    public.accounting_periods,
    public.profit_distribution_lines,
    public.profit_distributions,
    public.partner_capital_contributions,
    public.partner_ledger_transactions,
    public.partner_withdrawal_requests,
    public.partners,
    public.notifications,
    public.audit_logs,
    public.backup_history,
    public.user_documents
  RESTART IDENTITY CASCADE;

  -- Catalog / menu / offers / inventory definitions
  TRUNCATE TABLE
    public.offer_bundle_items,
    public.product_offers,
    public.product_recipes,
    public.modifier_option_recipes,
    public.modifier_options,
    public.product_modifier_groups,
    public.modifier_groups,
    public.product_sizes,
    public.product_branch_settings,
    public.products,
    public.categories,
    public.inventory_items
  RESTART IDENTITY CASCADE;

  -- Users: keep only the super admin
  DELETE FROM public.user_branches WHERE user_id <> _keep_profile;
  DELETE FROM public.user_roles WHERE user_id <> _keep_profile;
  DELETE FROM public.user_profiles WHERE id <> _keep_profile;
  DELETE FROM auth.users WHERE id <> _keep_auth;

  SET LOCAL session_replication_role = 'origin';
END $$;