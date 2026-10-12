ALTER TABLE public.profit_distributions
  ADD COLUMN IF NOT EXISTS development_fund_amount numeric(14,2) NOT NULL DEFAULT 0;

ALTER TABLE public.profit_distributions
  DROP CONSTRAINT IF EXISTS profit_distributions_development_fund_amount_check;
ALTER TABLE public.profit_distributions
  ADD CONSTRAINT profit_distributions_development_fund_amount_check
  CHECK (development_fund_amount >= 0);

CREATE OR REPLACE FUNCTION public.financial_self_sustainability()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  _profile uuid := public.current_profile_id();
  _row record;
  _pnl record;
  _history jsonb := '[]'::jsonb;
  _closed_count integer := 0;
  _positive_count integer := 0;
  _consecutive_positive integer := 0;
  _profit_sum numeric := 0;
  _cost_sum numeric := 0;
  _last_net numeric := 0;
  _trend numeric := 0;
  _reached boolean := false;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('reports.profit') OR public.has_permission('partners.view_profit') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  FOR _row IN
    SELECT id, start_date, end_date
    FROM public.accounting_periods
    WHERE company_id = public.current_company_id()
      AND status = 'closed'
      AND deleted_at IS NULL
    ORDER BY end_date DESC, start_date DESC
    LIMIT 12
  LOOP
    SELECT * INTO _pnl FROM public.period_pnl(_row.id);
    _closed_count := _closed_count + 1;
    _profit_sum := _profit_sum + COALESCE(_pnl.net_profit, 0);
    _cost_sum := _cost_sum + COALESCE(_pnl.cogs, 0) + COALESCE(_pnl.waste_cost, 0)
      + COALESCE(_pnl.expenses_total, 0) + COALESCE(_pnl.payroll_total, 0);
    IF COALESCE(_pnl.net_profit, 0) > 0 THEN
      _positive_count := _positive_count + 1;
      IF _closed_count = _positive_count THEN
        _consecutive_positive := _consecutive_positive + 1;
      END IF;
    END IF;
    IF _closed_count = 1 THEN
      _last_net := COALESCE(_pnl.net_profit, 0);
    ELSIF _closed_count = 2 THEN
      _trend := _last_net - COALESCE(_pnl.net_profit, 0);
    END IF;
    _history := _history || jsonb_build_array(jsonb_build_object(
      'period_id', _row.id,
      'start_date', _row.start_date,
      'end_date', _row.end_date,
      'revenue', round(COALESCE(_pnl.revenue, 0), 2),
      'costs', round(COALESCE(_pnl.cogs, 0) + COALESCE(_pnl.waste_cost, 0) + COALESCE(_pnl.expenses_total, 0) + COALESCE(_pnl.payroll_total, 0), 2),
      'net_profit', round(COALESCE(_pnl.net_profit, 0), 2)
    ));
  END LOOP;

  _reached := _consecutive_positive >= 3;
  RETURN jsonb_build_object(
    'reached', _reached,
    'closed_periods', _closed_count,
    'positive_periods', _positive_count,
    'consecutive_profitable_periods', _consecutive_positive,
    'required_consecutive_periods', 3,
    'estimated_periods_remaining', GREATEST(3 - _consecutive_positive, 0),
    'average_net_profit', CASE WHEN _closed_count = 0 THEN 0 ELSE round(_profit_sum / _closed_count, 2) END,
    'average_operating_cost', CASE WHEN _closed_count = 0 THEN 0 ELSE round(_cost_sum / _closed_count, 2) END,
    'latest_net_profit', round(_last_net, 2),
    'profit_trend', round(_trend, 2),
    'history', _history
  );
END $$;

REVOKE ALL ON FUNCTION public.financial_self_sustainability() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.financial_self_sustainability() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.distribute_period_profit(_period_id uuid, _development_fund_amount numeric)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  _p public.accounting_periods;
  _profile uuid := public.current_profile_id();
  _base_distributable numeric;
  _partner_distributable numeric;
  _currency text;
  _dist uuid;
  _r record;
  _txn uuid;
  _amount numeric;
  _tab numeric;
  _deduct numeric;
  _allocated numeric := 0;
  _last uuid;
  _active_total numeric;
  _sustainability jsonb;
  _fund numeric := round(COALESCE(_development_fund_amount, 0), 2);
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only a super admin can distribute partner profit'; END IF;
  IF _fund < 0 THEN RAISE EXCEPTION 'Development fund amount cannot be negative'; END IF;

  SELECT * INTO _p
  FROM public.accounting_periods
  WHERE id = _period_id AND company_id = public.current_company_id()
  FOR UPDATE;
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Period not found'; END IF;
  IF _p.status <> 'closed' THEN RAISE EXCEPTION 'Close the accounting period before distributing profit'; END IF;
  IF NOT _p.distribution_frozen THEN RAISE EXCEPTION 'Freeze partner shares before distributing profit'; END IF;
  IF EXISTS (SELECT 1 FROM public.profit_distributions WHERE period_id = _period_id AND status = 'active') THEN
    RAISE EXCEPTION 'Profit for this period has already been distributed';
  END IF;

  _base_distributable := (public.period_distribution(_period_id)->>'distributable')::numeric;
  IF COALESCE(_base_distributable, 0) <= 0 THEN
    RAISE EXCEPTION 'There is no positive distributable profit for this period';
  END IF;

  _sustainability := public.financial_self_sustainability();
  IF NOT COALESCE((_sustainability->>'reached')::boolean, false) THEN
    RAISE EXCEPTION 'Self-sustainability has not been reached: 3 consecutive profitable closed periods are required';
  END IF;
  IF _fund > _base_distributable THEN
    RAISE EXCEPTION 'Development fund cannot exceed distributable profit';
  END IF;
  _partner_distributable := round(_base_distributable - _fund, 2);
  IF _partner_distributable <= 0 THEN
    RAISE EXCEPTION 'Development fund leaves no profit available for partners';
  END IF;

  SELECT COALESCE(SUM(s.ownership_percentage), 0) INTO _active_total
  FROM public.period_partner_shares s
  WHERE s.period_id = _period_id
    AND NOT EXISTS (
      SELECT 1 FROM public.partner_period_freezes f
      WHERE f.period_id = _period_id AND f.partner_id = s.partner_id
    );
  IF _active_total <= 0 THEN RAISE EXCEPTION 'All partners are frozen for this period'; END IF;

  SELECT currency INTO _currency FROM public.companies WHERE id = _p.company_id;
  INSERT INTO public.profit_distributions(
    company_id, period_id, net_profit, development_fund_amount, currency, status, distributed_at, created_by
  ) VALUES (
    _p.company_id, _period_id, _partner_distributable, _fund, _currency, 'active', now(), _profile
  ) RETURNING id INTO _dist;

  IF _active_total = 100 THEN
    SELECT partner_id INTO _last
    FROM public.period_partner_shares s
    WHERE period_id = _period_id
    ORDER BY ownership_percentage DESC, partner_id
    LIMIT 1;
  END IF;

  FOR _r IN
    SELECT s.partner_id, s.ownership_percentage
    FROM public.period_partner_shares s
    WHERE s.period_id = _period_id
      AND NOT EXISTS (
        SELECT 1 FROM public.partner_period_freezes f
        WHERE f.period_id = _period_id AND f.partner_id = s.partner_id
      )
    ORDER BY (s.partner_id = _last) NULLS FIRST, s.partner_id
  LOOP
    _amount := CASE
      WHEN _r.partner_id = _last THEN round(_partner_distributable - _allocated, 2)
      ELSE round(_partner_distributable * _r.ownership_percentage / 100.0, 2)
    END;
    _allocated := _allocated + _amount;
    INSERT INTO public.partner_ledger_transactions(
      company_id, partner_id, transaction_type, amount, currency, reference_type,
      reference_id, description, transaction_date, status, created_by
    ) VALUES (
      _p.company_id, _r.partner_id, 'profit_distribution', _amount, _currency,
      'profit_distribution', _dist, 'Profit distribution', _p.end_date, 'active', _profile
    ) RETURNING id INTO _txn;
    INSERT INTO public.profit_distribution_lines(
      distribution_id, partner_id, ownership_percentage, amount, ledger_transaction_id
    ) VALUES (_dist, _r.partner_id, _r.ownership_percentage, _amount, _txn);

    SELECT COALESCE(SUM(t.total_amount), 0) INTO _tab
    FROM public.partner_tab_orders t
    WHERE t.partner_id = _r.partner_id AND NOT t.is_settled AND t.created_at::date <= _p.end_date;
    _deduct := LEAST(_tab, _amount);
    IF _deduct > 0 THEN
      INSERT INTO public.partner_ledger_transactions(
        company_id, partner_id, transaction_type, amount, currency, reference_type,
        reference_id, description, transaction_date, status, created_by
      ) VALUES (
        _p.company_id, _r.partner_id, 'adjustment', -_deduct, _currency,
        'partner_tab', _dist, 'خصم فواتير على الحساب', _p.end_date, 'active', _profile
      );
      UPDATE public.partner_tab_orders
      SET is_settled = true, settled_at = now(), distribution_id = _dist
      WHERE partner_id = _r.partner_id AND NOT is_settled AND created_at::date <= _p.end_date;
      PERFORM public.log_audit(
        'partner_tab.settle', 'partners', 'partner_tab_orders', _dist, NULL,
        jsonb_build_object('partner_id', _r.partner_id, 'deducted', _deduct, 'dividend', _amount), NULL, NULL
      );
    END IF;
  END LOOP;

  PERFORM public.log_audit(
    'finance.distribute_profit', 'partners', 'profit_distributions', _dist, NULL,
    jsonb_build_object(
      'base_distributable', _base_distributable,
      'development_fund_amount', _fund,
      'partner_distributable', _partner_distributable,
      'allocated', _allocated,
      'retained_frozen', round(_partner_distributable - _allocated, 2),
      'self_sustainability', _sustainability,
      'period_id', _period_id
    ), NULL, NULL
  );
  RETURN _dist;
END $$;

REVOKE ALL ON FUNCTION public.distribute_period_profit(uuid, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.distribute_period_profit(uuid, numeric) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.distribute_period_profit(_period_id uuid)
RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT public.distribute_period_profit(_period_id, 0::numeric)
$$;

REVOKE ALL ON FUNCTION public.distribute_period_profit(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.distribute_period_profit(uuid) TO authenticated, service_role;