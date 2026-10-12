-- =====================================================================
-- Core re-architecture 1/6 — foundation
--   * Business-day helpers in the company timezone (Africa/Cairo by default)
--   * Remove rigid accounting-period closing / locking
--   * Schema for carry-forward debts (partner tabs, advances, penalties)
--   * Schema for on-demand payouts and the development-fund ledger
-- Historical rows are kept; accounting_periods stays as read-only history.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Business-day helpers. Every date filter in money functions goes
--    through these so a sale at 01:30 Cairo time lands on the right day.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.company_tz(_company uuid DEFAULT NULL)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT COALESCE(NULLIF((SELECT c.timezone FROM public.companies c
                          WHERE c.id = COALESCE(_company, public.current_company_id())), ''),
                  'Africa/Cairo')
$$;

-- Start instant of a business day (inclusive lower bound for timestamptz filters).
CREATE OR REPLACE FUNCTION public.business_day_start(_day date, _company uuid DEFAULT NULL)
RETURNS timestamptz LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT (_day::timestamp AT TIME ZONE public.company_tz(_company))
$$;

CREATE OR REPLACE FUNCTION public.business_date(_ts timestamptz, _company uuid DEFAULT NULL)
RETURNS date LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT (_ts AT TIME ZONE public.company_tz(_company))::date
$$;

CREATE OR REPLACE FUNCTION public.business_today(_company uuid DEFAULT NULL)
RETURNS date LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT public.business_date(now(), _company)
$$;

REVOKE ALL ON FUNCTION public.company_tz(uuid), public.business_day_start(date, uuid),
  public.business_date(timestamptz, uuid), public.business_today(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.company_tz(uuid), public.business_day_start(date, uuid),
  public.business_date(timestamptz, uuid), public.business_today(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------
-- 2) Remove period locking.
-- ---------------------------------------------------------------------
-- Guard triggers on orders, expenses, purchases, stock, salaries, attendance, ...
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT t.tgname, t.tgrelid::regclass AS tbl
    FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
    WHERE NOT t.tgisinternal AND p.proname = 'block_closed_period_entry'
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', r.tgname, r.tbl);
  END LOOP;
END $$;
DROP FUNCTION IF EXISTS public.block_closed_period_entry();

-- Kept as a no-op: several treasury / purchase functions still call it.
CREATE OR REPLACE FUNCTION public.assert_period_open(_company_id uuid, _date date)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  RETURN;  -- Period locking was retired; payouts are now protected by range snapshots.
END $$;

-- Daily period jobs.
DO $$ BEGIN PERFORM cron.unschedule('ensure-open-periods'); EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN PERFORM cron.unschedule('notify-periods-due');  EXCEPTION WHEN OTHERS THEN NULL; END $$;

-- Period RPCs and period-based finance functions (all overloads, both schemas).
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname IN ('public', 'private')
      AND p.proname = ANY (ARRAY[
        'initialize_accounting_period', 'update_accounting_period', 'close_accounting_period',
        'reopen_accounting_period', 'override_locked_period', 'relock_period', 'create_adjustment_period',
        'delete_accounting_period', 'ensure_open_periods', 'notify_periods_due',
        'freeze_profit_distribution', 'toggle_partner_freeze', 'trg_pause_on_freeze',
        'period_pnl', 'period_distribution', 'period_manager_salaries', 'period_financial_kpis',
        'distribute_period_profit', 'financial_self_sustainability', 'reverse_period_dividend_payouts',
        'payout_partner_dividend', 'payout_partner_combined', 'run_month_simulation'
      ])
  LOOP
    EXECUTE 'DROP FUNCTION ' || r.sig || ' CASCADE';
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 3) Carry-forward debts.
-- ---------------------------------------------------------------------
-- Partner tabs: partially settled tabs keep their remaining balance.
ALTER TABLE public.partner_tab_orders
  ADD COLUMN IF NOT EXISTS settled_amount numeric(14,2) NOT NULL DEFAULT 0;
UPDATE public.partner_tab_orders SET settled_amount = total_amount
 WHERE is_settled AND settled_amount = 0;
ALTER TABLE public.partner_tab_orders DROP CONSTRAINT IF EXISTS partner_tab_orders_settled_amount_check;
ALTER TABLE public.partner_tab_orders ADD CONSTRAINT partner_tab_orders_settled_amount_check
  CHECK (settled_amount >= 0 AND settled_amount <= total_amount + 0.005);

-- Employee advances and staff penalties: partially deducted amounts carry forward.
ALTER TABLE public.employee_advances
  ADD COLUMN IF NOT EXISTS deducted_amount numeric(14,2) NOT NULL DEFAULT 0;
UPDATE public.employee_advances SET deducted_amount = amount
 WHERE settled_payment_id IS NOT NULL AND deducted_amount = 0;

ALTER TABLE public.staff_penalties
  ADD COLUMN IF NOT EXISTS deducted_amount numeric(14,2) NOT NULL DEFAULT 0;
UPDATE public.staff_penalties SET deducted_amount = amount
 WHERE is_settled AND deducted_amount = 0;

-- Salary lines keep each deduction separately so P&L can use the true labour cost.
ALTER TABLE public.salary_payments
  ADD COLUMN IF NOT EXISTS absence_deduction numeric(14,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS penalty_deduction numeric(14,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS advance_deduction numeric(14,2) NOT NULL DEFAULT 0;

-- Back-fill legacy lines: advances / penalties already linked to a salary line.
UPDATE public.salary_payments sp SET
  advance_deduction = LEAST(sp.deduction, COALESCE((
    SELECT SUM(a.amount) FROM public.employee_advances a
     WHERE a.settled_payment_id = sp.id AND a.status = 'active'), 0)),
  penalty_deduction = LEAST(sp.deduction, COALESCE((
    SELECT SUM(p.amount) FROM public.staff_penalties p WHERE p.payroll_id = sp.id), 0))
WHERE sp.advance_deduction = 0 AND sp.penalty_deduction = 0 AND sp.deduction > 0;
UPDATE public.salary_payments sp SET
  penalty_deduction = LEAST(sp.penalty_deduction, GREATEST(sp.deduction - sp.advance_deduction, 0)),
  absence_deduction = GREATEST(sp.deduction - sp.advance_deduction
                               - LEAST(sp.penalty_deduction, GREATEST(sp.deduction - sp.advance_deduction, 0)), 0)
WHERE sp.deduction > 0 AND sp.absence_deduction = 0;

-- Exact link between a salary line and every advance / penalty it recovered.
CREATE TABLE IF NOT EXISTS public.payroll_deductions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  salary_payment_id uuid NOT NULL REFERENCES public.salary_payments(id) ON DELETE CASCADE,
  source_type text NOT NULL CHECK (source_type IN ('advance', 'penalty')),
  source_id uuid NOT NULL,
  amount numeric(14,2) NOT NULL CHECK (amount > 0),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS payroll_deductions_salary_idx ON public.payroll_deductions(salary_payment_id);
CREATE INDEX IF NOT EXISTS payroll_deductions_source_idx ON public.payroll_deductions(source_type, source_id);
ALTER TABLE public.payroll_deductions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS payroll_deductions_select ON public.payroll_deductions;
CREATE POLICY payroll_deductions_select ON public.payroll_deductions FOR SELECT TO authenticated
  USING (company_id = public.current_company_id() AND (public.has_permission('payroll.view') OR public.is_super_admin()));
GRANT SELECT ON public.payroll_deductions TO authenticated;
GRANT ALL ON public.payroll_deductions TO service_role;

-- ---------------------------------------------------------------------
-- 4) On-demand payouts (profit_distributions now cover a date range).
-- ---------------------------------------------------------------------
ALTER TABLE public.profit_distributions ALTER COLUMN period_id DROP NOT NULL;
ALTER TABLE public.profit_distributions
  ADD COLUMN IF NOT EXISTS range_from date,
  ADD COLUMN IF NOT EXISTS range_to date,
  ADD COLUMN IF NOT EXISTS pnl_snapshot jsonb,
  ADD COLUMN IF NOT EXISTS management_salary numeric(14,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS reserve_amount numeric(14,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS tab_deducted numeric(14,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS notes text,
  ADD COLUMN IF NOT EXISTS reversed_at timestamptz,
  ADD COLUMN IF NOT EXISTS reversed_by uuid,
  ADD COLUMN IF NOT EXISTS reverse_reason text;

-- Legacy period-based distributions keep their covered range for overlap checks.
UPDATE public.profit_distributions d
   SET range_from = ap.start_date, range_to = ap.end_date
  FROM public.accounting_periods ap
 WHERE ap.id = d.period_id AND d.range_from IS NULL;

ALTER TABLE public.profit_distributions DROP CONSTRAINT IF EXISTS profit_distributions_range_check;
ALTER TABLE public.profit_distributions ADD CONSTRAINT profit_distributions_range_check
  CHECK (range_from IS NULL OR range_to >= range_from);
CREATE INDEX IF NOT EXISTS profit_distributions_range_idx
  ON public.profit_distributions(company_id, range_from, range_to) WHERE status = 'active';

ALTER TABLE public.partner_dividend_payouts ALTER COLUMN period_id DROP NOT NULL;

-- Which tab orders (and how much of each) a payout settled — used to reverse exactly.
CREATE TABLE IF NOT EXISTS public.partner_tab_settlements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  distribution_id uuid NOT NULL REFERENCES public.profit_distributions(id),
  tab_order_id uuid NOT NULL REFERENCES public.partner_tab_orders(id),
  partner_id uuid NOT NULL REFERENCES public.partners(id),
  amount numeric(14,2) NOT NULL CHECK (amount > 0),
  status public.record_status NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS partner_tab_settlements_dist_idx ON public.partner_tab_settlements(distribution_id);
ALTER TABLE public.partner_tab_settlements ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS partner_tab_settlements_select ON public.partner_tab_settlements;
CREATE POLICY partner_tab_settlements_select ON public.partner_tab_settlements FOR SELECT TO authenticated
  USING (company_id = public.current_company_id()
         AND (public.has_permission('partners.view') OR public.is_super_admin()
              OR partner_id = public.current_partner_id()));
GRANT SELECT ON public.partner_tab_settlements TO authenticated;
GRANT ALL ON public.partner_tab_settlements TO service_role;

-- ---------------------------------------------------------------------
-- 5) Development / maintenance fund ledger (money set aside before payouts).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.development_fund_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  direction text NOT NULL CHECK (direction IN ('in', 'out')),
  amount numeric(14,2) NOT NULL CHECK (amount > 0),
  distribution_id uuid REFERENCES public.profit_distributions(id),
  entry_date date NOT NULL DEFAULT CURRENT_DATE,
  description text,
  status public.record_status NOT NULL DEFAULT 'active',
  reversal_of uuid REFERENCES public.development_fund_ledger(id),
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS development_fund_ledger_company_idx ON public.development_fund_ledger(company_id, entry_date);
ALTER TABLE public.development_fund_ledger ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS development_fund_ledger_select ON public.development_fund_ledger;
CREATE POLICY development_fund_ledger_select ON public.development_fund_ledger FOR SELECT TO authenticated
  USING (company_id = public.current_company_id()
         AND (public.has_permission('reports.profit') OR public.has_permission('partners.view_profit') OR public.is_super_admin()));
GRANT SELECT ON public.development_fund_ledger TO authenticated;
GRANT ALL ON public.development_fund_ledger TO service_role;

-- Funds already reserved by earlier distributions.
INSERT INTO public.development_fund_ledger (company_id, direction, amount, distribution_id, entry_date, description, created_by)
SELECT d.company_id, 'in', d.development_fund_amount, d.id, COALESCE(d.distributed_at::date, d.created_at::date),
       'Development fund reserved at profit distribution', d.created_by
  FROM public.profit_distributions d
 WHERE d.status = 'active' AND d.development_fund_amount > 0
   AND NOT EXISTS (SELECT 1 FROM public.development_fund_ledger f WHERE f.distribution_id = d.id);

CREATE OR REPLACE FUNCTION public.development_fund_balance()
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT round(COALESCE(SUM(CASE WHEN direction = 'in' THEN amount ELSE -amount END), 0), 2)
    FROM public.development_fund_ledger
   WHERE company_id = public.current_company_id() AND status = 'active'
$$;
REVOKE ALL ON FUNCTION public.development_fund_balance() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.development_fund_balance() TO authenticated;

-- Spend from the fund (maintenance, equipment). Optionally pays it from a treasury account.
CREATE OR REPLACE FUNCTION public.spend_development_fund(_amount numeric, _description text, _account_id uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _company uuid := public.current_company_id(); _profile uuid := public.current_profile_id();
  _bal numeric; _id uuid; _amt numeric := round(COALESCE(_amount, 0), 2);
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only a super admin can spend from the development fund'; END IF;
  IF _amt <= 0 THEN RAISE EXCEPTION 'Amount must be greater than zero'; END IF;
  IF length(btrim(COALESCE(_description, ''))) < 3 THEN RAISE EXCEPTION 'A description is required'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('dev_fund:' || _company::text));
  _bal := public.development_fund_balance();
  IF _amt > _bal THEN RAISE EXCEPTION 'The development fund only has %', _bal; END IF;
  INSERT INTO public.development_fund_ledger (company_id, direction, amount, entry_date, description, created_by)
  VALUES (_company, 'out', _amt, public.business_today(_company), btrim(_description), _profile)
  RETURNING id INTO _id;
  IF _account_id IS NOT NULL THEN
    PERFORM public.post_cash_txn(_company, _account_id, 'out', _amt, 'development_fund', 'cash',
      public.business_today(_company), 'development_fund', _id, btrim(_description));
  END IF;
  PERFORM public.log_audit('finance.development_fund_spend', 'finance', 'development_fund_ledger', _id, NULL,
    jsonb_build_object('amount', _amt, 'balance_before', _bal), btrim(_description), NULL);
  RETURN _id;
END $$;
REVOKE ALL ON FUNCTION public.spend_development_fund(numeric, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.spend_development_fund(numeric, text, uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 6) Partner advances (سلف): money paid to a partner ahead of profit,
--    recovered from their next payouts (oldest first, carried forward).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.partner_advances (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  partner_id uuid NOT NULL REFERENCES public.partners(id),
  amount numeric(14,2) NOT NULL CHECK (amount > 0),
  deducted_amount numeric(14,2) NOT NULL DEFAULT 0 CHECK (deducted_amount >= 0),
  advance_date date NOT NULL DEFAULT CURRENT_DATE,
  method text NOT NULL DEFAULT 'cash',
  reason text,
  cash_transaction_id uuid,
  status public.record_status NOT NULL DEFAULT 'active',
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT partner_advances_deducted_le_amount CHECK (deducted_amount <= amount + 0.005)
);
CREATE INDEX IF NOT EXISTS partner_advances_partner_idx ON public.partner_advances(partner_id, advance_date);
ALTER TABLE public.partner_advances ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS partner_advances_select ON public.partner_advances;
CREATE POLICY partner_advances_select ON public.partner_advances FOR SELECT TO authenticated
  USING (company_id = public.current_company_id()
         AND (public.has_permission('partners.view') OR public.is_super_admin() OR partner_id = public.current_partner_id()));
GRANT SELECT ON public.partner_advances TO authenticated;
GRANT ALL ON public.partner_advances TO service_role;

CREATE TABLE IF NOT EXISTS public.partner_advance_settlements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  distribution_id uuid NOT NULL REFERENCES public.profit_distributions(id),
  advance_id uuid NOT NULL REFERENCES public.partner_advances(id),
  partner_id uuid NOT NULL REFERENCES public.partners(id),
  amount numeric(14,2) NOT NULL CHECK (amount > 0),
  status public.record_status NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS partner_advance_settlements_dist_idx ON public.partner_advance_settlements(distribution_id);
ALTER TABLE public.partner_advance_settlements ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS partner_advance_settlements_select ON public.partner_advance_settlements;
CREATE POLICY partner_advance_settlements_select ON public.partner_advance_settlements FOR SELECT TO authenticated
  USING (company_id = public.current_company_id()
         AND (public.has_permission('partners.view') OR public.is_super_admin() OR partner_id = public.current_partner_id()));
GRANT SELECT ON public.partner_advance_settlements TO authenticated;
GRANT ALL ON public.partner_advance_settlements TO service_role;
