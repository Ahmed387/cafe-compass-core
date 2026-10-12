-- Fix reopen_accounting_period (accounting_periods has no updated_at column)
CREATE OR REPLACE FUNCTION public.reopen_accounting_period(_period_id uuid, _reason text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
     SET status = 'open', closed_at = NULL, closed_by = NULL
   WHERE id = _period_id;

  PERFORM public.log_audit('period.reopen','finance','accounting_periods',_period_id,
    jsonb_build_object('status','closed'), jsonb_build_object('status','open'), _reason, NULL);
  RETURN _period_id;
END
$$;

-- Purge test/demo transactional data (delete guards are session-disabled)
SET session_replication_role = replica;

DELETE FROM public.order_item_modifiers;
DELETE FROM public.order_refunds;
DELETE FROM public.order_payments;
DELETE FROM public.order_items;
DELETE FROM public.orders;
DELETE FROM public.order_counters;
DELETE FROM public.shifts;
DELETE FROM public.stock_movements;
DELETE FROM public.branch_stock;
DELETE FROM public.purchase_items;
DELETE FROM public.purchases;
DELETE FROM public.profit_distribution_lines;
DELETE FROM public.profit_distributions;
DELETE FROM public.partner_ledger_transactions;
DELETE FROM public.partner_capital_contributions;
DELETE FROM public.partners WHERE name = 'Partner Test';
DELETE FROM public.employee_advances;
DELETE FROM public.salary_payments;
DELETE FROM public.employee_salaries;
DELETE FROM public.attendance;
DELETE FROM public.expenses;
DELETE FROM public.accounting_periods;
DELETE FROM public.notifications;
DELETE FROM public.audit_logs;

DELETE FROM public.user_roles WHERE user_id IN (SELECT id FROM public.user_profiles WHERE email LIKE '%@test20s.local');
DELETE FROM public.user_branches WHERE user_id IN (SELECT id FROM public.user_profiles WHERE email LIKE '%@test20s.local');
DELETE FROM public.user_profiles WHERE email LIKE '%@test20s.local';

SET session_replication_role = origin;