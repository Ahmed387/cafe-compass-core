CREATE OR REPLACE FUNCTION public.period_manager_salaries(_period_id uuid)
RETURNS TABLE(partner_id uuid, user_id uuid, partner_name text, pct numeric, base_net_profit numeric, amount numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE _net numeric; _p public.accounting_periods;
BEGIN
  SELECT * INTO _p FROM public.accounting_periods WHERE id=_period_id AND company_id=public.current_company_id();
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Period not found'; END IF;
  SELECT net_profit INTO _net FROM public.period_pnl(_period_id);
  RETURN QUERY
  SELECT pt.id, pt.user_id, pt.name, pt.management_salary_pct, round(COALESCE(_net,0),2),
    CASE WHEN COALESCE(_net,0) > 0 THEN round(_net * LEAST(GREATEST(pt.management_salary_pct,0),100)/100.0, 2) ELSE 0 END
  FROM public.partners pt
  WHERE pt.company_id=_p.company_id AND pt.status='active' AND pt.is_managing_staff
    AND pt.management_salary_type='percent' AND pt.management_salary_pct > 0;
END $$;
GRANT EXECUTE ON FUNCTION public.period_manager_salaries(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.period_distribution(_period_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE _net numeric; _mgmt numeric; _after numeric; _cfg jsonb; _type text; _val numeric; _reserve numeric; _p public.accounting_periods;
BEGIN
  SELECT * INTO _p FROM public.accounting_periods WHERE id=_period_id AND company_id=public.current_company_id();
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Period not found'; END IF;
  SELECT net_profit INTO _net FROM public.period_pnl(_period_id);
  SELECT COALESCE(sum(amount),0) INTO _mgmt FROM public.period_manager_salaries(_period_id);
  _after := COALESCE(_net,0) - _mgmt;
  _cfg := public.operating_reserve_settings();
  _type := COALESCE(_cfg->>'operating_reserve_type','percent');
  _val := COALESCE((_cfg->>'operating_reserve_value')::numeric, 0);
  IF _after <= 0 THEN _reserve := 0;
  ELSIF _type='amount' THEN _reserve := LEAST(_val,_after);
  ELSE _reserve := round(_after * (LEAST(GREATEST(_val,0),100)/100.0), 2); END IF;
  RETURN jsonb_build_object(
    'net_profit_before_management', round(COALESCE(_net,0),2),
    'management_salary', round(_mgmt,2),
    'net_profit', round(_after,2),
    'reserve_type', _type, 'reserve_value', _val,
    'reserve_amount', round(COALESCE(_reserve,0),2),
    'distributable', round(GREATEST(_after - COALESCE(_reserve,0),0),2));
END $$;