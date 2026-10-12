ALTER TABLE public.accounting_periods ADD COLUMN IF NOT EXISTS deleted_at timestamptz, ADD COLUMN IF NOT EXISTS deleted_by uuid, ADD COLUMN IF NOT EXISTS delete_reason text;

DROP POLICY IF EXISTS ap_select ON public.accounting_periods;
CREATE POLICY ap_select ON public.accounting_periods FOR SELECT TO authenticated
USING (company_id = current_company_id() AND deleted_at IS NULL AND (has_permission('periods.view') OR has_permission('reports.profit') OR has_permission('settings.view')));

CREATE OR REPLACE FUNCTION public.assert_period_open(_company_id uuid, _date date)
 RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  IF _company_id IS NULL OR _date IS NULL THEN RETURN; END IF;
  IF EXISTS (SELECT 1 FROM public.accounting_periods ap
    WHERE ap.company_id=_company_id AND ap.deleted_at IS NULL AND ap.status='closed'
      AND _date BETWEEN ap.start_date AND ap.end_date
      AND NOT (public.is_super_admin() AND ap.override_until IS NOT NULL AND ap.override_until > now())) THEN
    RAISE EXCEPTION 'The accounting period covering % is closed and locked', _date;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.ensure_open_periods()
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE _c record; _created integer := 0; _start date; _end date;
BEGIN
  _start := date_trunc('month', CURRENT_DATE)::date;
  _end := (date_trunc('month', CURRENT_DATE) + interval '1 month - 1 day')::date;
  FOR _c IN SELECT id FROM public.companies LOOP
    IF NOT EXISTS (SELECT 1 FROM public.accounting_periods ap WHERE ap.company_id=_c.id AND ap.deleted_at IS NULL AND ap.start_date <= _end AND ap.end_date >= _start) THEN
      INSERT INTO public.accounting_periods (company_id, period_type, start_date, end_date, status, auto_created)
      VALUES (_c.id, 'monthly', _start, _end, 'open', true);
      _created := _created + 1;
    END IF;
  END LOOP;
  RETURN _created;
END $$;

CREATE OR REPLACE FUNCTION public.initialize_accounting_period(_start_date date DEFAULT NULL, _end_date date DEFAULT NULL, _period_type period_type DEFAULT 'monthly')
 RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE _profile uuid := public.current_profile_id(); _company uuid := public.current_company_id(); _s date; _e date; _id uuid;
BEGIN
  IF _profile IS NULL OR _company IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('periods.manage') OR public.has_permission('settings.manage') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF _start_date IS NULL THEN
    SELECT (date_trunc('month', MAX(ap.end_date) + 1))::date INTO _s FROM public.accounting_periods ap WHERE ap.company_id=_company AND ap.deleted_at IS NULL;
    _s := COALESCE(_s, date_trunc('month', CURRENT_DATE)::date);
  ELSE _s := _start_date; END IF;
  _e := COALESCE(_end_date, (date_trunc('month', _s::timestamp) + interval '1 month - 1 day')::date);
  IF _e < _s THEN RAISE EXCEPTION 'End date must be on or after the start date'; END IF;
  IF EXISTS (SELECT 1 FROM public.accounting_periods ap WHERE ap.company_id=_company AND ap.deleted_at IS NULL AND ap.start_date <= _e AND ap.end_date >= _s)
    THEN RAISE EXCEPTION 'A period already exists for this date range'; END IF;
  INSERT INTO public.accounting_periods (company_id, period_type, start_date, end_date, status)
  VALUES (_company, COALESCE(_period_type,'monthly'), _s, _e, 'open') RETURNING id INTO _id;
  PERFORM public.log_audit('period.create','settings','accounting_periods',_id,NULL,jsonb_build_object('start_date',_s,'end_date',_e),NULL,NULL);
  RETURN _id;
END $$;

-- Edit dates/type of an OPEN period
CREATE OR REPLACE FUNCTION public.update_accounting_period(_period_id uuid, _start_date date, _end_date date, _period_type period_type)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE _p public.accounting_periods; _company uuid := public.current_company_id();
BEGIN
  IF NOT (public.is_super_admin() OR public.has_permission('periods.manage') OR public.has_permission('settings.manage')) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  SELECT * INTO _p FROM public.accounting_periods WHERE id=_period_id AND company_id=_company AND deleted_at IS NULL FOR UPDATE;
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Period not found'; END IF;
  IF _p.status <> 'open' THEN RAISE EXCEPTION 'Reopen the period before editing it'; END IF;
  IF _start_date IS NULL OR _end_date IS NULL OR _end_date < _start_date THEN RAISE EXCEPTION 'End date must be on or after the start date'; END IF;
  IF EXISTS (SELECT 1 FROM public.accounting_periods ap WHERE ap.company_id=_company AND ap.deleted_at IS NULL AND ap.id<>_period_id AND ap.start_date <= _end_date AND ap.end_date >= _start_date)
    THEN RAISE EXCEPTION 'A period already exists for this date range'; END IF;
  UPDATE public.accounting_periods SET start_date=_start_date, end_date=_end_date, period_type=COALESCE(_period_type,period_type) WHERE id=_period_id;
  PERFORM public.log_audit('period.update','finance','accounting_periods',_period_id,
    jsonb_build_object('start_date',_p.start_date,'end_date',_p.end_date,'period_type',_p.period_type),
    jsonb_build_object('start_date',_start_date,'end_date',_end_date,'period_type',_period_type),NULL,NULL);
END $$;

-- Delete ANY period atomically: reverse distributions append-only, release tabs, then remove/retire the period
CREATE OR REPLACE FUNCTION public.delete_accounting_period(_period_id uuid, _reason text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE _profile uuid := public.current_profile_id(); _p public.accounting_periods; _d public.profit_distributions;
        _reversed int := 0; _has_history boolean;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only a super admin can delete a period'; END IF;
  IF _reason IS NULL OR length(btrim(_reason)) < 5 THEN RAISE EXCEPTION 'A clear reason is required'; END IF;
  SELECT * INTO _p FROM public.accounting_periods WHERE id=_period_id AND company_id=public.current_company_id() AND deleted_at IS NULL FOR UPDATE;
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Period not found'; END IF;

  FOR _d IN SELECT * FROM public.profit_distributions WHERE period_id=_period_id AND status='active' LOOP
    INSERT INTO public.partner_ledger_transactions(company_id,partner_id,transaction_type,amount,currency,reference_type,reference_id,description,transaction_date,status,reversal_of,created_by)
    SELECT company_id,partner_id,'adjustment',-amount,currency,'profit_distribution_reversal',_d.id,'عكس توزيع أرباح بسبب حذف الفترة',transaction_date,'active',id,_profile
      FROM public.partner_ledger_transactions
     WHERE reference_id=_d.id AND status='active' AND reference_type IN ('profit_distribution','partner_tab');
    UPDATE public.partner_tab_orders SET is_settled=false, settled_at=NULL, distribution_id=NULL WHERE distribution_id=_d.id;
    UPDATE public.profit_distributions SET status='reversed' WHERE id=_d.id;
    _reversed := _reversed + 1;
  END LOOP;

  DELETE FROM public.partner_period_freezes WHERE period_id=_period_id;

  _has_history := EXISTS (SELECT 1 FROM public.profit_distributions WHERE period_id=_period_id)
               OR EXISTS (SELECT 1 FROM public.partner_dividend_payouts WHERE period_id=_period_id);

  PERFORM public.log_audit('period.delete','finance','accounting_periods',_period_id,
    to_jsonb(_p), jsonb_build_object('reversed_distributions',_reversed,'retired',_has_history), _reason, NULL);

  IF _has_history THEN
    -- Financial history (reversed distributions/payouts) still references it: retire instead of hard delete
    UPDATE public.accounting_periods SET status='open', closed_at=NULL, closed_by=NULL, override_until=NULL,
      deleted_at=now(), deleted_by=_profile, delete_reason=btrim(_reason) WHERE id=_period_id;
  ELSE
    UPDATE public.salary_payments SET accounting_period_id=NULL WHERE accounting_period_id=_period_id;
    -- allow the protect trigger: period is closed? reset status first
    UPDATE public.accounting_periods SET status='open' WHERE id=_period_id;
    DELETE FROM public.accounting_periods WHERE id=_period_id;
  END IF;
  RETURN jsonb_build_object('reversed_distributions',_reversed,'retired',_has_history);
END $$;

-- Full employee edit
CREATE OR REPLACE FUNCTION public.admin_update_employee(_user_id uuid, _first_name text, _last_name text, _display_name text, _phone text, _employee_code text, _job_title text, _base_salary numeric, _hire_date date)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE _old public.user_profiles; _company uuid := public.current_company_id(); _sal uuid; _old_sal numeric;
BEGIN
  IF NOT (public.is_super_admin() OR public.has_permission('users.update')) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  SELECT * INTO _old FROM public.user_profiles WHERE id=_user_id AND company_id=_company FOR UPDATE;
  IF _old.id IS NULL THEN RAISE EXCEPTION 'Employee not found'; END IF;
  IF NULLIF(btrim(COALESCE(_first_name,'')),'') IS NULL THEN RAISE EXCEPTION 'Employee name is required'; END IF;
  IF length(_first_name) > 80 OR length(COALESCE(_last_name,'')) > 80 OR length(COALESCE(_phone,'')) > 30 OR length(COALESCE(_employee_code,'')) > 30 THEN RAISE EXCEPTION 'Value too long'; END IF;
  IF _job_title IS NOT NULL AND _job_title NOT IN ('cashier','barista','floor_staff','manager','general_manager') THEN RAISE EXCEPTION 'Invalid job title'; END IF;
  UPDATE public.user_profiles SET first_name=btrim(_first_name), last_name=NULLIF(btrim(COALESCE(_last_name,'')),''),
    display_name=COALESCE(NULLIF(btrim(COALESCE(_display_name,'')),''), btrim(_first_name||' '||COALESCE(_last_name,''))),
    phone=NULLIF(btrim(COALESCE(_phone,'')),''), employee_code=NULLIF(btrim(COALESCE(_employee_code,'')),''),
    job_title=_job_title, hire_date=_hire_date, updated_at=now() WHERE id=_user_id;
  IF _base_salary IS NOT NULL AND (public.is_super_admin() OR public.has_permission('payroll.manage')) THEN
    IF _base_salary < 0 THEN RAISE EXCEPTION 'Salary must be zero or more'; END IF;
    SELECT id, base_salary INTO _sal, _old_sal FROM public.employee_salaries WHERE user_id=_user_id AND company_id=_company AND is_active ORDER BY effective_from DESC NULLS LAST LIMIT 1 FOR UPDATE;
    IF _sal IS NULL THEN
      IF _base_salary > 0 THEN INSERT INTO public.employee_salaries(company_id,user_id,base_salary,effective_from,is_active,created_by)
        VALUES(_company,_user_id,round(_base_salary,2),COALESCE(_hire_date,CURRENT_DATE),true,public.current_profile_id()); END IF;
    ELSIF _old_sal <> round(_base_salary,2) THEN
      UPDATE public.employee_salaries SET base_salary=round(_base_salary,2), updated_at=now() WHERE id=_sal;
    END IF;
  END IF;
  PERFORM public.log_audit('user.update','users','user_profiles',_user_id,
    jsonb_build_object('first_name',_old.first_name,'last_name',_old.last_name,'phone',_old.phone,'employee_code',_old.employee_code,'job_title',_old.job_title,'hire_date',_old.hire_date,'base_salary',_old_sal),
    jsonb_build_object('first_name',_first_name,'last_name',_last_name,'phone',_phone,'employee_code',_employee_code,'job_title',_job_title,'hire_date',_hire_date,'base_salary',_base_salary),NULL,NULL);
END $$;

-- Remove one attachment row; returns the storage path for file cleanup
CREATE OR REPLACE FUNCTION public.delete_user_document(_doc_id uuid)
 RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE _d public.user_documents;
BEGIN
  IF NOT (public.is_super_admin() OR public.has_permission('users.update')) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  SELECT * INTO _d FROM public.user_documents WHERE id=_doc_id AND company_id=public.current_company_id();
  IF _d.id IS NULL THEN RAISE EXCEPTION 'Attachment not found'; END IF;
  DELETE FROM public.user_documents WHERE id=_doc_id;
  PERFORM public.log_audit('user.document_delete','users','user_documents',_doc_id,to_jsonb(_d),NULL,NULL,NULL);
  RETURN _d.file_path;
END $$;

REVOKE EXECUTE ON FUNCTION public.update_accounting_period(uuid,date,date,period_type), public.delete_accounting_period(uuid,text),
  public.admin_update_employee(uuid,text,text,text,text,text,text,numeric,date), public.delete_user_document(uuid) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.update_accounting_period(uuid,date,date,period_type), public.delete_accounting_period(uuid,text),
  public.admin_update_employee(uuid,text,text,text,text,text,text,numeric,date), public.delete_user_document(uuid) TO authenticated;