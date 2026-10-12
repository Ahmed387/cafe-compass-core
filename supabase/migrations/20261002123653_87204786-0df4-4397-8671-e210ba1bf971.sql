ALTER TABLE public.salary_payments ADD COLUMN IF NOT EXISTS salary_kind text NOT NULL DEFAULT 'regular';
ALTER TABLE public.salary_payments ADD COLUMN IF NOT EXISTS accounting_period_id uuid REFERENCES public.accounting_periods(id);

-- Manager % salaries already recorded in salary_payments are added back so profit is never double-deducted.
CREATE OR REPLACE FUNCTION public.period_manager_salaries(_period_id uuid)
RETURNS TABLE(partner_id uuid, user_id uuid, partner_name text, pct numeric, base_net_profit numeric, amount numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE _net numeric; _addback numeric; _p public.accounting_periods;
BEGIN
  SELECT * INTO _p FROM public.accounting_periods WHERE id=_period_id AND company_id=public.current_company_id();
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Period not found'; END IF;
  SELECT net_profit INTO _net FROM public.period_pnl(_period_id);
  SELECT COALESCE(sum(s.net_amount),0) INTO _addback FROM public.salary_payments s
   WHERE s.company_id=_p.company_id AND s.status='active' AND s.salary_kind='manager_percent'
     AND s.period_start BETWEEN _p.start_date AND _p.end_date;
  _net := COALESCE(_net,0) + _addback;
  RETURN QUERY
  SELECT pt.id, pt.user_id, pt.name, pt.management_salary_pct, round(_net,2),
    CASE WHEN _net > 0 THEN round(_net * LEAST(GREATEST(pt.management_salary_pct,0),100)/100.0, 2) ELSE 0 END
  FROM public.partners pt
  WHERE pt.company_id=_p.company_id AND pt.status='active' AND pt.is_managing_staff
    AND pt.management_salary_type='percent' AND pt.management_salary_pct > 0;
END $$;

CREATE OR REPLACE FUNCTION public.period_distribution(_period_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE _net numeric; _mgmt numeric; _after numeric; _cfg jsonb; _type text; _val numeric; _reserve numeric; _p public.accounting_periods;
BEGIN
  SELECT * INTO _p FROM public.accounting_periods WHERE id=_period_id AND company_id=public.current_company_id();
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Period not found'; END IF;
  SELECT COALESCE(max(base_net_profit),NULL), COALESCE(sum(amount),0) INTO _net, _mgmt FROM public.period_manager_salaries(_period_id);
  IF _net IS NULL THEN SELECT net_profit INTO _net FROM public.period_pnl(_period_id); END IF;
  _after := COALESCE(_net,0) - _mgmt;
  _cfg := public.operating_reserve_settings();
  _type := COALESCE(_cfg->>'operating_reserve_type','percent');
  _val := COALESCE((_cfg->>'operating_reserve_value')::numeric, 0);
  IF _after <= 0 THEN _reserve := 0;
  ELSIF _type='amount' THEN _reserve := LEAST(_val,_after);
  ELSE _reserve := round(_after * (LEAST(GREATEST(_val,0),100)/100.0), 2); END IF;
  RETURN jsonb_build_object('net_profit_before_management', round(COALESCE(_net,0),2),
    'management_salary', round(_mgmt,2), 'net_profit', round(_after,2),
    'reserve_type', _type, 'reserve_value', _val, 'reserve_amount', round(COALESCE(_reserve,0),2),
    'distributable', round(GREATEST(_after - COALESCE(_reserve,0),0),2));
END $$;

-- Pay lines for % managers in a payroll month (period overlapping the month).
CREATE OR REPLACE FUNCTION public.hr_manager_percent_pay(_period_start date, _period_end date)
RETURNS TABLE(partner_id uuid, user_id uuid, employee_name text, pct numeric, base_net_profit numeric, amount numeric,
  accounting_period_id uuid, salary_id uuid, recorded_amount numeric, paid_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE _pid uuid;
BEGIN
  IF NOT (public.has_permission('payroll.view') OR public.is_super_admin()) THEN RAISE EXCEPTION 'not authorized'; END IF;
  SELECT ap.id INTO _pid FROM public.accounting_periods ap
   WHERE ap.company_id=public.current_company_id() AND ap.start_date<=_period_end AND ap.end_date>=_period_start
   ORDER BY ap.start_date DESC LIMIT 1;
  IF _pid IS NULL THEN RETURN; END IF;
  RETURN QUERY
  SELECT m.partner_id, m.user_id, m.partner_name, m.pct, m.base_net_profit, m.amount, _pid,
    sp.id, sp.net_amount, sp.paid_at
  FROM public.period_manager_salaries(_pid) m
  LEFT JOIN LATERAL (SELECT s.id, s.net_amount, s.paid_at FROM public.salary_payments s
     WHERE s.user_id=m.user_id AND s.status='active' AND s.salary_kind='manager_percent' AND s.period_start=_period_start
     ORDER BY s.created_at DESC LIMIT 1) sp ON true
  WHERE m.user_id IS NOT NULL;
END $$;

-- Record (or refresh, while unpaid) the formal pay line for a % manager.
CREATE OR REPLACE FUNCTION public.record_manager_percent_salary(_partner_id uuid, _period_start date, _period_end date)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE _actor uuid := public.current_profile_id(); _company uuid := public.current_company_id(); _r record; _id uuid; _paid timestamptz;
BEGIN
  IF NOT (public.has_permission('payroll.manage') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  SELECT * INTO _r FROM public.hr_manager_percent_pay(_period_start,_period_end) x WHERE x.partner_id=_partner_id;
  IF _r.partner_id IS NULL THEN RAISE EXCEPTION 'This partner has no percentage salary for this month'; END IF;
  IF COALESCE(_r.amount,0) <= 0 THEN RAISE EXCEPTION 'No net profit yet, so there is no salary to record'; END IF;
  IF _r.salary_id IS NOT NULL THEN
    SELECT paid_at INTO _paid FROM public.salary_payments WHERE id=_r.salary_id;
    IF _paid IS NOT NULL THEN RAISE EXCEPTION 'This salary is already paid'; END IF;
    UPDATE public.salary_payments SET base_amount=_r.amount, bonus=0, deduction=0, updated_at=now() WHERE id=_r.salary_id;
    _id := _r.salary_id;
  ELSE
    INSERT INTO public.salary_payments(company_id,user_id,period_start,period_end,base_amount,bonus,deduction,created_by,salary_kind,accounting_period_id)
    VALUES(_company,_r.user_id,_period_start,_period_end,_r.amount,0,0,_actor,'manager_percent',_r.accounting_period_id)
    RETURNING id INTO _id;
  END IF;
  PERFORM public.log_audit('payroll.manager_percent','finance','salary_payments',_id,NULL,
    jsonb_build_object('partner_id',_partner_id,'pct',_r.pct,'base_net_profit',_r.base_net_profit,'amount',_r.amount),NULL,NULL);
  RETURN _id;
END $$;

REVOKE EXECUTE ON FUNCTION public.hr_manager_percent_pay(date,date) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.record_manager_percent_salary(uuid,date,date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.hr_manager_percent_pay(date,date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_manager_percent_salary(uuid,date,date) TO authenticated;