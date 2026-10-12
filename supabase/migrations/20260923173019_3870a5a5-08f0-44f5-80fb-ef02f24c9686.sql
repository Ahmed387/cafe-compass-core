ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS job_title text;

CREATE TABLE public.partner_period_freezes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  period_id uuid NOT NULL REFERENCES public.accounting_periods(id),
  partner_id uuid NOT NULL REFERENCES public.partners(id),
  reason text,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(period_id, partner_id)
);
GRANT SELECT ON public.partner_period_freezes TO authenticated;
GRANT ALL ON public.partner_period_freezes TO service_role;
ALTER TABLE public.partner_period_freezes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "view partner freezes" ON public.partner_period_freezes FOR SELECT TO authenticated
USING (company_id = public.current_company_id() AND (public.is_super_admin() OR public.has_permission('partners.view') OR partner_id = public.current_partner_id()));

CREATE TABLE public.partner_dividend_payouts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  period_id uuid NOT NULL REFERENCES public.accounting_periods(id),
  partner_id uuid NOT NULL REFERENCES public.partners(id),
  distribution_id uuid REFERENCES public.profit_distributions(id),
  amount numeric NOT NULL,
  cash_transaction_id uuid,
  ledger_transaction_id uuid,
  status public.record_status NOT NULL DEFAULT 'active',
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX partner_dividend_payouts_active_uq ON public.partner_dividend_payouts(period_id, partner_id) WHERE status='active';
GRANT SELECT ON public.partner_dividend_payouts TO authenticated;
GRANT ALL ON public.partner_dividend_payouts TO service_role;
ALTER TABLE public.partner_dividend_payouts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "view dividend payouts" ON public.partner_dividend_payouts FOR SELECT TO authenticated
USING (company_id = public.current_company_id() AND (public.is_super_admin() OR public.has_permission('partners.view') OR partner_id = public.current_partner_id()));
CREATE TRIGGER t_pdp_no_delete BEFORE DELETE ON public.partner_dividend_payouts FOR EACH ROW EXECUTE FUNCTION public.forbid_hard_delete();

DROP FUNCTION IF EXISTS public.hr_payroll_preview(date, date);
CREATE FUNCTION public.hr_payroll_preview(_period_start date, _period_end date)
RETURNS TABLE(user_id uuid, employee_name text, job_title text, hire_date date, base_salary numeric, prorated_salary numeric, worked_days integer, worked_hours numeric, shifts_count integer, absent_days integer, absence_deduction numeric, penalties numeric, bonuses numeric, advances numeric, net_pay numeric, already_generated boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_company uuid := public.current_company_id();
BEGIN
  IF NOT (public.has_permission('payroll.view') OR public.is_super_admin()) THEN RAISE EXCEPTION 'not authorized'; END IF;
  RETURN QUERY
  WITH base AS (
    SELECT p.id AS uid, COALESCE(s.base_salary,0) AS bs, p.hire_date AS hd, p.job_title AS jt,
      COALESCE(NULLIF(p.display_name,''), NULLIF(trim(COALESCE(p.first_name,'')||' '||COALESCE(p.last_name,'')),''), p.email) AS nm
    FROM public.user_profiles p
    LEFT JOIN LATERAL (SELECT es.base_salary FROM public.employee_salaries es WHERE es.user_id=p.id AND es.company_id=v_company AND es.is_active ORDER BY es.effective_from DESC NULLS LAST LIMIT 1) s ON true
    WHERE p.company_id = v_company AND p.is_active
  ), calc AS (
    SELECT b.*, public._prorated_salary(b.bs, b.hd, _period_start, _period_end) AS pr,
      (SELECT count(DISTINCT a.work_date)::int FROM public.attendance a WHERE a.user_id=b.uid AND a.company_id=v_company AND a.work_date BETWEEN _period_start AND _period_end AND COALESCE(a.status,'') <> 'absent') AS wd,
      (SELECT round(COALESCE(sum(a.minutes_worked),0)/60.0, 2) FROM public.attendance a WHERE a.user_id=b.uid AND a.company_id=v_company AND a.work_date BETWEEN _period_start AND _period_end) AS wh,
      (SELECT count(*)::int FROM public.shifts sh WHERE sh.opened_by=b.uid AND sh.opened_at::date BETWEEN _period_start AND _period_end) AS sc,
      (SELECT count(*)::int FROM public.attendance a WHERE a.user_id=b.uid AND a.company_id=v_company AND a.status='absent' AND a.work_date BETWEEN _period_start AND _period_end) AS ad,
      (SELECT COALESCE(sum(sp.amount),0) FROM public.staff_penalties sp WHERE sp.company_id=v_company AND sp.staff_id=b.uid AND NOT sp.is_settled AND sp.payroll_id IS NULL AND sp.created_at::date BETWEEN _period_start AND _period_end) AS pen,
      (SELECT COALESCE(sum(sb.amount),0) FROM public.staff_bonuses sb WHERE sb.company_id=v_company AND sb.staff_id=b.uid AND NOT sb.is_settled AND sb.payroll_id IS NULL AND sb.bonus_date BETWEEN _period_start AND _period_end) AS bon,
      (SELECT COALESCE(sum(ea.amount),0) FROM public.employee_advances ea WHERE ea.user_id=b.uid AND ea.status='active' AND ea.settled_payment_id IS NULL AND ea.advance_date <= _period_end) AS adv,
      EXISTS (SELECT 1 FROM public.salary_payments sp2 WHERE sp2.user_id=b.uid AND sp2.period_start=_period_start AND sp2.status='active') AS gen
    FROM base b
  )
  SELECT c.uid, c.nm, c.jt, c.hd, c.bs, c.pr, c.wd, c.wh, c.sc, c.ad,
    round(c.bs/30.0*c.ad, 2), c.pen, c.bon, c.adv,
    GREATEST(round(c.pr + c.bon - LEAST(c.adv + round(c.bs/30.0*c.ad,2) + c.pen, c.pr), 2), 0),
    c.gen
  FROM calc c ORDER BY c.nm;
END $function$;

CREATE OR REPLACE FUNCTION public.update_employee_profile(_user_id uuid, _name text, _job_title text, _base_salary numeric, _hire_date date)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE _old public.user_profiles; _company uuid := public.current_company_id(); _sal uuid; _old_sal numeric;
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only the Super Admin can edit employee data'; END IF;
  SELECT * INTO _old FROM public.user_profiles WHERE id=_user_id AND company_id=_company FOR UPDATE;
  IF _old.id IS NULL THEN RAISE EXCEPTION 'Employee not found'; END IF;
  IF NULLIF(btrim(COALESCE(_name,'')),'') IS NULL THEN RAISE EXCEPTION 'Employee name is required'; END IF;
  IF _base_salary IS NULL OR _base_salary < 0 THEN RAISE EXCEPTION 'Salary must be zero or more'; END IF;
  IF _job_title IS NOT NULL AND _job_title NOT IN ('cashier','barista','floor_staff','manager') THEN RAISE EXCEPTION 'Invalid job title'; END IF;
  UPDATE public.user_profiles SET display_name=btrim(_name), job_title=_job_title, hire_date=_hire_date, updated_at=now() WHERE id=_user_id;
  SELECT id, base_salary INTO _sal, _old_sal FROM public.employee_salaries WHERE user_id=_user_id AND company_id=_company AND is_active ORDER BY effective_from DESC NULLS LAST LIMIT 1 FOR UPDATE;
  IF _sal IS NULL THEN
    IF _base_salary > 0 THEN
      INSERT INTO public.employee_salaries(company_id,user_id,base_salary,effective_from,is_active,created_by)
      VALUES(_company,_user_id,round(_base_salary,2),COALESCE(_hire_date,CURRENT_DATE),true,public.current_profile_id());
    END IF;
  ELSIF _old_sal <> round(_base_salary,2) THEN
    UPDATE public.employee_salaries SET base_salary=round(_base_salary,2), updated_at=now() WHERE id=_sal;
  END IF;
  PERFORM public.log_audit('hr.employee_update','hr','user_profiles',_user_id,
    jsonb_build_object('name',_old.display_name,'job_title',_old.job_title,'hire_date',_old.hire_date,'base_salary',_old_sal),
    jsonb_build_object('name',btrim(_name),'job_title',_job_title,'hire_date',_hire_date,'base_salary',round(_base_salary,2)),NULL,NULL);
END $function$;

CREATE OR REPLACE FUNCTION public.hr_add_penalty(_staff_id uuid, _amount numeric, _reason text, _order_id uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE _id uuid; _company uuid := public.current_company_id();
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only the Super Admin can record penalties here'; END IF;
  IF _amount IS NULL OR _amount <= 0 THEN RAISE EXCEPTION 'Amount must be greater than zero'; END IF;
  IF length(btrim(COALESCE(_reason,''))) < 3 THEN RAISE EXCEPTION 'Reason is required'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE id=_staff_id AND company_id=_company) THEN RAISE EXCEPTION 'Employee not found'; END IF;
  INSERT INTO public.staff_penalties(company_id,staff_id,amount,reason,order_id,created_by)
  VALUES(_company,_staff_id,round(_amount,2),btrim(_reason),_order_id,public.current_profile_id()) RETURNING id INTO _id;
  PERFORM public.log_audit('hr.penalty_add','hr','staff_penalties',_id,NULL,jsonb_build_object('staff_id',_staff_id,'amount',round(_amount,2),'order_id',_order_id),_reason,NULL);
  RETURN _id;
END $function$;

CREATE OR REPLACE FUNCTION public.toggle_partner_freeze(_period_id uuid, _partner_id uuid, _freeze boolean, _reason text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE _company uuid := public.current_company_id();
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only the Super Admin can freeze a partner dividend'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.accounting_periods WHERE id=_period_id AND company_id=_company) THEN RAISE EXCEPTION 'Period not found'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.partners WHERE id=_partner_id AND company_id=_company) THEN RAISE EXCEPTION 'Partner not found'; END IF;
  IF EXISTS (SELECT 1 FROM public.profit_distributions WHERE period_id=_period_id AND status='active') THEN RAISE EXCEPTION 'Distributed periods cannot be changed'; END IF;
  IF _freeze THEN
    INSERT INTO public.partner_period_freezes(company_id,period_id,partner_id,reason,created_by)
    VALUES(_company,_period_id,_partner_id,NULLIF(btrim(COALESCE(_reason,'')),''),public.current_profile_id())
    ON CONFLICT (period_id,partner_id) DO NOTHING;
  ELSE
    DELETE FROM public.partner_period_freezes WHERE period_id=_period_id AND partner_id=_partner_id;
  END IF;
  PERFORM public.log_audit(CASE WHEN _freeze THEN 'partner.dividend_freeze' ELSE 'partner.dividend_unfreeze' END,'partners','partners',_partner_id,NULL,
    jsonb_build_object('period_id',_period_id,'frozen',_freeze),_reason,NULL);
END $function$;

CREATE OR REPLACE FUNCTION public.distribute_period_profit(_period_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE _p public.accounting_periods; _profile uuid := public.current_profile_id(); _net numeric; _currency text;
  _dist uuid; _r record; _txn uuid; _amount numeric; _tab numeric; _deduct numeric; _allocated numeric := 0; _last uuid; _active_total numeric;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('partners.manage_profit_distribution') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  SELECT * INTO _p FROM public.accounting_periods WHERE id=_period_id AND company_id=public.current_company_id() FOR UPDATE;
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Period not found'; END IF;
  IF _p.status <> 'closed' THEN RAISE EXCEPTION 'Close the accounting period before distributing profit'; END IF;
  IF NOT _p.distribution_frozen THEN RAISE EXCEPTION 'Freeze partner shares before distributing profit'; END IF;
  IF EXISTS (SELECT 1 FROM public.profit_distributions WHERE period_id=_period_id AND status='active') THEN RAISE EXCEPTION 'Profit for this period has already been distributed'; END IF;
  _net := (public.period_distribution(_period_id)->>'distributable')::numeric;
  IF COALESCE(_net,0) <= 0 THEN RAISE EXCEPTION 'There is no distributable profit for this period'; END IF;
  SELECT COALESCE(SUM(s.ownership_percentage),0) INTO _active_total FROM public.period_partner_shares s
   WHERE s.period_id=_period_id AND NOT EXISTS (SELECT 1 FROM public.partner_period_freezes f WHERE f.period_id=_period_id AND f.partner_id=s.partner_id);
  IF _active_total <= 0 THEN RAISE EXCEPTION 'All partners are frozen for this period'; END IF;
  SELECT currency INTO _currency FROM public.companies WHERE id=_p.company_id;
  INSERT INTO public.profit_distributions(company_id,period_id,net_profit,currency,status,distributed_at,created_by)
  VALUES(_p.company_id,_period_id,_net,_currency,'active',now(),_profile) RETURNING id INTO _dist;
  -- Frozen partners' shares stay in the treasury; the rounding absorber is only relevant when nobody is frozen.
  IF _active_total = 100 THEN
    SELECT partner_id INTO _last FROM public.period_partner_shares s WHERE period_id=_period_id ORDER BY ownership_percentage DESC,partner_id LIMIT 1;
  END IF;
  FOR _r IN SELECT s.partner_id,s.ownership_percentage FROM public.period_partner_shares s
    WHERE s.period_id=_period_id AND NOT EXISTS (SELECT 1 FROM public.partner_period_freezes f WHERE f.period_id=_period_id AND f.partner_id=s.partner_id)
    ORDER BY (s.partner_id=_last) NULLS FIRST, s.partner_id LOOP
    _amount := CASE WHEN _r.partner_id=_last THEN round(_net-_allocated,2) ELSE round(_net*_r.ownership_percentage/100.0,2) END;
    _allocated := _allocated+_amount;
    INSERT INTO public.partner_ledger_transactions(company_id,partner_id,transaction_type,amount,currency,reference_type,reference_id,description,transaction_date,status,created_by)
    VALUES(_p.company_id,_r.partner_id,'profit_distribution',_amount,_currency,'profit_distribution',_dist,'Profit distribution',_p.end_date,'active',_profile) RETURNING id INTO _txn;
    INSERT INTO public.profit_distribution_lines(distribution_id,partner_id,ownership_percentage,amount,ledger_transaction_id)
    VALUES(_dist,_r.partner_id,_r.ownership_percentage,_amount,_txn);
    SELECT COALESCE(SUM(t.total_amount),0) INTO _tab FROM public.partner_tab_orders t
    WHERE t.partner_id=_r.partner_id AND NOT t.is_settled AND t.created_at::date<=_p.end_date;
    _deduct := LEAST(_tab,_amount);
    IF _deduct>0 THEN
      INSERT INTO public.partner_ledger_transactions(company_id,partner_id,transaction_type,amount,currency,reference_type,reference_id,description,transaction_date,status,created_by)
      VALUES(_p.company_id,_r.partner_id,'adjustment',-_deduct,_currency,'partner_tab',_dist,'خصم فواتير على الحساب',_p.end_date,'active',_profile);
      UPDATE public.partner_tab_orders SET is_settled=true,settled_at=now(),distribution_id=_dist
      WHERE partner_id=_r.partner_id AND NOT is_settled AND created_at::date<=_p.end_date;
      PERFORM public.log_audit('partner_tab.settle','partners','partner_tab_orders',_dist,NULL,
        jsonb_build_object('partner_id',_r.partner_id,'deducted',_deduct,'dividend',_amount),NULL,NULL);
    END IF;
  END LOOP;
  PERFORM public.log_audit('finance.distribute_profit','partners','profit_distributions',_dist,NULL,
    jsonb_build_object('net_profit',_net,'allocated',_allocated,'retained_frozen',round(_net-_allocated,2),'period_id',_period_id),NULL,NULL);
  RETURN _dist;
END $function$;

CREATE OR REPLACE FUNCTION public.payout_partner_dividend(_period_id uuid, _partner_id uuid, _account_id uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE _company uuid := public.current_company_id(); _profile uuid := public.current_profile_id();
  _dist uuid; _line numeric; _ded numeric; _net numeric; _acc uuid; _cash uuid; _txn uuid; _id uuid; _currency text;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.is_super_admin() OR public.current_partner_id() = _partner_id) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  SELECT id INTO _dist FROM public.profit_distributions WHERE period_id=_period_id AND company_id=_company AND status='active';
  IF _dist IS NULL THEN RAISE EXCEPTION 'Profit for this period has not been distributed yet'; END IF;
  IF EXISTS (SELECT 1 FROM public.partner_dividend_payouts WHERE period_id=_period_id AND partner_id=_partner_id AND status='active') THEN RAISE EXCEPTION 'This dividend was already paid out'; END IF;
  SELECT amount INTO _line FROM public.profit_distribution_lines WHERE distribution_id=_dist AND partner_id=_partner_id;
  IF _line IS NULL THEN RAISE EXCEPTION 'This partner has no dividend for this period (frozen or no share)'; END IF;
  SELECT COALESCE(-SUM(amount),0) INTO _ded FROM public.partner_ledger_transactions
   WHERE partner_id=_partner_id AND reference_type='partner_tab' AND reference_id=_dist AND status='active';
  _net := round(_line - _ded, 2);
  SELECT currency INTO _currency FROM public.companies WHERE id=_company;
  IF _net > 0 THEN
    _acc := COALESCE(_account_id, public.default_cash_account(_company, 'cash'));
    IF _acc IS NULL THEN RAISE EXCEPTION 'No cash account available'; END IF;
    _cash := public.post_cash_txn(_company, _acc, 'out', _net, 'partner_dividend', 'cash', CURRENT_DATE, 'partner_dividend', _period_id, 'Partner dividend payout');
    INSERT INTO public.partner_ledger_transactions(company_id,partner_id,transaction_type,amount,currency,reference_type,reference_id,description,transaction_date,status,created_by)
    VALUES(_company,_partner_id,'withdrawal',_net,COALESCE(_currency,'EGP'),'partner_dividend',_dist,'صرف الأرباح',CURRENT_DATE,'active',_profile) RETURNING id INTO _txn;
  END IF;
  INSERT INTO public.partner_dividend_payouts(company_id,period_id,partner_id,distribution_id,amount,cash_transaction_id,ledger_transaction_id,created_by)
  VALUES(_company,_period_id,_partner_id,_dist,_net,_cash,_txn,_profile) RETURNING id INTO _id;
  PERFORM public.log_audit('partner.dividend_payout','partners','partner_dividend_payouts',_id,NULL,
    jsonb_build_object('period_id',_period_id,'dividend',_line,'tab_deducted',_ded,'paid',_net),NULL,NULL);
  RETURN _id;
END $function$;

REVOKE EXECUTE ON FUNCTION public.update_employee_profile(uuid,text,text,numeric,date), public.hr_add_penalty(uuid,numeric,text,uuid), public.toggle_partner_freeze(uuid,uuid,boolean,text), public.payout_partner_dividend(uuid,uuid,uuid) FROM anon;