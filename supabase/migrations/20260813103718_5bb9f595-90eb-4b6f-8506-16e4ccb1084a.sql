-- EXPENSE CATEGORIES
CREATE TABLE public.expense_categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  name text NOT NULL,
  name_ar text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE ON public.expense_categories TO authenticated;
GRANT ALL ON public.expense_categories TO service_role;
ALTER TABLE public.expense_categories ENABLE ROW LEVEL SECURITY;
CREATE POLICY "expense_categories_select" ON public.expense_categories FOR SELECT TO authenticated
  USING (company_id = public.current_company_id() AND (public.has_permission('expenses.view') OR public.is_super_admin()));
CREATE POLICY "expense_categories_insert" ON public.expense_categories FOR INSERT TO authenticated
  WITH CHECK (company_id = public.current_company_id() AND (public.has_permission('expenses.edit') OR public.is_super_admin()));
CREATE POLICY "expense_categories_update" ON public.expense_categories FOR UPDATE TO authenticated
  USING (company_id = public.current_company_id() AND (public.has_permission('expenses.edit') OR public.is_super_admin()));
CREATE TRIGGER t_expense_categories_upd BEFORE UPDATE ON public.expense_categories FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- EXPENSES
CREATE TABLE public.expenses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  branch_id uuid REFERENCES public.branches(id),
  category_id uuid REFERENCES public.expense_categories(id),
  amount numeric NOT NULL CHECK (amount > 0),
  expense_date date NOT NULL DEFAULT CURRENT_DATE,
  payment_method text,
  vendor text,
  description text,
  status public.record_status NOT NULL DEFAULT 'active',
  approved_by uuid REFERENCES public.user_profiles(id),
  approved_at timestamptz,
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE ON public.expenses TO authenticated;
GRANT ALL ON public.expenses TO service_role;
ALTER TABLE public.expenses ENABLE ROW LEVEL SECURITY;
CREATE POLICY "expenses_select" ON public.expenses FOR SELECT TO authenticated
  USING (company_id = public.current_company_id()
    AND (public.has_permission('expenses.view') OR public.is_super_admin())
    AND public.can_access_branch(branch_id));
CREATE POLICY "expenses_insert" ON public.expenses FOR INSERT TO authenticated
  WITH CHECK (company_id = public.current_company_id()
    AND (public.has_permission('expenses.create') OR public.is_super_admin())
    AND public.can_access_branch(branch_id));
CREATE POLICY "expenses_update" ON public.expenses FOR UPDATE TO authenticated
  USING (company_id = public.current_company_id()
    AND (public.has_permission('expenses.edit') OR public.has_permission('expenses.approve') OR public.is_super_admin())
    AND public.can_access_branch(branch_id));
CREATE TRIGGER t_expenses_upd BEFORE UPDATE ON public.expenses FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER t_expenses_no_delete BEFORE DELETE ON public.expenses FOR EACH ROW EXECUTE FUNCTION public.forbid_hard_delete();
CREATE INDEX idx_expenses_date ON public.expenses (company_id, expense_date DESC);

-- EMPLOYEE SALARIES
CREATE TABLE public.employee_salaries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  user_id uuid NOT NULL REFERENCES public.user_profiles(id),
  base_salary numeric NOT NULL CHECK (base_salary >= 0),
  effective_from date NOT NULL DEFAULT CURRENT_DATE,
  is_active boolean NOT NULL DEFAULT true,
  notes text,
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE ON public.employee_salaries TO authenticated;
GRANT ALL ON public.employee_salaries TO service_role;
ALTER TABLE public.employee_salaries ENABLE ROW LEVEL SECURITY;
CREATE POLICY "employee_salaries_select" ON public.employee_salaries FOR SELECT TO authenticated
  USING (company_id = public.current_company_id()
    AND (public.has_permission('payroll.view') OR public.is_super_admin() OR user_id = public.current_profile_id()));
CREATE POLICY "employee_salaries_insert" ON public.employee_salaries FOR INSERT TO authenticated
  WITH CHECK (company_id = public.current_company_id() AND (public.has_permission('payroll.manage') OR public.is_super_admin()));
CREATE POLICY "employee_salaries_update" ON public.employee_salaries FOR UPDATE TO authenticated
  USING (company_id = public.current_company_id() AND (public.has_permission('payroll.manage') OR public.is_super_admin()));
CREATE TRIGGER t_employee_salaries_upd BEFORE UPDATE ON public.employee_salaries FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- SALARY PAYMENTS
CREATE TABLE public.salary_payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  user_id uuid NOT NULL REFERENCES public.user_profiles(id),
  period_start date NOT NULL,
  period_end date NOT NULL,
  base_amount numeric NOT NULL DEFAULT 0 CHECK (base_amount >= 0),
  bonus numeric NOT NULL DEFAULT 0 CHECK (bonus >= 0),
  deduction numeric NOT NULL DEFAULT 0 CHECK (deduction >= 0),
  net_amount numeric NOT NULL DEFAULT 0,
  status public.record_status NOT NULL DEFAULT 'active',
  paid_at timestamptz,
  paid_by uuid REFERENCES public.user_profiles(id),
  notes text,
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE ON public.salary_payments TO authenticated;
GRANT ALL ON public.salary_payments TO service_role;
ALTER TABLE public.salary_payments ENABLE ROW LEVEL SECURITY;
CREATE POLICY "salary_payments_select" ON public.salary_payments FOR SELECT TO authenticated
  USING (company_id = public.current_company_id()
    AND (public.has_permission('payroll.view') OR public.is_super_admin() OR user_id = public.current_profile_id()));
CREATE POLICY "salary_payments_insert" ON public.salary_payments FOR INSERT TO authenticated
  WITH CHECK (company_id = public.current_company_id() AND (public.has_permission('payroll.manage') OR public.is_super_admin()));
CREATE POLICY "salary_payments_update" ON public.salary_payments FOR UPDATE TO authenticated
  USING (company_id = public.current_company_id()
    AND (public.has_permission('payroll.manage') OR public.has_permission('payroll.approve') OR public.is_super_admin()));
CREATE TRIGGER t_salary_payments_upd BEFORE UPDATE ON public.salary_payments FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER t_salary_payments_no_delete BEFORE DELETE ON public.salary_payments FOR EACH ROW EXECUTE FUNCTION public.forbid_hard_delete();

CREATE OR REPLACE FUNCTION public.set_salary_net()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  NEW.net_amount := COALESCE(NEW.base_amount,0) + COALESCE(NEW.bonus,0) - COALESCE(NEW.deduction,0);
  IF NEW.net_amount < 0 THEN RAISE EXCEPTION 'Net salary cannot be negative'; END IF;
  IF NEW.period_end < NEW.period_start THEN RAISE EXCEPTION 'Invalid salary period'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER t_salary_net BEFORE INSERT OR UPDATE ON public.salary_payments FOR EACH ROW EXECUTE FUNCTION public.set_salary_net();

-- SEED CATEGORIES
INSERT INTO public.expense_categories (company_id, name, name_ar)
SELECT c.id, v.name, v.name_ar
FROM public.companies c,
  (VALUES ('Rent','إيجار'),('Utilities','فواتير ومرافق'),('Salaries','رواتب'),
          ('Maintenance','صيانة'),('Marketing','تسويق'),('Supplies','مستلزمات'),('Other','أخرى')) AS v(name, name_ar)
WHERE c.is_active;

-- PERIOD P&L
CREATE OR REPLACE FUNCTION public.period_pnl(_period_id uuid)
RETURNS TABLE(revenue numeric, cogs numeric, expenses_total numeric, payroll_total numeric, net_profit numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE _p public.accounting_periods; _rev numeric := 0; _cogs numeric := 0; _exp numeric := 0; _pay numeric := 0;
BEGIN
  IF NOT (public.has_permission('reports.profit') OR public.has_permission('partners.view_profit') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  SELECT * INTO _p FROM public.accounting_periods WHERE id = _period_id AND company_id = public.current_company_id();
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Period not found'; END IF;

  SELECT COALESCE(SUM(o.total),0) INTO _rev FROM public.orders o
  WHERE o.company_id = _p.company_id AND o.status = 'completed'
    AND o.created_at::date BETWEEN _p.start_date AND _p.end_date;

  SELECT COALESCE(SUM(oi.unit_cost * oi.quantity),0) INTO _cogs
  FROM public.order_items oi JOIN public.orders o ON o.id = oi.order_id
  WHERE o.company_id = _p.company_id AND o.status = 'completed' AND oi.status = 'active'
    AND o.created_at::date BETWEEN _p.start_date AND _p.end_date;

  SELECT COALESCE(SUM(e.amount),0) INTO _exp FROM public.expenses e
  WHERE e.company_id = _p.company_id AND e.status = 'active'
    AND e.expense_date BETWEEN _p.start_date AND _p.end_date;

  SELECT COALESCE(SUM(s.net_amount),0) INTO _pay FROM public.salary_payments s
  WHERE s.company_id = _p.company_id AND s.status = 'active'
    AND s.period_start BETWEEN _p.start_date AND _p.end_date;

  RETURN QUERY SELECT round(_rev,2), round(_cogs,2), round(_exp,2), round(_pay,2),
    round(_rev - _cogs - _exp - _pay, 2);
END $$;

-- DISTRIBUTE PROFIT
CREATE OR REPLACE FUNCTION public.distribute_period_profit(_period_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  _p public.accounting_periods; _profile uuid := public.current_profile_id();
  _net numeric; _currency text; _dist uuid; _capital numeric; _r record; _txn uuid; _pct numeric; _amount numeric;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('partners.manage_profit_distribution') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  SELECT * INTO _p FROM public.accounting_periods WHERE id = _period_id AND company_id = public.current_company_id();
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Period not found'; END IF;
  IF _p.status <> 'closed' THEN RAISE EXCEPTION 'Close the accounting period before distributing profit'; END IF;
  IF EXISTS (SELECT 1 FROM public.profit_distributions d WHERE d.period_id = _period_id AND d.status = 'active') THEN
    RAISE EXCEPTION 'Profit for this period has already been distributed';
  END IF;

  SELECT net_profit INTO _net FROM public.period_pnl(_period_id);
  IF _net IS NULL OR _net <= 0 THEN RAISE EXCEPTION 'There is no profit to distribute for this period'; END IF;

  SELECT currency INTO _currency FROM public.companies WHERE id = _p.company_id;

  SELECT COALESCE(SUM(cc.amount),0) INTO _capital
  FROM public.partner_capital_contributions cc
  JOIN public.partners pa ON pa.id = cc.partner_id
  WHERE cc.company_id = _p.company_id AND cc.status = 'active' AND pa.status = 'active';
  IF _capital <= 0 THEN RAISE EXCEPTION 'Partner capital contributions are required before distributing profit'; END IF;

  INSERT INTO public.profit_distributions (company_id, period_id, net_profit, currency, status, distributed_at, created_by)
  VALUES (_p.company_id, _period_id, _net, _currency, 'active', now(), _profile)
  RETURNING id INTO _dist;

  FOR _r IN
    SELECT pa.id AS partner_id, COALESCE(SUM(cc.amount),0) AS capital
    FROM public.partners pa
    LEFT JOIN public.partner_capital_contributions cc ON cc.partner_id = pa.id AND cc.status = 'active'
    WHERE pa.company_id = _p.company_id AND pa.status = 'active'
    GROUP BY pa.id
    HAVING COALESCE(SUM(cc.amount),0) > 0
  LOOP
    _pct := round((_r.capital / _capital) * 100, 4);
    _amount := round(_net * (_r.capital / _capital), 2);

    INSERT INTO public.partner_ledger_transactions (company_id, partner_id, transaction_type, amount, currency,
      reference_type, reference_id, description, transaction_date, status, created_by)
    VALUES (_p.company_id, _r.partner_id, 'profit_distribution', _amount, _currency,
      'profit_distribution', _dist, 'Profit distribution', _p.end_date, 'active', _profile)
    RETURNING id INTO _txn;

    INSERT INTO public.profit_distribution_lines (distribution_id, partner_id, ownership_percentage, amount, ledger_transaction_id)
    VALUES (_dist, _r.partner_id, _pct, _amount, _txn);
  END LOOP;

  PERFORM public.log_audit('finance.distribute_profit','partners','profit_distributions',_dist,NULL,
    jsonb_build_object('net_profit',_net,'period_id',_period_id),NULL,NULL);
  RETURN _dist;
END $$;