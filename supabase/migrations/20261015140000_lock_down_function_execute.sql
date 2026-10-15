-- =====================================================================
-- Security: close SECURITY DEFINER functions that anyone could call.
--
-- After the database moved to its current Supabase project (2026-10-14) the
-- REVOKE statements from earlier migrations were not in effect: 226 privileged
-- functions were executable by the anonymous (not signed-in) role through the
-- public API, 49 of them with no permission check at all — e.g. closing a
-- shift, posting to a customer wallet, paying a salary, reading the P&L and
-- every salary.
--
-- Rules applied here:
--   * anon may only call what the public pages need (public menu, customer
--     card) and the small helpers used inside row-level-security policies.
--   * Internal helpers (called only from other database functions, triggers or
--     cron) are not callable through the API by anyone.
--   * Every other privileged function stays available to signed-in users; each
--     one checks the caller's permissions itself.
-- No data is changed.
-- =====================================================================

DO $$
DECLARE
  r record;
  -- Needed before sign-in, or used inside RLS policies / views / invoker functions.
  anon_ok text[] := ARRAY['public_menu', 'customer_card',
    '_prorated_salary', 'advance_outstanding', 'can_access_branch', 'cashier_can_see_shift', 'current_company_id',
    'current_partner_id', 'current_profile_id', 'enforce_public_menu_requires_recipe', 'forbid_hard_delete',
    'guard_profile_self_update', 'has_permission', 'is_can_eligible_product', 'is_cashier_only', 'is_super_admin',
    'line_cogs', 'line_raw_cost', 'normalize_phone', 'order_item_unit_cogs', 'orders_period_summary',
    'partner_balance', 'penalty_outstanding', 'protect_closed_period', 'protect_closed_shift', 'salary_line_cost',
    'set_salary_net', 'set_soft_opening_updated_at', 'set_updated_at', 'tender_key', 'waste_factor'];
  -- Internal only: never called by the app directly.
  internal text[] := ARRAY['_cashback_accrue', '_finalize_shift_close', '_management_salary', '_on_open_order_shift',
    '_payout_calc', '_payroll_lines', '_post_shift_electronic', '_range_pnl', '_shift_figures', '_wallet_post',
    '_issue_salary_line', 'apply_weighted_cost', 'recalc_order_totals', 'return_line_stock', 'refund_shift_for',
    'refund_target_shift', 'execute_salary_payment', 'recompute_capital_equity', 'sync_capital_contribution_ledger',
    'auto_close_due_shifts', 'auto_link_can_group', 'waste_share_staff', 'attendance_deduction_days',
    'cashback_config', 'loyalty_config', 'shift_expense_total', 'cash_balance', 'assert_period_open',
    'work_day_close_at'];
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig, p.proname
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND p.prosecdef
       AND NOT (p.proname = ANY (anon_ok))
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', r.sig);
    IF r.proname = ANY (internal) THEN
      EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', r.sig);
    ELSE
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', r.sig);
      EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon', r.sig);
    END IF;
  END LOOP;
END $$;
