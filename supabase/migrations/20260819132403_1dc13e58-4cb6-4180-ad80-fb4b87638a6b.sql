-- ============ 1) CASH ACCOUNTS ============
CREATE TABLE public.cash_accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  key text NOT NULL,
  name text NOT NULL,
  name_ar text,
  account_type text NOT NULL DEFAULT 'cash',
  opening_balance numeric(14,2) NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  is_default boolean NOT NULL DEFAULT false,
  notes text,
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (company_id, key)
);

GRANT SELECT, INSERT, UPDATE ON public.cash_accounts TO authenticated;
GRANT ALL ON public.cash_accounts TO service_role;
ALTER TABLE public.cash_accounts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "cash_accounts_select" ON public.cash_accounts FOR SELECT TO authenticated
USING (company_id = public.current_company_id()
  AND (public.has_permission('treasury.view') OR public.is_super_admin()));
CREATE POLICY "cash_accounts_insert" ON public.cash_accounts FOR INSERT TO authenticated
WITH CHECK (company_id = public.current_company_id()
  AND (public.has_permission('treasury.manage') OR public.is_super_admin()));
CREATE POLICY "cash_accounts_update" ON public.cash_accounts FOR UPDATE TO authenticated
USING (company_id = public.current_company_id()
  AND (public.has_permission('treasury.manage') OR public.is_super_admin()));

CREATE TRIGGER trg_cash_accounts_updated BEFORE UPDATE ON public.cash_accounts
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ============ 2) CASH TRANSACTIONS ============
CREATE TABLE public.cash_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  account_id uuid NOT NULL REFERENCES public.cash_accounts(id),
  direction text NOT NULL CHECK (direction IN ('in','out')),
  amount numeric(14,2) NOT NULL CHECK (amount > 0),
  method text NOT NULL DEFAULT 'cash',
  category text NOT NULL,
  txn_date date NOT NULL DEFAULT CURRENT_DATE,
  reference_type text,
  reference_id uuid,
  transfer_group uuid,
  description text,
  status public.record_status NOT NULL DEFAULT 'active',
  reversal_of uuid REFERENCES public.cash_transactions(id),
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_cash_txn_company_date ON public.cash_transactions (company_id, txn_date DESC);
CREATE INDEX idx_cash_txn_account ON public.cash_transactions (account_id);

GRANT SELECT ON public.cash_transactions TO authenticated;
GRANT ALL ON public.cash_transactions TO service_role;
ALTER TABLE public.cash_transactions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "cash_transactions_select" ON public.cash_transactions FOR SELECT TO authenticated
USING (company_id = public.current_company_id()
  AND (public.has_permission('treasury.view') OR public.is_super_admin()));

CREATE TRIGGER trg_cash_txn_no_delete BEFORE DELETE ON public.cash_transactions
FOR EACH ROW EXECUTE FUNCTION public.forbid_hard_delete();

-- ============ 3) PERMISSIONS ============
INSERT INTO public.permissions (key, name, description, module) VALUES
  ('treasury.view','View treasury','See cash accounts and cash movements','treasury'),
  ('treasury.manage','Manage treasury','Deposit, spend and transfer cash','treasury')
ON CONFLICT (key) DO NOTHING;

INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM public.roles r, public.permissions p
WHERE p.key IN ('treasury.view','treasury.manage') AND r.key IN ('super_admin','accountant')
ON CONFLICT DO NOTHING;

INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM public.roles r, public.permissions p
WHERE p.key = 'treasury.view' AND r.key = 'manager'
ON CONFLICT DO NOTHING;

-- ============ 4) DEFAULT ACCOUNTS PER COMPANY ============
INSERT INTO public.cash_accounts (company_id, key, name, name_ar, account_type, is_default)
SELECT c.id, 'main_cash', 'Main Cash Box', 'الخزنة الرئيسية', 'cash', true FROM public.companies c
ON CONFLICT DO NOTHING;
INSERT INTO public.cash_accounts (company_id, key, name, name_ar, account_type)
SELECT c.id, 'bank', 'Bank / Card', 'البنك / الفيزا', 'bank' FROM public.companies c
ON CONFLICT DO NOTHING;
INSERT INTO public.cash_accounts (company_id, key, name, name_ar, account_type)
SELECT c.id, 'wallet', 'E-Wallet', 'المحفظة الإلكترونية', 'wallet' FROM public.companies c
ON CONFLICT DO NOTHING;

-- ============ 5) CORE TREASURY FUNCTIONS ============
CREATE OR REPLACE FUNCTION public.cash_balance(_account_id uuid)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT round(COALESCE((SELECT opening_balance FROM public.cash_accounts WHERE id = _account_id),0)
    + COALESCE((SELECT SUM(CASE WHEN direction = 'in' THEN amount ELSE -amount END)
        FROM public.cash_transactions WHERE account_id = _account_id AND status = 'active'),0), 2)
$$;

CREATE OR REPLACE FUNCTION public.default_cash_account(_company_id uuid, _method text DEFAULT 'cash')
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT id FROM public.cash_accounts
   WHERE company_id = _company_id AND is_active
     AND key = CASE
       WHEN lower(COALESCE(_method,'cash')) IN ('card','visa','bank','transfer','bank_transfer') THEN 'bank'
       WHEN lower(COALESCE(_method,'cash')) IN ('wallet','instapay','vodafone_cash','e_wallet') THEN 'wallet'
       ELSE 'main_cash' END
   LIMIT 1
$$;

CREATE OR REPLACE FUNCTION public.post_cash_txn(
  _company_id uuid, _account_id uuid, _direction text, _amount numeric, _category text,
  _method text DEFAULT 'cash', _txn_date date DEFAULT CURRENT_DATE,
  _reference_type text DEFAULT NULL, _reference_id uuid DEFAULT NULL,
  _description text DEFAULT NULL, _transfer_group uuid DEFAULT NULL, _enforce_balance boolean DEFAULT true)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _id uuid; _acc public.cash_accounts; _bal numeric;
BEGIN
  IF COALESCE(_amount,0) <= 0 THEN RAISE EXCEPTION 'Amount must be greater than zero'; END IF;
  SELECT * INTO _acc FROM public.cash_accounts WHERE id = _account_id AND company_id = _company_id;
  IF _acc.id IS NULL THEN RAISE EXCEPTION 'Cash account not found'; END IF;
  IF NOT _acc.is_active THEN RAISE EXCEPTION 'Cash account is inactive'; END IF;
  PERFORM public.assert_period_open(_company_id, COALESCE(_txn_date, CURRENT_DATE));

  IF _direction = 'out' AND _enforce_balance THEN
    _bal := public.cash_balance(_account_id);
    IF round(_amount,2) > _bal THEN
      RAISE EXCEPTION 'Not enough balance in this account (available %)', _bal;
    END IF;
  END IF;

  INSERT INTO public.cash_transactions (company_id, account_id, direction, amount, method, category,
    txn_date, reference_type, reference_id, description, transfer_group, created_by)
  VALUES (_company_id, _account_id, _direction, round(_amount,2), COALESCE(NULLIF(_method,''),'cash'), _category,
    COALESCE(_txn_date, CURRENT_DATE), _reference_type, _reference_id, NULLIF(_description,''), _transfer_group,
    public.current_profile_id())
  RETURNING id INTO _id;
  RETURN _id;
END $$;

CREATE OR REPLACE FUNCTION public.treasury_entry(
  _account_id uuid, _direction text, _amount numeric, _method text,
  _txn_date date, _description text, _category text DEFAULT 'manual')
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _company uuid := public.current_company_id(); _id uuid;
BEGIN
  IF public.current_profile_id() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('treasury.manage') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF _direction NOT IN ('in','out') THEN RAISE EXCEPTION 'Invalid direction'; END IF;
  _id := public.post_cash_txn(_company, _account_id, _direction, _amount,
    COALESCE(NULLIF(_category,''),'manual'), _method, _txn_date, 'manual', NULL, _description);
  PERFORM public.log_audit('treasury.' || _direction, 'treasury', 'cash_transactions', _id, NULL,
    jsonb_build_object('amount', _amount, 'method', _method), _description, NULL);
  RETURN _id;
END $$;

CREATE OR REPLACE FUNCTION public.transfer_cash(
  _from_account uuid, _to_account uuid, _amount numeric,
  _txn_date date DEFAULT CURRENT_DATE, _description text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _company uuid := public.current_company_id(); _group uuid := gen_random_uuid();
BEGIN
  IF public.current_profile_id() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('treasury.manage') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF _from_account = _to_account THEN RAISE EXCEPTION 'Choose two different accounts'; END IF;
  PERFORM public.post_cash_txn(_company, _from_account, 'out', _amount, 'transfer_out', 'cash', _txn_date,
    'transfer', NULL, _description, _group);
  PERFORM public.post_cash_txn(_company, _to_account, 'in', _amount, 'transfer_in', 'cash', _txn_date,
    'transfer', NULL, _description, _group, false);
  PERFORM public.log_audit('treasury.transfer','treasury','cash_transactions', NULL, NULL,
    jsonb_build_object('amount',_amount,'from',_from_account,'to',_to_account), _description, NULL);
  RETURN _group;
END $$;

-- ============ 6) WIRE EXISTING FLOWS ============
CREATE OR REPLACE FUNCTION public.close_shift(_shift_id uuid, _closing_cash numeric, _notes text DEFAULT NULL::text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _s public.shifts; _expected numeric; _cash_in numeric := 0; _cash_out numeric := 0;
  _profile uuid := public.current_profile_id(); _acc uuid; _company uuid;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO _s FROM public.shifts WHERE id = _shift_id;
  IF _s.id IS NULL THEN RAISE EXCEPTION 'Shift not found'; END IF;
  IF _s.status = 'closed' THEN RAISE EXCEPTION 'Shift already closed'; END IF;
  IF NOT (public.has_permission('shifts.close') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF NOT public.can_access_branch(_s.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _s.user_id <> _profile AND NOT (public.has_permission('shifts.adjust_cash') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'You can only close your own shift';
  END IF;

  SELECT COALESCE(SUM(p.amount),0) INTO _cash_in
  FROM public.orders o JOIN public.order_payments p ON p.order_id = o.id
  WHERE o.shift_id = _shift_id AND o.status <> 'cancelled' AND p.method_key = 'cash';

  SELECT COALESCE(SUM(r.amount),0) INTO _cash_out
  FROM public.order_refunds r
  WHERE r.shift_id = _shift_id AND r.status = 'active' AND COALESCE(r.method_key,'cash') = 'cash';

  _expected := _s.opening_cash + _cash_in - _cash_out;

  UPDATE public.shifts SET status = 'closed', closing_cash = _closing_cash, expected_cash = _expected,
    variance = COALESCE(_closing_cash,0) - _expected, notes = _notes, closed_at = now(), closed_by = _profile
  WHERE id = _shift_id;

  -- Deposit the counted cash (minus the float the drawer keeps) into the main cash box
  SELECT company_id INTO _company FROM public.branches WHERE id = _s.branch_id;
  _acc := public.default_cash_account(_company, 'cash');
  IF _acc IS NOT NULL AND COALESCE(_closing_cash,0) - _s.opening_cash > 0 THEN
    PERFORM public.post_cash_txn(_company, _acc, 'in',
      round(COALESCE(_closing_cash,0) - _s.opening_cash, 2), 'shift_deposit', 'cash', CURRENT_DATE,
      'shift', _shift_id, 'Shift cash deposit', NULL, false);
  END IF;

  PERFORM public.log_audit('shift.close','pos','shifts',_shift_id,NULL,
    jsonb_build_object('closing_cash',_closing_cash,'expected_cash',_expected),_notes,_s.branch_id);
  RETURN _shift_id;
END $$;

CREATE OR REPLACE FUNCTION public.record_purchase_payment(_purchase_id uuid, _amount numeric, _method text DEFAULT NULL::text, _paid_at date DEFAULT CURRENT_DATE, _notes text DEFAULT NULL::text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _profile uuid := public.current_profile_id(); _p public.purchases; _due numeric; _id uuid; _acc uuid;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('purchases.create') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  SELECT * INTO _p FROM public.purchases WHERE id = _purchase_id AND company_id = public.current_company_id();
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Purchase not found'; END IF;
  IF _p.status = 'cancelled' THEN RAISE EXCEPTION 'This purchase is cancelled'; END IF;
  IF COALESCE(_amount,0) <= 0 THEN RAISE EXCEPTION 'Amount must be greater than zero'; END IF;
  PERFORM public.assert_period_open(_p.company_id, COALESCE(_paid_at, CURRENT_DATE));

  _due := round(_p.total - _p.returned_amount - _p.paid_amount, 2);
  IF round(_amount,2) > _due THEN
    RAISE EXCEPTION 'Payment exceeds the remaining balance (%)', _due;
  END IF;

  INSERT INTO public.purchase_payments (company_id, purchase_id, amount, method, paid_at, notes, created_by)
  VALUES (_p.company_id, _purchase_id, round(_amount,2), NULLIF(_method,''), COALESCE(_paid_at, CURRENT_DATE), NULLIF(_notes,''), _profile)
  RETURNING id INTO _id;

  UPDATE public.purchases SET paid_amount = round(paid_amount + round(_amount,2), 2) WHERE id = _purchase_id;

  _acc := public.default_cash_account(_p.company_id, _method);
  IF _acc IS NOT NULL THEN
    PERFORM public.post_cash_txn(_p.company_id, _acc, 'out', round(_amount,2), 'purchase_payment',
      COALESCE(NULLIF(_method,''),'cash'), COALESCE(_paid_at, CURRENT_DATE), 'purchase', _purchase_id,
      'Supplier payment', NULL, false);
  END IF;

  PERFORM public.log_audit('purchase.payment','purchases','purchases',_purchase_id, NULL,
    jsonb_build_object('amount', round(_amount,2), 'method', _method), _notes, _p.branch_id);
  RETURN _id;
END $$;

CREATE OR REPLACE FUNCTION public.approve_expense(_expense_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _profile uuid := public.current_profile_id(); _e public.expenses; _acc uuid;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('expenses.approve') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO _e FROM public.expenses
   WHERE id = _expense_id AND company_id = public.current_company_id();
  IF _e.id IS NULL THEN RAISE EXCEPTION 'Expense not found'; END IF;
  IF _e.status <> 'active' THEN RAISE EXCEPTION 'Only active expenses can be approved'; END IF;
  IF _e.approved_at IS NOT NULL THEN RAISE EXCEPTION 'Expense is already approved'; END IF;
  IF _e.branch_id IS NOT NULL AND NOT public.can_access_branch(_e.branch_id) THEN
    RAISE EXCEPTION 'Not authorized for this branch';
  END IF;

  UPDATE public.expenses SET approved_by = _profile, approved_at = now(), updated_at = now()
   WHERE id = _expense_id;

  _acc := public.default_cash_account(_e.company_id, _e.payment_method);
  IF _acc IS NOT NULL THEN
    PERFORM public.post_cash_txn(_e.company_id, _acc, 'out', _e.amount, 'expense',
      COALESCE(NULLIF(_e.payment_method,''),'cash'), _e.expense_date, 'expense', _expense_id,
      COALESCE(_e.description, 'Expense'), NULL, false);
  END IF;

  PERFORM public.log_audit('expense.approve','finance','expenses',_expense_id, NULL,
    jsonb_build_object('amount',_e.amount), NULL, _e.branch_id);
  RETURN _expense_id;
END $$;

CREATE OR REPLACE FUNCTION public.pay_salary(_salary_id uuid, _account_id uuid DEFAULT NULL, _method text DEFAULT 'cash')
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _profile uuid := public.current_profile_id(); _s public.salary_payments; _acc uuid;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('payroll.manage') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  SELECT * INTO _s FROM public.salary_payments WHERE id = _salary_id AND company_id = public.current_company_id();
  IF _s.id IS NULL THEN RAISE EXCEPTION 'Salary record not found'; END IF;
  IF _s.status <> 'active' THEN RAISE EXCEPTION 'This salary record is not active'; END IF;
  IF _s.paid_at IS NOT NULL THEN RAISE EXCEPTION 'This salary is already paid'; END IF;

  _acc := COALESCE(_account_id, public.default_cash_account(_s.company_id, _method));
  IF _acc IS NULL THEN RAISE EXCEPTION 'No cash account available'; END IF;

  UPDATE public.salary_payments SET paid_at = now(), paid_by = _profile, updated_at = now() WHERE id = _salary_id;

  PERFORM public.post_cash_txn(_s.company_id, _acc, 'out', _s.net_amount, 'salary', _method, CURRENT_DATE,
    'salary_payment', _salary_id, 'Salary payment');

  PERFORM public.log_audit('payroll.pay','finance','salary_payments',_salary_id, NULL,
    jsonb_build_object('amount',_s.net_amount,'method',_method), NULL, NULL);
  RETURN _salary_id;
END $$;

-- capital contributions add cash in
CREATE OR REPLACE FUNCTION public.capital_contribution_cash()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _acc uuid;
BEGIN
  IF NEW.status = 'active' THEN
    _acc := public.default_cash_account(NEW.company_id, NEW.payment_method);
    IF _acc IS NOT NULL THEN
      PERFORM public.post_cash_txn(NEW.company_id, _acc, 'in', NEW.amount, 'capital_contribution',
        COALESCE(NULLIF(NEW.payment_method,''),'cash'), NEW.contribution_date, 'capital_contribution', NEW.id,
        'Partner capital', NULL, false);
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_capital_contribution_cash AFTER INSERT ON public.partner_capital_contributions
FOR EACH ROW EXECUTE FUNCTION public.capital_contribution_cash();

-- ============ 7) PARTNER BALANCE + WITHDRAWAL REQUESTS ============
CREATE OR REPLACE FUNCTION public.partner_balance(_partner_id uuid)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT round(COALESCE(SUM(
    CASE WHEN t.transaction_type IN ('profit_distribution','capital_contribution') THEN t.amount
         WHEN t.transaction_type = 'withdrawal' THEN -abs(t.amount)
         ELSE t.amount END), 0), 2)
  FROM public.partner_ledger_transactions t
  WHERE t.partner_id = _partner_id AND t.status = 'active'
$$;

CREATE TABLE public.partner_withdrawal_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  partner_id uuid NOT NULL REFERENCES public.partners(id) ON DELETE CASCADE,
  amount numeric(14,2) NOT NULL CHECK (amount > 0),
  method text NOT NULL DEFAULT 'cash',
  notes text,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected','cancelled')),
  reviewed_by uuid REFERENCES public.user_profiles(id),
  reviewed_at timestamptz,
  review_note text,
  cash_transaction_id uuid REFERENCES public.cash_transactions(id),
  ledger_transaction_id uuid REFERENCES public.partner_ledger_transactions(id),
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT ON public.partner_withdrawal_requests TO authenticated;
GRANT ALL ON public.partner_withdrawal_requests TO service_role;
ALTER TABLE public.partner_withdrawal_requests ENABLE ROW LEVEL SECURITY;

CREATE POLICY "withdrawals_select" ON public.partner_withdrawal_requests FOR SELECT TO authenticated
USING (company_id = public.current_company_id()
  AND (partner_id = public.current_partner_id()
       OR public.has_permission('partners.manage_withdrawals')
       OR public.has_permission('partners.view')
       OR public.is_super_admin()));

CREATE TRIGGER trg_withdrawals_updated BEFORE UPDATE ON public.partner_withdrawal_requests
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE OR REPLACE FUNCTION public.request_partner_withdrawal(
  _amount numeric, _method text DEFAULT 'cash', _notes text DEFAULT NULL, _partner_id uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _profile uuid := public.current_profile_id(); _partner uuid; _company uuid := public.current_company_id();
  _balance numeric; _pending numeric; _id uuid; _name text;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  _partner := COALESCE(_partner_id, public.current_partner_id());
  IF _partner IS NULL THEN RAISE EXCEPTION 'You are not linked to a partner account'; END IF;
  IF _partner_id IS NOT NULL AND _partner_id <> COALESCE(public.current_partner_id(), '00000000-0000-0000-0000-000000000000'::uuid)
     AND NOT (public.has_permission('partners.manage_withdrawals') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF COALESCE(_amount,0) <= 0 THEN RAISE EXCEPTION 'Amount must be greater than zero'; END IF;

  SELECT name INTO _name FROM public.partners WHERE id = _partner AND company_id = _company;
  IF _name IS NULL THEN RAISE EXCEPTION 'Partner not found'; END IF;

  _balance := public.partner_balance(_partner);
  SELECT COALESCE(SUM(amount),0) INTO _pending FROM public.partner_withdrawal_requests
   WHERE partner_id = _partner AND status = 'pending';
  IF round(_amount,2) > round(_balance - _pending, 2) THEN
    RAISE EXCEPTION 'Amount exceeds your available balance (%)', round(_balance - _pending, 2);
  END IF;

  INSERT INTO public.partner_withdrawal_requests (company_id, partner_id, amount, method, notes, created_by)
  VALUES (_company, _partner, round(_amount,2), COALESCE(NULLIF(_method,''),'cash'), NULLIF(_notes,''), _profile)
  RETURNING id INTO _id;

  INSERT INTO public.notifications (company_id, required_permission, type, severity, title, body, data)
  VALUES (_company, 'partners.manage_withdrawals', 'partner_withdrawal', 'info',
    'Partner withdrawal request',
    _name || ' requested ' || round(_amount,2)::text,
    jsonb_build_object('request_id', _id, 'partner_id', _partner, 'amount', round(_amount,2)));

  PERFORM public.log_audit('partner.withdrawal_request','partners','partner_withdrawal_requests',_id,NULL,
    jsonb_build_object('amount',round(_amount,2),'method',_method),_notes,NULL);
  RETURN _id;
END $$;

CREATE OR REPLACE FUNCTION public.review_partner_withdrawal(
  _request_id uuid, _approve boolean, _note text DEFAULT NULL, _account_id uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _profile uuid := public.current_profile_id(); _r public.partner_withdrawal_requests;
  _acc uuid; _cash uuid; _txn uuid; _currency text; _balance numeric;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('partners.manage_withdrawals') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  SELECT * INTO _r FROM public.partner_withdrawal_requests
   WHERE id = _request_id AND company_id = public.current_company_id();
  IF _r.id IS NULL THEN RAISE EXCEPTION 'Request not found'; END IF;
  IF _r.status <> 'pending' THEN RAISE EXCEPTION 'This request was already reviewed'; END IF;

  IF NOT _approve THEN
    UPDATE public.partner_withdrawal_requests
       SET status = 'rejected', reviewed_by = _profile, reviewed_at = now(), review_note = NULLIF(_note,'')
     WHERE id = _request_id;
    PERFORM public.log_audit('partner.withdrawal_reject','partners','partner_withdrawal_requests',_request_id,NULL,
      jsonb_build_object('amount',_r.amount),_note,NULL);
    RETURN _request_id;
  END IF;

  _balance := public.partner_balance(_r.partner_id);
  IF round(_r.amount,2) > _balance THEN
    RAISE EXCEPTION 'Partner balance is not enough (%)', _balance;
  END IF;

  SELECT currency INTO _currency FROM public.companies WHERE id = _r.company_id;
  _acc := COALESCE(_account_id, public.default_cash_account(_r.company_id, _r.method));
  IF _acc IS NULL THEN RAISE EXCEPTION 'No cash account available'; END IF;

  _cash := public.post_cash_txn(_r.company_id, _acc, 'out', _r.amount, 'partner_withdrawal', _r.method,
    CURRENT_DATE, 'partner_withdrawal', _request_id, 'Partner withdrawal');

  INSERT INTO public.partner_ledger_transactions (company_id, partner_id, transaction_type, amount, currency,
    reference_type, reference_id, description, transaction_date, status, created_by)
  VALUES (_r.company_id, _r.partner_id, 'withdrawal', _r.amount, COALESCE(_currency,'EGP'),
    'partner_withdrawal', _request_id, COALESCE(NULLIF(_note,''),'Approved withdrawal'), CURRENT_DATE, 'active', _profile)
  RETURNING id INTO _txn;

  UPDATE public.partner_withdrawal_requests
     SET status = 'approved', reviewed_by = _profile, reviewed_at = now(), review_note = NULLIF(_note,''),
         cash_transaction_id = _cash, ledger_transaction_id = _txn
   WHERE id = _request_id;

  PERFORM public.log_audit('partner.withdrawal_approve','partners','partner_withdrawal_requests',_request_id,NULL,
    jsonb_build_object('amount',_r.amount,'method',_r.method),_note,NULL);
  RETURN _request_id;
END $$;

-- ============ 8) OPERATING COSTS + PROFIT SPLIT ============
CREATE OR REPLACE FUNCTION public.monthly_operating_costs(_from date, _to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE _company uuid := public.current_company_id();
  _sales numeric := 0; _tax numeric := 0; _cogs numeric := 0; _waste numeric := 0;
  _purchases numeric := 0; _purch_paid numeric := 0; _payroll numeric := 0; _advances numeric := 0;
  _expenses numeric := 0; _items jsonb; _cats jsonb;
BEGIN
  IF NOT (public.has_permission('reports.profit') OR public.has_permission('treasury.view')
          OR public.has_permission('partners.view_profit') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT COALESCE(SUM(o.total - o.tax_amount),0), COALESCE(SUM(o.tax_amount),0) INTO _sales, _tax
  FROM public.orders o WHERE o.company_id = _company AND o.status IN ('completed','refunded')
    AND o.created_at::date BETWEEN _from AND _to;

  SELECT COALESCE(SUM(oi.unit_cost * oi.quantity),0) INTO _cogs
  FROM public.order_items oi JOIN public.orders o ON o.id = oi.order_id
  WHERE o.company_id = _company AND o.status = 'completed' AND oi.status = 'active'
    AND o.created_at::date BETWEEN _from AND _to;

  SELECT COALESCE(SUM(-sm.quantity * sm.unit_cost),0) INTO _waste
  FROM public.stock_movements sm
  WHERE sm.company_id = _company AND sm.movement_type IN ('waste','stocktake') AND sm.quantity < 0
    AND sm.created_at::date BETWEEN _from AND _to;

  SELECT COALESCE(SUM(p.total - p.returned_amount),0), COALESCE(SUM(p.paid_amount),0)
    INTO _purchases, _purch_paid
  FROM public.purchases p WHERE p.company_id = _company AND p.status <> 'cancelled'
    AND p.purchase_date BETWEEN _from AND _to;

  SELECT COALESCE(SUM(s.net_amount),0) INTO _payroll FROM public.salary_payments s
  WHERE s.company_id = _company AND s.status = 'active'
    AND s.period_start <= _to AND s.period_end >= _from;

  SELECT COALESCE(SUM(a.amount),0) INTO _advances FROM public.employee_advances a
  WHERE a.company_id = _company AND a.status = 'active' AND a.advance_date BETWEEN _from AND _to;

  SELECT COALESCE(SUM(e.amount),0) INTO _expenses FROM public.expenses e
  WHERE e.company_id = _company AND e.status = 'active' AND e.expense_date BETWEEN _from AND _to;

  SELECT COALESCE(jsonb_agg(x ORDER BY x->>'cost' DESC), '[]'::jsonb) INTO _items FROM (
    SELECT jsonb_build_object('item', i.name, 'item_ar', i.name_ar, 'unit', i.unit,
      'qty', round(SUM(-sm.quantity),3), 'cost', round(SUM(-sm.quantity * sm.unit_cost),2)) AS x
    FROM public.stock_movements sm JOIN public.inventory_items i ON i.id = sm.item_id
    WHERE sm.company_id = _company AND sm.quantity < 0
      AND sm.movement_type IN ('sale_consumption','waste','adjustment','stocktake')
      AND sm.created_at::date BETWEEN _from AND _to
    GROUP BY i.name, i.name_ar, i.unit
  ) s;

  SELECT COALESCE(jsonb_agg(x ORDER BY x->>'amount' DESC), '[]'::jsonb) INTO _cats FROM (
    SELECT jsonb_build_object('category', COALESCE(c.name,'Other'), 'category_ar', c.name_ar,
      'amount', round(SUM(e.amount),2)) AS x
    FROM public.expenses e LEFT JOIN public.expense_categories c ON c.id = e.category_id
    WHERE e.company_id = _company AND e.status = 'active' AND e.expense_date BETWEEN _from AND _to
    GROUP BY c.name, c.name_ar
  ) s;

  RETURN jsonb_build_object(
    'from', _from, 'to', _to,
    'sales', round(_sales,2), 'tax', round(_tax,2),
    'cogs', round(_cogs,2), 'waste', round(_waste,2),
    'purchases_total', round(_purchases,2), 'purchases_paid', round(_purch_paid,2),
    'purchases_due', round(_purchases - _purch_paid,2),
    'payroll', round(_payroll,2), 'advances', round(_advances,2),
    'expenses', round(_expenses,2),
    'operating_total', round(_cogs + _waste + _payroll + _expenses,2),
    'consumption', COALESCE(_items,'[]'::jsonb),
    'expense_breakdown', COALESCE(_cats,'[]'::jsonb)
  );
END $$;

CREATE OR REPLACE FUNCTION public.operating_reserve_settings()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(
    (SELECT value FROM public.app_settings WHERE company_id = public.current_company_id() AND key = 'finance' LIMIT 1),
    '{}'::jsonb) || '{}'::jsonb
$$;

CREATE OR REPLACE FUNCTION public.period_distribution(_period_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE _net numeric; _cfg jsonb; _type text; _val numeric; _reserve numeric; _p public.accounting_periods;
BEGIN
  SELECT * INTO _p FROM public.accounting_periods WHERE id = _period_id AND company_id = public.current_company_id();
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Period not found'; END IF;
  SELECT net_profit INTO _net FROM public.period_pnl(_period_id);
  _cfg := public.operating_reserve_settings();
  _type := COALESCE(_cfg->>'operating_reserve_type','percent');
  _val := COALESCE((_cfg->>'operating_reserve_value')::numeric, 0);
  IF COALESCE(_net,0) <= 0 THEN
    _reserve := 0;
  ELSIF _type = 'amount' THEN
    _reserve := LEAST(_val, _net);
  ELSE
    _reserve := round(_net * (LEAST(GREATEST(_val,0),100) / 100.0), 2);
  END IF;
  RETURN jsonb_build_object('net_profit', round(COALESCE(_net,0),2),
    'reserve_type', _type, 'reserve_value', _val,
    'reserve_amount', round(COALESCE(_reserve,0),2),
    'distributable', round(GREATEST(COALESCE(_net,0) - COALESCE(_reserve,0), 0),2));
END $$;

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

  _net := (public.period_distribution(_period_id)->>'distributable')::numeric;
  IF _net IS NULL OR _net <= 0 THEN RAISE EXCEPTION 'There is no distributable profit for this period'; END IF;

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

-- ============ 9) TREASURY OVERVIEW ============
CREATE OR REPLACE FUNCTION public.treasury_overview()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE _company uuid := public.current_company_id(); _accounts jsonb; _drawers numeric := 0;
BEGIN
  IF NOT (public.has_permission('treasury.view') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', a.id, 'key', a.key, 'name', a.name, 'name_ar', a.name_ar,
    'type', a.account_type, 'is_active', a.is_active, 'balance', public.cash_balance(a.id))
    ORDER BY a.key), '[]'::jsonb) INTO _accounts
  FROM public.cash_accounts a WHERE a.company_id = _company;

  SELECT COALESCE(SUM(s.opening_cash),0) INTO _drawers
  FROM public.shifts s JOIN public.branches b ON b.id = s.branch_id
  WHERE b.company_id = _company AND s.status = 'open';

  RETURN jsonb_build_object('accounts', _accounts, 'open_drawers', round(_drawers,2),
    'total', round(COALESCE((SELECT SUM((e->>'balance')::numeric) FROM jsonb_array_elements(_accounts) e),0) + _drawers, 2));
END $$;