
-- ============ PHASE 4: WRITE-PATH CONSOLIDATION (ADDITIVE) ============

-- 1) EXPENSES ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_expense_entry(
  _amount numeric,
  _expense_date date DEFAULT CURRENT_DATE,
  _payment_method text DEFAULT 'cash',
  _category_id uuid DEFAULT NULL,
  _branch_id uuid DEFAULT NULL,
  _vendor text DEFAULT NULL,
  _description text DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _profile uuid := public.current_profile_id();
        _company uuid := public.current_company_id();
        _id uuid;
BEGIN
  IF _profile IS NULL OR _company IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('expenses.create') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF _amount IS NULL OR _amount <= 0 THEN RAISE EXCEPTION 'Amount must be greater than zero'; END IF;
  IF _branch_id IS NOT NULL AND NOT public.can_access_branch(_branch_id) THEN
    RAISE EXCEPTION 'Not authorized for this branch';
  END IF;
  IF _category_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.expense_categories ec WHERE ec.id = _category_id AND ec.company_id = _company
  ) THEN RAISE EXCEPTION 'Invalid expense category'; END IF;

  INSERT INTO public.expenses (company_id, branch_id, category_id, amount, expense_date,
    payment_method, vendor, description, created_by)
  VALUES (_company, _branch_id, _category_id, round(_amount, 2), COALESCE(_expense_date, CURRENT_DATE),
    NULLIF(_payment_method, ''), NULLIF(_vendor, ''), NULLIF(_description, ''), _profile)
  RETURNING id INTO _id;

  PERFORM public.log_audit('expense.create', 'finance', 'expenses', _id, NULL,
    jsonb_build_object('amount', round(_amount, 2), 'expense_date', COALESCE(_expense_date, CURRENT_DATE)),
    NULL, _branch_id);
  RETURN _id;
END $$;

CREATE OR REPLACE FUNCTION public.review_expense(_expense_id uuid, _decision text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _profile uuid := public.current_profile_id();
        _e public.expenses;
        _new public.record_status;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF _decision NOT IN ('approve', 'cancel', 'restore') THEN RAISE EXCEPTION 'Invalid decision'; END IF;

  IF _decision = 'approve' THEN
    RETURN public.approve_expense(_expense_id);
  END IF;

  IF NOT (public.has_permission('expenses.edit') OR public.has_permission('expenses.approve')
          OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT * INTO _e FROM public.expenses
   WHERE id = _expense_id AND company_id = public.current_company_id();
  IF _e.id IS NULL THEN RAISE EXCEPTION 'Expense not found'; END IF;
  IF _e.branch_id IS NOT NULL AND NOT public.can_access_branch(_e.branch_id) THEN
    RAISE EXCEPTION 'Not authorized for this branch';
  END IF;
  IF _decision = 'cancel' AND _e.approved_at IS NOT NULL THEN
    RAISE EXCEPTION 'Approved expenses cannot be cancelled';
  END IF;

  _new := CASE WHEN _decision = 'cancel' THEN 'cancelled'::public.record_status
               ELSE 'active'::public.record_status END;
  IF _e.status = _new THEN RETURN _expense_id; END IF;

  UPDATE public.expenses SET status = _new, updated_at = now() WHERE id = _expense_id;

  PERFORM public.log_audit(
    CASE WHEN _decision = 'cancel' THEN 'expense.cancel' ELSE 'expense.restore' END,
    'finance', 'expenses', _expense_id,
    jsonb_build_object('status', _e.status), jsonb_build_object('status', _new), NULL, _e.branch_id);
  RETURN _expense_id;
END $$;

-- 2) PAYROLL ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.upsert_employee_salary(
  _user_id uuid,
  _base_salary numeric,
  _effective_from date DEFAULT CURRENT_DATE,
  _notes text DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _profile uuid := public.current_profile_id();
        _company uuid := public.current_company_id();
        _id uuid;
BEGIN
  IF _profile IS NULL OR _company IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('payroll.manage') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF _base_salary IS NULL OR _base_salary < 0 THEN RAISE EXCEPTION 'Invalid salary amount'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.user_profiles up WHERE up.id = _user_id AND up.company_id = _company
  ) THEN RAISE EXCEPTION 'Employee not found'; END IF;

  UPDATE public.employee_salaries
     SET is_active = false, updated_at = now()
   WHERE user_id = _user_id AND company_id = _company AND is_active = true;

  INSERT INTO public.employee_salaries (company_id, user_id, base_salary, effective_from, notes, created_by)
  VALUES (_company, _user_id, round(_base_salary, 2), COALESCE(_effective_from, CURRENT_DATE),
    NULLIF(_notes, ''), _profile)
  RETURNING id INTO _id;

  PERFORM public.log_audit('payroll.set_salary', 'finance', 'employee_salaries', _id, NULL,
    jsonb_build_object('user_id', _user_id, 'base_salary', round(_base_salary, 2)), NULL, NULL);
  RETURN _id;
END $$;

CREATE OR REPLACE FUNCTION public.execute_salary_payment(
  _salary_id uuid,
  _account_id uuid DEFAULT NULL,
  _method text DEFAULT 'cash'
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RETURN public.pay_salary(_salary_id, _account_id, COALESCE(NULLIF(_method, ''), 'cash'));
END $$;

-- 3) PARTNERS ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_partner_entry(
  _name text,
  _email text DEFAULT NULL,
  _phone text DEFAULT NULL,
  _notes text DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _profile uuid := public.current_profile_id();
        _company uuid := public.current_company_id();
        _id uuid;
BEGIN
  IF _profile IS NULL OR _company IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('partners.manage') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF _name IS NULL OR btrim(_name) = '' THEN RAISE EXCEPTION 'Partner name is required'; END IF;

  INSERT INTO public.partners (company_id, name, email, phone, notes, created_by)
  VALUES (_company, btrim(_name), NULLIF(btrim(COALESCE(_email, '')), ''),
    NULLIF(btrim(COALESCE(_phone, '')), ''), NULLIF(_notes, ''), _profile)
  RETURNING id INTO _id;

  PERFORM public.log_audit('partner.create', 'partners', 'partners', _id, NULL,
    jsonb_build_object('name', btrim(_name)), NULL, NULL);
  RETURN _id;
END $$;

CREATE OR REPLACE FUNCTION public.record_capital_contribution(
  _partner_id uuid,
  _amount numeric,
  _contribution_date date DEFAULT CURRENT_DATE,
  _reference text DEFAULT NULL,
  _payment_method text DEFAULT NULL,
  _notes text DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _profile uuid := public.current_profile_id();
        _company uuid := public.current_company_id();
        _currency text;
        _id uuid;
BEGIN
  IF _profile IS NULL OR _company IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('partners.manage') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF _amount IS NULL OR _amount <= 0 THEN RAISE EXCEPTION 'Amount must be greater than zero'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.partners p WHERE p.id = _partner_id AND p.company_id = _company
  ) THEN RAISE EXCEPTION 'Partner not found'; END IF;

  SELECT COALESCE(c.currency, 'EGP') INTO _currency FROM public.companies c WHERE c.id = _company;

  -- The ledger entry and the cash-in movement are posted by database triggers,
  -- so this single statement keeps balances, treasury and history in sync.
  INSERT INTO public.partner_capital_contributions (company_id, partner_id, amount, currency,
    contribution_date, payment_method, reference, notes, created_by)
  VALUES (_company, _partner_id, round(_amount, 2), COALESCE(_currency, 'EGP'),
    COALESCE(_contribution_date, CURRENT_DATE), NULLIF(_payment_method, ''),
    NULLIF(_reference, ''), NULLIF(_notes, ''), _profile)
  RETURNING id INTO _id;

  PERFORM public.log_audit('partner.capital_contribution', 'partners',
    'partner_capital_contributions', _id, NULL,
    jsonb_build_object('amount', round(_amount, 2), 'currency', COALESCE(_currency, 'EGP')), NULL, NULL);
  RETURN _id;
END $$;

-- 4) ACCOUNTING PERIODS -----------------------------------------------------
CREATE OR REPLACE FUNCTION public.initialize_accounting_period(
  _start_date date DEFAULT NULL,
  _end_date date DEFAULT NULL,
  _period_type public.period_type DEFAULT 'monthly'
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _profile uuid := public.current_profile_id();
        _company uuid := public.current_company_id();
        _s date; _e date; _id uuid;
BEGIN
  IF _profile IS NULL OR _company IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('periods.manage') OR public.has_permission('settings.manage')
          OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  -- Default: the calendar month following the latest existing period (or next month).
  IF _start_date IS NULL THEN
    SELECT (date_trunc('month', MAX(ap.end_date) + 1))::date INTO _s
      FROM public.accounting_periods ap WHERE ap.company_id = _company;
    _s := COALESCE(_s, (date_trunc('month', CURRENT_DATE) + interval '1 month')::date);
  ELSE
    _s := _start_date;
  END IF;
  _e := COALESCE(_end_date, (date_trunc('month', _s::timestamp) + interval '1 month - 1 day')::date);

  IF _e < _s THEN RAISE EXCEPTION 'End date must be on or after the start date'; END IF;
  IF EXISTS (
    SELECT 1 FROM public.accounting_periods ap
     WHERE ap.company_id = _company AND ap.start_date <= _e AND ap.end_date >= _s
  ) THEN RAISE EXCEPTION 'A period already exists for this date range'; END IF;

  INSERT INTO public.accounting_periods (company_id, period_type, start_date, end_date, status)
  VALUES (_company, COALESCE(_period_type, 'monthly'), _s, _e, 'open')
  RETURNING id INTO _id;

  PERFORM public.log_audit('period.create', 'settings', 'accounting_periods', _id, NULL,
    jsonb_build_object('start_date', _s, 'end_date', _e), NULL, NULL);
  RETURN _id;
END $$;

-- 5) SUPPLIERS --------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.save_supplier(
  _name text DEFAULT NULL,
  _id uuid DEFAULT NULL,
  _contact_person text DEFAULT NULL,
  _phone text DEFAULT NULL,
  _email text DEFAULT NULL,
  _address text DEFAULT NULL,
  _payment_terms text DEFAULT NULL,
  _notes text DEFAULT NULL,
  _is_active boolean DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _profile uuid := public.current_profile_id();
        _company uuid := public.current_company_id();
        _existing public.suppliers;
        _out uuid;
BEGIN
  IF _profile IS NULL OR _company IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;

  IF _id IS NULL THEN
    IF NOT (public.has_permission('suppliers.create') OR public.has_permission('purchases.create')
            OR public.is_super_admin()) THEN
      RAISE EXCEPTION 'Not authorized';
    END IF;
    IF _name IS NULL OR btrim(_name) = '' THEN RAISE EXCEPTION 'Supplier name is required'; END IF;

    INSERT INTO public.suppliers (company_id, name, contact_person, phone, email, address,
      payment_terms, notes, is_active, created_by)
    VALUES (_company, btrim(_name), NULLIF(btrim(COALESCE(_contact_person, '')), ''),
      NULLIF(btrim(COALESCE(_phone, '')), ''), NULLIF(btrim(COALESCE(_email, '')), ''),
      NULLIF(btrim(COALESCE(_address, '')), ''), NULLIF(btrim(COALESCE(_payment_terms, '')), ''),
      NULLIF(_notes, ''), COALESCE(_is_active, true), _profile)
    RETURNING id INTO _out;

    PERFORM public.log_audit('supplier.create', 'purchases', 'suppliers', _out, NULL,
      jsonb_build_object('name', btrim(_name)), NULL, NULL);
    RETURN _out;
  END IF;

  IF NOT (public.has_permission('suppliers.update') OR public.has_permission('purchases.create')
          OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT * INTO _existing FROM public.suppliers WHERE id = _id AND company_id = _company;
  IF _existing.id IS NULL THEN RAISE EXCEPTION 'Supplier not found'; END IF;

  UPDATE public.suppliers SET
    name = CASE WHEN _name IS NULL OR btrim(_name) = '' THEN name ELSE btrim(_name) END,
    contact_person = NULLIF(btrim(COALESCE(_contact_person, '')), ''),
    phone = NULLIF(btrim(COALESCE(_phone, '')), ''),
    email = NULLIF(btrim(COALESCE(_email, '')), ''),
    address = COALESCE(NULLIF(btrim(COALESCE(_address, '')), ''), address),
    payment_terms = NULLIF(btrim(COALESCE(_payment_terms, '')), ''),
    notes = COALESCE(NULLIF(_notes, ''), notes),
    is_active = COALESCE(_is_active, is_active),
    updated_at = now()
  WHERE id = _id;

  PERFORM public.log_audit('supplier.update', 'purchases', 'suppliers', _id,
    jsonb_build_object('name', _existing.name, 'is_active', _existing.is_active),
    jsonb_build_object('name', COALESCE(NULLIF(btrim(COALESCE(_name, '')), ''), _existing.name),
      'is_active', COALESCE(_is_active, _existing.is_active)), NULL, NULL);
  RETURN _id;
END $$;

-- 6) GRANTS: authenticated + service_role only ------------------------------
REVOKE ALL ON FUNCTION public.create_expense_entry(numeric, date, text, uuid, uuid, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.review_expense(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.upsert_employee_salary(uuid, numeric, date, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.execute_salary_payment(uuid, uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.create_partner_entry(text, text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.record_capital_contribution(uuid, numeric, date, text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.initialize_accounting_period(date, date, public.period_type) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.save_supplier(text, uuid, text, text, text, text, text, text, boolean) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.create_expense_entry(numeric, date, text, uuid, uuid, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.review_expense(uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.upsert_employee_salary(uuid, numeric, date, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.execute_salary_payment(uuid, uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_partner_entry(text, text, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_capital_contribution(uuid, numeric, date, text, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.initialize_accounting_period(date, date, public.period_type) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.save_supplier(text, uuid, text, text, text, text, text, text, boolean) TO authenticated, service_role;
