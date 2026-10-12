CREATE OR REPLACE FUNCTION public.get_my_partner_profit_summary()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _partner uuid := public.current_partner_id();
  _company uuid := public.current_company_id();
  _d record;
  _line_pct numeric;
  _line_amount numeric;
  _capital numeric := 0;
  _mine numeric := 0;
  _lifetime numeric := 0;
BEGIN
  IF public.current_profile_id() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF _partner IS NULL THEN RAISE EXCEPTION 'Not a partner'; END IF;

  SELECT COALESCE(SUM(cc.amount),0) INTO _capital
  FROM public.partner_capital_contributions cc
  JOIN public.partners pa ON pa.id = cc.partner_id
  WHERE cc.company_id = _company AND cc.status = 'active' AND pa.status = 'active';

  SELECT COALESCE(SUM(cc.amount),0) INTO _mine
  FROM public.partner_capital_contributions cc
  WHERE cc.company_id = _company AND cc.status = 'active' AND cc.partner_id = _partner;

  SELECT COALESCE(SUM(l.amount),0) INTO _lifetime
  FROM public.profit_distribution_lines l
  JOIN public.profit_distributions d ON d.id = l.distribution_id
  WHERE d.company_id = _company AND l.partner_id = _partner;

  SELECT d.id, d.net_profit, d.distributed_at, ap.start_date, ap.end_date
  INTO _d
  FROM public.profit_distributions d
  JOIN public.accounting_periods ap ON ap.id = d.period_id
  WHERE d.company_id = _company
  ORDER BY ap.end_date DESC
  LIMIT 1;

  IF _d.id IS NOT NULL THEN
    SELECT l.ownership_percentage, l.amount INTO _line_pct, _line_amount
    FROM public.profit_distribution_lines l
    WHERE l.distribution_id = _d.id AND l.partner_id = _partner;
  END IF;

  RETURN jsonb_build_object(
    'has_period', _d.id IS NOT NULL,
    'period_start', _d.start_date,
    'period_end', _d.end_date,
    'distributed_at', _d.distributed_at,
    'company_net_profit', round(COALESCE(_d.net_profit,0),2),
    'my_percentage', round(COALESCE(_line_pct,
      CASE WHEN _capital > 0 THEN _mine / _capital * 100 ELSE 0 END), 2),
    'my_profit', round(COALESCE(_line_amount,0),2),
    'my_capital', round(_mine,2),
    'lifetime_profit', round(_lifetime,2)
  );
END $function$;