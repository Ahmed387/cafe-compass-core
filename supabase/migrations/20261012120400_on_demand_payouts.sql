-- =====================================================================
-- Core re-architecture 5/6 — on-demand profit payouts
--   payout_preview(from, to, fund)   : full calculation + safety checks, no writes
--   execute_payout(from, to, fund)   : Super Admin runs the payout for that range
--   reverse_payout(id, reason)       : append-only reversal
--   payout_partner_dividend(...)     : cash out a partner's line
-- A date range can only be paid out once (no overlapping active payouts).
-- The P&L used is stored on the payout (pnl_snapshot) and compared live later
-- so any change after payout is visible instead of silently ignored.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Management % salary for a range: managing partners earn a % of net profit.
-- Lines already recorded in payroll are added back first so they're never
-- deducted twice.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._management_salary(_company uuid, _from date, _to date, _pnl jsonb)
RETURNS TABLE(partner_id uuid, user_id uuid, partner_name text, pct numeric, base_net_profit numeric, amount numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  WITH b AS (SELECT round((_pnl->>'net_profit')::numeric + (_pnl->>'management_salary_recorded')::numeric, 2) AS base)
  SELECT pt.id, pt.user_id, pt.name, pt.management_salary_pct, b.base,
         CASE WHEN b.base > 0 THEN round(b.base * LEAST(GREATEST(pt.management_salary_pct, 0), 100) / 100.0, 2) ELSE 0 END
    FROM public.partners pt CROSS JOIN b
   WHERE pt.company_id = _company AND pt.status = 'active' AND pt.is_managing_staff
     AND pt.management_salary_type = 'percent' AND pt.management_salary_pct > 0
$$;
REVOKE ALL ON FUNCTION public._management_salary(uuid, date, date, jsonb) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- Internal: the whole payout calculation. Used by preview and execute.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._payout_calc(_company uuid, _from date, _to date, _fund numeric)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _pnl jsonb; _net numeric; _mgmt_total numeric; _mgmt_recorded numeric; _mgmt_due numeric;
  _after_mgmt numeric; _cfg jsonb; _rtype text; _rval numeric; _reserve numeric; _available numeric;
  _fund_r numeric := round(GREATEST(COALESCE(_fund, 0), 0), 2); _pool numeric; _share_total numeric;
  _active_total numeric; _lines jsonb := '[]'::jsonb; _allocated numeric := 0; _r record; _amt numeric;
  _tab numeric; _adv numeric; _tab_d numeric; _adv_d numeric; _largest uuid; _overlap jsonb; _open_shifts int; _open_orders int; _sus jsonb; _today date;
  _to_end timestamptz;
BEGIN
  _today := public.business_today(_company);
  _pnl := public._range_pnl(_company, _from, _to);
  _net := (_pnl->>'net_profit')::numeric;
  _to_end := public.business_day_start(_to + 1, _company);

  SELECT COALESCE(SUM(m.amount), 0) INTO _mgmt_total FROM public._management_salary(_company, _from, _to, _pnl) m;
  _mgmt_recorded := (_pnl->>'management_salary_recorded')::numeric;
  _mgmt_due := GREATEST(round(_mgmt_total - _mgmt_recorded, 2), 0);
  _after_mgmt := round(_net - _mgmt_due, 2);

  _cfg := public.operating_reserve_settings();
  _rtype := COALESCE(_cfg->>'operating_reserve_type', 'percent');
  _rval := GREATEST(COALESCE((_cfg->>'operating_reserve_value')::numeric, 0), 0);
  _reserve := CASE WHEN _after_mgmt <= 0 THEN 0
                   WHEN _rtype = 'amount' THEN LEAST(_rval, _after_mgmt)
                   ELSE round(_after_mgmt * LEAST(_rval, 100) / 100.0, 2) END;
  _available := GREATEST(round(_after_mgmt - _reserve, 2), 0);
  _pool := round(_available - _fund_r, 2);

  -- Partner shares: active partners, must total 100%. Paused partners keep
  -- their share in the café (no line, nothing is redistributed to others).
  SELECT COALESCE(SUM(po.ownership_percentage), 0),
         COALESCE(SUM(po.ownership_percentage) FILTER (WHERE NOT p.dividends_paused), 0)
    INTO _share_total, _active_total
    FROM public.partner_ownership po JOIN public.partners p ON p.id = po.partner_id
   WHERE po.company_id = _company AND p.status = 'active' AND po.ownership_percentage > 0;
  _share_total := round(_share_total, 4);

  IF round(_active_total, 4) = 100 THEN
    SELECT po.partner_id INTO _largest
      FROM public.partner_ownership po JOIN public.partners p ON p.id = po.partner_id
     WHERE po.company_id = _company AND p.status = 'active' AND po.ownership_percentage > 0
     ORDER BY po.ownership_percentage DESC, po.partner_id LIMIT 1;
  END IF;

  FOR _r IN
    SELECT po.partner_id, p.name, po.ownership_percentage AS pct, p.dividends_paused AS paused
      FROM public.partner_ownership po JOIN public.partners p ON p.id = po.partner_id
     WHERE po.company_id = _company AND p.status = 'active' AND po.ownership_percentage > 0
     ORDER BY (po.partner_id = _largest) NULLS FIRST, po.partner_id
  LOOP
    _amt := CASE WHEN _r.paused OR _pool <= 0 THEN 0
                 WHEN _r.partner_id = _largest THEN round(_pool - _allocated, 2)
                 ELSE round(_pool * _r.pct / 100.0, 2) END;
    _allocated := _allocated + _amt;
    SELECT COALESCE(SUM(t.total_amount - t.settled_amount), 0) INTO _tab
      FROM public.partner_tab_orders t
     WHERE t.partner_id = _r.partner_id AND NOT t.is_settled AND t.created_at < _to_end;
    -- Partner advances (سلف) taken up to the end of the range.
    SELECT COALESCE(SUM(a.amount - a.deducted_amount), 0) INTO _adv
      FROM public.partner_advances a
     WHERE a.partner_id = _r.partner_id AND a.status = 'active' AND a.deducted_amount < a.amount AND a.advance_date <= _to;
    -- Order: tabs first, then advances; each only up to what the dividend covers.
    _tab_d := LEAST(round(_tab, 2), _amt);
    _adv_d := LEAST(round(_adv, 2), _amt - _tab_d);
    _lines := _lines || jsonb_build_array(jsonb_build_object(
      'partner_id', _r.partner_id, 'name', _r.name, 'pct', _r.pct, 'paused', _r.paused,
      'amount', _amt, 'tab_open', round(_tab, 2), 'tab_deduct', _tab_d,
      'advance_open', round(_adv, 2), 'advance_deduct', _adv_d,
      'cash_due', round(_amt - _tab_d - _adv_d, 2),
      'tab_carried', round(_tab - _tab_d, 2),
      'advance_carried', round(_adv - _adv_d, 2)));
  END LOOP;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', d.id, 'from', d.range_from, 'to', d.range_to)), '[]'::jsonb)
    INTO _overlap
    FROM public.profit_distributions d
   WHERE d.company_id = _company AND d.status = 'active' AND d.range_from IS NOT NULL
     AND d.range_from <= _to AND d.range_to >= _from;

  SELECT count(*) INTO _open_shifts FROM public.shifts s
   WHERE s.company_id = _company AND s.status = 'open' AND s.opened_at < _to_end;
  SELECT count(*) INTO _open_orders FROM public.orders o
   WHERE o.company_id = _company AND o.status = 'open'
     AND o.created_at >= public.business_day_start(_from, _company) AND o.created_at < _to_end;

  _sus := public.financial_self_sustainability();

  RETURN jsonb_build_object(
    'from', _from, 'to', _to, 'pnl', _pnl,
    'net_profit', round(_net, 2),
    'management_salary_total', round(_mgmt_total, 2),
    'management_salary_recorded', round(_mgmt_recorded, 2),
    'management_salary_due', _mgmt_due,
    'net_after_management', _after_mgmt,
    'reserve_type', _rtype, 'reserve_value', _rval, 'reserve_amount', round(_reserve, 2),
    'available_before_fund', _available,
    'development_fund', _fund_r,
    'partner_pool', GREATEST(_pool, 0),
    'retained_paused', round(GREATEST(_pool, 0) - _allocated, 2),
    'lines', _lines,
    'sustainability', _sus,
    'checks', jsonb_build_object(
      'range_valid', _to >= _from AND _to <= _today,
      'no_overlap', jsonb_array_length(_overlap) = 0,
      'no_open_shifts', _open_shifts = 0,
      'no_open_orders', _open_orders = 0,
      'net_positive', _available > 0,
      'self_sustaining', COALESCE((_sus->>'reached')::boolean, false),
      'fund_within_limit', _fund_r <= _available,
      'partner_pool_positive', _pool > 0,
      'shares_total_100', _share_total = 100),
    'overlaps', _overlap, 'open_shifts', _open_shifts, 'open_orders', _open_orders,
    'share_total', _share_total);
END $$;
REVOKE ALL ON FUNCTION public._payout_calc(uuid, date, date, numeric) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.payout_preview(_from date, _to date, _development_fund numeric DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF public.current_profile_id() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('reports.profit') OR public.has_permission('partners.view_profit') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF _from IS NULL OR _to IS NULL OR _to < _from THEN RAISE EXCEPTION 'Choose a valid date range'; END IF;
  RETURN public._payout_calc(public.current_company_id(), _from, _to, _development_fund);
END $$;
REVOKE ALL ON FUNCTION public.payout_preview(date, date, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payout_preview(date, date, numeric) TO authenticated;

-- ---------------------------------------------------------------------
-- Execute.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.execute_payout(_from date, _to date, _development_fund numeric DEFAULT 0, _notes text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _company uuid := public.current_company_id(); _profile uuid := public.current_profile_id();
  _calc jsonb; _checks jsonb; _k text; _currency text; _dist uuid; _line jsonb; _txn uuid;
  _left numeric; _take numeric; _t record; _tab_total numeric := 0; _partner_tab numeric; _to_end timestamptz;
  _a public.partner_advances; _partner_adv numeric;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only a super admin can run a profit payout'; END IF;
  IF _from IS NULL OR _to IS NULL OR _to < _from THEN RAISE EXCEPTION 'Choose a valid date range'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('payout:' || _company::text));

  _calc := public._payout_calc(_company, _from, _to, _development_fund);
  _checks := _calc->'checks';
  FOR _k IN SELECT jsonb_object_keys(_checks) LOOP
    IF NOT (_checks->>_k)::boolean THEN
      RAISE EXCEPTION 'Payout blocked: %', CASE _k
        WHEN 'range_valid' THEN 'the range must end today or earlier'
        WHEN 'no_overlap' THEN 'part of this range was already paid out'
        WHEN 'no_open_shifts' THEN 'close the open shift(s) in this range first'
        WHEN 'no_open_orders' THEN 'settle the unpaid order(s) in this range first'
        WHEN 'net_positive' THEN 'there is no positive distributable profit'
        WHEN 'self_sustaining' THEN 'self-sustainability not reached (3 profitable months in a row)'
        WHEN 'fund_within_limit' THEN 'the development fund is larger than the available profit'
        WHEN 'partner_pool_positive' THEN 'the development fund leaves nothing for partners'
        WHEN 'shares_total_100' THEN 'active partner shares must total 100%'
        ELSE _k END;
    END IF;
  END LOOP;

  SELECT currency INTO _currency FROM public.companies WHERE id = _company;
  _to_end := public.business_day_start(_to + 1, _company);

  INSERT INTO public.profit_distributions (company_id, period_id, range_from, range_to, net_profit,
    development_fund_amount, management_salary, reserve_amount, pnl_snapshot, notes, currency, status,
    distributed_at, created_by)
  VALUES (_company, NULL, _from, _to, (_calc->>'partner_pool')::numeric, (_calc->>'development_fund')::numeric,
    (_calc->>'management_salary_due')::numeric, (_calc->>'reserve_amount')::numeric, _calc - 'sustainability',
    NULLIF(btrim(COALESCE(_notes, '')), ''), COALESCE(_currency, 'EGP'), 'active', now(), _profile)
  RETURNING id INTO _dist;

  FOR _line IN SELECT * FROM jsonb_array_elements(_calc->'lines') LOOP
    CONTINUE WHEN (_line->>'amount')::numeric <= 0;
    INSERT INTO public.partner_ledger_transactions (company_id, partner_id, transaction_type, amount, currency,
      reference_type, reference_id, description, transaction_date, status, created_by)
    VALUES (_company, (_line->>'partner_id')::uuid, 'profit_distribution', (_line->>'amount')::numeric, COALESCE(_currency, 'EGP'),
      'profit_distribution', _dist, 'أرباح من ' || _from || ' إلى ' || _to, _to, 'active', _profile)
    RETURNING id INTO _txn;
    INSERT INTO public.profit_distribution_lines (distribution_id, partner_id, ownership_percentage, amount, ledger_transaction_id)
    VALUES (_dist, (_line->>'partner_id')::uuid, (_line->>'pct')::numeric, (_line->>'amount')::numeric, _txn);

    -- Settle partner tabs oldest-first, only up to the dividend. The rest stays owed.
    _left := (_line->>'tab_deduct')::numeric; _partner_tab := 0;
    FOR _t IN SELECT * FROM public.partner_tab_orders
               WHERE partner_id = (_line->>'partner_id')::uuid AND NOT is_settled AND created_at < _to_end
               ORDER BY created_at, id FOR UPDATE LOOP
      EXIT WHEN _left <= 0;
      _take := LEAST(round(_t.total_amount - _t.settled_amount, 2), _left);
      CONTINUE WHEN _take <= 0;
      UPDATE public.partner_tab_orders SET settled_amount = round(settled_amount + _take, 2),
        is_settled = round(settled_amount + _take, 2) >= total_amount,
        settled_at = CASE WHEN round(settled_amount + _take, 2) >= total_amount THEN now() ELSE settled_at END,
        distribution_id = _dist, updated_at = now()
       WHERE id = _t.id;
      INSERT INTO public.partner_tab_settlements (company_id, distribution_id, tab_order_id, partner_id, amount)
      VALUES (_company, _dist, _t.id, _t.partner_id, _take);
      _left := round(_left - _take, 2);
      _partner_tab := _partner_tab + _take;
    END LOOP;
    IF _partner_tab > 0 THEN
      INSERT INTO public.partner_ledger_transactions (company_id, partner_id, transaction_type, amount, currency,
        reference_type, reference_id, description, transaction_date, status, created_by)
      VALUES (_company, (_line->>'partner_id')::uuid, 'adjustment', -_partner_tab, COALESCE(_currency, 'EGP'),
        'partner_tab', _dist, 'خصم فواتير على الحساب', _to, 'active', _profile);
      _tab_total := _tab_total + _partner_tab;
    END IF;

    -- Then recover partner advances (سلف), oldest first, up to what's left of the dividend.
    _left := (_line->>'advance_deduct')::numeric; _partner_adv := 0;
    FOR _a IN SELECT * FROM public.partner_advances
               WHERE partner_id = (_line->>'partner_id')::uuid AND status = 'active'
                 AND deducted_amount < amount AND advance_date <= _to
               ORDER BY advance_date, created_at, id FOR UPDATE LOOP
      EXIT WHEN _left <= 0;
      _take := LEAST(round(_a.amount - _a.deducted_amount, 2), _left);
      CONTINUE WHEN _take <= 0;
      UPDATE public.partner_advances SET deducted_amount = round(deducted_amount + _take, 2) WHERE id = _a.id;
      INSERT INTO public.partner_advance_settlements (company_id, distribution_id, advance_id, partner_id, amount)
      VALUES (_company, _dist, _a.id, _a.partner_id, _take);
      _left := round(_left - _take, 2);
      _partner_adv := _partner_adv + _take;
    END LOOP;
    IF _partner_adv > 0 THEN
      INSERT INTO public.partner_ledger_transactions (company_id, partner_id, transaction_type, amount, currency,
        reference_type, reference_id, description, transaction_date, status, created_by)
      VALUES (_company, (_line->>'partner_id')::uuid, 'adjustment', -_partner_adv, COALESCE(_currency, 'EGP'),
        'partner_advance', _dist, 'خصم سلف الشريك', _to, 'active', _profile);
    END IF;
  END LOOP;

  UPDATE public.profit_distributions SET tab_deducted = round(_tab_total, 2) WHERE id = _dist;

  IF (_calc->>'development_fund')::numeric > 0 THEN
    INSERT INTO public.development_fund_ledger (company_id, direction, amount, distribution_id, entry_date, description, created_by)
    VALUES (_company, 'in', (_calc->>'development_fund')::numeric, _dist, public.business_today(_company),
      'حجز صندوق التطوير من أرباح ' || _from || ' إلى ' || _to, _profile);
  END IF;

  PERFORM public.log_audit('finance.payout', 'partners', 'profit_distributions', _dist, NULL,
    _calc - 'pnl' || jsonb_build_object('tab_deducted', _tab_total), _notes, NULL);
  RETURN _dist;
END $$;
REVOKE ALL ON FUNCTION public.execute_payout(date, date, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.execute_payout(date, date, numeric, text) TO authenticated;

-- ---------------------------------------------------------------------
-- Reverse (append-only). Blocked once any partner received cash for it,
-- or once fund money reserved by it has been spent.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reverse_payout(_distribution_id uuid, _reason text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _company uuid := public.current_company_id(); _profile uuid := public.current_profile_id();
  _d public.profit_distributions; _s record; _f public.development_fund_ledger;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only a super admin can reverse a payout'; END IF;
  IF char_length(btrim(COALESCE(_reason, ''))) < 5 THEN RAISE EXCEPTION 'A clear reason is required'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('payout:' || _company::text));
  SELECT * INTO _d FROM public.profit_distributions WHERE id = _distribution_id AND company_id = _company FOR UPDATE;
  IF _d.id IS NULL THEN RAISE EXCEPTION 'Payout not found'; END IF;
  IF _d.status <> 'active' THEN RAISE EXCEPTION 'This payout is already reversed'; END IF;
  IF EXISTS (SELECT 1 FROM public.partner_dividend_payouts WHERE distribution_id = _d.id AND status = 'active') THEN
    RAISE EXCEPTION 'Partners already received cash for this payout; reverse those cash payouts first';
  END IF;

  -- Partner ledger: mirror every entry created by the payout.
  INSERT INTO public.partner_ledger_transactions (company_id, partner_id, transaction_type, amount, currency,
    reference_type, reference_id, description, transaction_date, status, reversal_of, created_by)
  SELECT company_id, partner_id, 'adjustment', -amount, currency, 'profit_distribution_reversal', _d.id,
         'عكس توزيع أرباح: ' || btrim(_reason), public.business_today(_company), 'active', id, _profile
    FROM public.partner_ledger_transactions
   WHERE reference_id = _d.id AND status = 'active' AND reference_type IN ('profit_distribution', 'partner_tab', 'partner_advance');

  -- Partner tabs: give back exactly what this payout settled.
  FOR _s IN SELECT * FROM public.partner_tab_settlements WHERE distribution_id = _d.id AND status = 'active' LOOP
    UPDATE public.partner_tab_orders SET settled_amount = GREATEST(round(settled_amount - _s.amount, 2), 0),
      is_settled = false, settled_at = NULL,
      distribution_id = CASE WHEN distribution_id = _d.id THEN NULL ELSE distribution_id END, updated_at = now()
     WHERE id = _s.tab_order_id;
    UPDATE public.partner_tab_settlements SET status = 'reversed' WHERE id = _s.id;
  END LOOP;
  -- Legacy payouts settled whole tabs without a settlement record.
  UPDATE public.partner_tab_orders SET is_settled = false, settled_amount = 0, settled_at = NULL, distribution_id = NULL
   WHERE distribution_id = _d.id
     AND NOT EXISTS (SELECT 1 FROM public.partner_tab_settlements s WHERE s.tab_order_id = partner_tab_orders.id AND s.distribution_id = _d.id);

  -- Partner advances: owed again exactly as before the payout.
  UPDATE public.partner_advances a SET deducted_amount = GREATEST(round(a.deducted_amount - s.amount, 2), 0)
    FROM public.partner_advance_settlements s
   WHERE s.distribution_id = _d.id AND s.status = 'active' AND s.advance_id = a.id;
  UPDATE public.partner_advance_settlements SET status = 'reversed' WHERE distribution_id = _d.id AND status = 'active';

  -- Development fund.
  SELECT * INTO _f FROM public.development_fund_ledger
   WHERE distribution_id = _d.id AND direction = 'in' AND status = 'active' LIMIT 1;
  IF _f.id IS NOT NULL THEN
    IF public.development_fund_balance() < _f.amount THEN
      RAISE EXCEPTION 'The development fund money from this payout was already spent';
    END IF;
    INSERT INTO public.development_fund_ledger (company_id, direction, amount, distribution_id, entry_date, description, reversal_of, created_by)
    VALUES (_company, 'out', _f.amount, _d.id, public.business_today(_company), 'عكس حجز صندوق التطوير', _f.id, _profile);
  END IF;

  UPDATE public.profit_distributions SET status = 'reversed', reversed_at = now(), reversed_by = _profile,
    reverse_reason = btrim(_reason) WHERE id = _d.id;
  PERFORM public.log_audit('finance.payout_reverse', 'partners', 'profit_distributions', _d.id,
    to_jsonb(_d) - 'pnl_snapshot', jsonb_build_object('status', 'reversed'), btrim(_reason), NULL);
  RETURN _d.id;
END $$;
REVOKE ALL ON FUNCTION public.reverse_payout(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reverse_payout(uuid, text) TO authenticated;

-- ---------------------------------------------------------------------
-- Payout history with live drift check (did the range's P&L change later?).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.payout_history(_limit integer DEFAULT 24)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _company uuid := public.current_company_id(); _out jsonb := '[]'::jsonb; _d record; _now numeric;
BEGIN
  IF public.current_profile_id() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('reports.profit') OR public.has_permission('partners.view_profit') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  FOR _d IN
    SELECT d.*, COALESCE((SELECT jsonb_agg(jsonb_build_object('partner_id', l.partner_id, 'name', p.name,
                 'pct', l.ownership_percentage, 'amount', l.amount,
                 'paid', EXISTS (SELECT 1 FROM public.partner_dividend_payouts x
                                  WHERE x.distribution_id = d.id AND x.partner_id = l.partner_id AND x.status = 'active'))
                 ORDER BY l.amount DESC)
               FROM public.profit_distribution_lines l LEFT JOIN public.partners p ON p.id = l.partner_id
              WHERE l.distribution_id = d.id), '[]'::jsonb) AS lines
      FROM public.profit_distributions d
     WHERE d.company_id = _company
     ORDER BY COALESCE(d.range_to, d.created_at::date) DESC, d.created_at DESC
     LIMIT GREATEST(COALESCE(_limit, 24), 1)
  LOOP
    _now := CASE WHEN _d.status = 'active' AND _d.range_from IS NOT NULL AND _d.pnl_snapshot IS NOT NULL
                 THEN (public._range_pnl(_company, _d.range_from, _d.range_to)->>'net_profit')::numeric END;
    _out := _out || jsonb_build_array(jsonb_build_object(
      'id', _d.id, 'status', _d.status, 'from', _d.range_from, 'to', _d.range_to,
      'distributed_at', _d.distributed_at, 'partner_pool', _d.net_profit,
      'development_fund', _d.development_fund_amount, 'management_salary', _d.management_salary,
      'reserve_amount', _d.reserve_amount, 'tab_deducted', _d.tab_deducted, 'notes', _d.notes,
      'reverse_reason', _d.reverse_reason, 'lines', _d.lines,
      'net_profit_at_payout', _d.pnl_snapshot->'net_profit',
      'net_profit_now', _now,
      'drift', CASE WHEN _now IS NOT NULL THEN round(_now - (_d.pnl_snapshot->>'net_profit')::numeric, 2) END));
  END LOOP;
  RETURN jsonb_build_object('payouts', _out, 'development_fund_balance', public.development_fund_balance());
END $$;
REVOKE ALL ON FUNCTION public.payout_history(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payout_history(integer) TO authenticated;

-- ---------------------------------------------------------------------
-- Cash out a partner's line (cash from treasury, or bank / InstaPay).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.payout_partner_dividend(_distribution_id uuid, _partner_id uuid,
  _method text DEFAULT 'cash', _account_id uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _company uuid := public.current_company_id(); _profile uuid := public.current_profile_id();
  _d public.profit_distributions; _line numeric; _ded numeric; _net numeric; _acc uuid; _cash uuid; _txn uuid; _id uuid;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only the Super Admin can pay out dividends'; END IF;
  IF _method NOT IN ('cash', 'bank') THEN RAISE EXCEPTION 'Invalid payout method'; END IF;
  SELECT * INTO _d FROM public.profit_distributions WHERE id = _distribution_id AND company_id = _company FOR UPDATE;
  IF _d.id IS NULL OR _d.status <> 'active' THEN RAISE EXCEPTION 'Payout not found'; END IF;
  IF EXISTS (SELECT 1 FROM public.partner_dividend_payouts
              WHERE distribution_id = _d.id AND partner_id = _partner_id AND status = 'active') THEN
    RAISE EXCEPTION 'This dividend was already paid out';
  END IF;
  SELECT amount INTO _line FROM public.profit_distribution_lines WHERE distribution_id = _d.id AND partner_id = _partner_id;
  IF _line IS NULL THEN RAISE EXCEPTION 'This partner has no dividend in this payout'; END IF;
  SELECT COALESCE(-SUM(amount), 0) INTO _ded FROM public.partner_ledger_transactions
   WHERE partner_id = _partner_id AND reference_type IN ('partner_tab', 'partner_advance') AND reference_id = _d.id AND status = 'active';
  _net := round(_line - _ded, 2);

  IF _net > 0 THEN
    _acc := COALESCE(_account_id, public.default_cash_account(_company, _method));
    IF _acc IS NULL THEN RAISE EXCEPTION 'No cash account available'; END IF;
    _cash := public.post_cash_txn(_company, _acc, 'out', _net, 'partner_dividend', _method,
      public.business_today(_company), 'partner_dividend', _d.id,
      CASE WHEN _method = 'cash' THEN 'Partner dividend payout (cash)' ELSE 'Partner dividend payout (bank / InstaPay)' END,
      NULL, _method = 'cash');
    INSERT INTO public.partner_ledger_transactions (company_id, partner_id, transaction_type, amount, currency,
      reference_type, reference_id, description, transaction_date, status, created_by)
    VALUES (_company, _partner_id, 'withdrawal', _net, _d.currency, 'partner_dividend', _d.id,
      CASE WHEN _method = 'cash' THEN 'صرف الأرباح نقداً' ELSE 'صرف الأرباح تحويل بنكي' END,
      public.business_today(_company), 'active', _profile)
    RETURNING id INTO _txn;
  END IF;

  INSERT INTO public.partner_dividend_payouts (company_id, period_id, partner_id, distribution_id, amount,
    cash_transaction_id, ledger_transaction_id, created_by)
  VALUES (_company, NULL, _partner_id, _d.id, _net, _cash, _txn, _profile) RETURNING id INTO _id;
  PERFORM public.log_audit('partner.dividend_payout', 'partners', 'partner_dividend_payouts', _id, NULL,
    jsonb_build_object('distribution_id', _d.id, 'dividend', _line, 'tab_deducted', _ded, 'paid', _net, 'method', _method), NULL, NULL);
  RETURN _id;
END $$;

-- Undo a cash payout (money returned to the treasury account it left).
CREATE OR REPLACE FUNCTION public.reverse_partner_dividend_payout(_payout_id uuid, _reason text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _profile uuid := public.current_profile_id(); _pp public.partner_dividend_payouts;
  _c public.cash_transactions; _l public.partner_ledger_transactions;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only the Super Admin can reverse a dividend payout'; END IF;
  IF char_length(btrim(COALESCE(_reason, ''))) < 5 THEN RAISE EXCEPTION 'A clear reason is required'; END IF;
  SELECT * INTO _pp FROM public.partner_dividend_payouts
   WHERE id = _payout_id AND company_id = public.current_company_id() FOR UPDATE;
  IF _pp.id IS NULL OR _pp.status <> 'active' THEN RAISE EXCEPTION 'Dividend payout not found'; END IF;
  SELECT * INTO _c FROM public.cash_transactions WHERE id = _pp.cash_transaction_id AND status = 'active';
  IF _c.id IS NOT NULL THEN
    INSERT INTO public.cash_transactions (company_id, account_id, direction, amount, method, category, txn_date,
      reference_type, reference_id, description, status, reversal_of, created_by)
    VALUES (_c.company_id, _c.account_id, 'in', _c.amount, _c.method, _c.category, public.business_today(_c.company_id),
      'partner_dividend_reversal', _pp.id, 'عكس صرف أرباح: ' || btrim(_reason), 'active', _c.id, _profile);
    UPDATE public.cash_transactions SET status = 'reversed' WHERE id = _c.id;
  END IF;
  SELECT * INTO _l FROM public.partner_ledger_transactions WHERE id = _pp.ledger_transaction_id AND status = 'active';
  IF _l.id IS NOT NULL THEN
    INSERT INTO public.partner_ledger_transactions (company_id, partner_id, transaction_type, amount, currency,
      reference_type, reference_id, description, transaction_date, status, reversal_of, created_by)
    VALUES (_l.company_id, _l.partner_id, 'adjustment', _l.amount, _l.currency, 'partner_dividend_reversal', _pp.id,
      'عكس صرف أرباح: ' || btrim(_reason), public.business_today(_l.company_id), 'active', _l.id, _profile);
  END IF;
  UPDATE public.partner_dividend_payouts SET status = 'reversed' WHERE id = _pp.id;
  PERFORM public.log_audit('partner.dividend_payout_reverse', 'partners', 'partner_dividend_payouts', _pp.id,
    to_jsonb(_pp), NULL, btrim(_reason), NULL);
  RETURN _pp.id;
END $$;

CREATE OR REPLACE FUNCTION public.payout_partner_combined(_distribution_id uuid, _partner_id uuid,
  _salary_payment_id uuid, _method text DEFAULT 'cash')
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only the Super Admin can pay out'; END IF;
  PERFORM public.pay_salary(_salary_payment_id, NULL, _method);
  PERFORM public.payout_partner_dividend(_distribution_id, _partner_id, _method, NULL);
END $$;

REVOKE ALL ON FUNCTION public.payout_partner_dividend(uuid, uuid, text, uuid),
  public.reverse_partner_dividend_payout(uuid, text),
  public.payout_partner_combined(uuid, uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payout_partner_dividend(uuid, uuid, text, uuid),
  public.reverse_partner_dividend_payout(uuid, text),
  public.payout_partner_combined(uuid, uuid, uuid, text) TO authenticated;

-- ---------------------------------------------------------------------
-- Manager % salary per payroll month (replaces the period-based version).
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.hr_manager_percent_pay(date, date);
CREATE FUNCTION public.hr_manager_percent_pay(_period_start date, _period_end date)
RETURNS TABLE(partner_id uuid, user_id uuid, employee_name text, pct numeric, base_net_profit numeric, amount numeric,
  salary_id uuid, recorded_amount numeric, paid_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _company uuid := public.current_company_id(); _pnl jsonb;
BEGIN
  IF NOT (public.has_permission('payroll.view') OR public.is_super_admin()) THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF _period_start IS NULL OR _period_end IS NULL OR _period_end < _period_start THEN RAISE EXCEPTION 'invalid payroll period'; END IF;
  _pnl := public._range_pnl(_company, _period_start, _period_end);
  RETURN QUERY
  SELECT m.partner_id, m.user_id, m.partner_name, m.pct, m.base_net_profit, m.amount, sp.id, sp.net_amount, sp.paid_at
    FROM public._management_salary(_company, _period_start, _period_end, _pnl) m
    LEFT JOIN LATERAL (SELECT s.id, s.net_amount, s.paid_at FROM public.salary_payments s
                        WHERE s.user_id = m.user_id AND s.status = 'active' AND s.salary_kind = 'manager_percent'
                          AND s.period_start = _period_start
                        ORDER BY s.created_at DESC LIMIT 1) sp ON true
   WHERE m.user_id IS NOT NULL;
END $$;

CREATE OR REPLACE FUNCTION public.record_manager_percent_salary(_partner_id uuid, _period_start date, _period_end date)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _actor uuid := public.current_profile_id(); _company uuid := public.current_company_id(); _r record; _paid timestamptz; _id uuid;
BEGIN
  IF NOT (public.has_permission('payroll.manage') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  SELECT * INTO _r FROM public.hr_manager_percent_pay(_period_start, _period_end) x WHERE x.partner_id = _partner_id;
  IF _r.partner_id IS NULL THEN RAISE EXCEPTION 'This partner has no percentage salary for this month'; END IF;
  IF COALESCE(_r.amount, 0) <= 0 THEN RAISE EXCEPTION 'No net profit yet, so there is no salary to record'; END IF;
  IF _r.salary_id IS NOT NULL THEN
    SELECT paid_at INTO _paid FROM public.salary_payments WHERE id = _r.salary_id;
    IF _paid IS NOT NULL THEN RAISE EXCEPTION 'This salary is already paid'; END IF;
    UPDATE public.salary_payments SET base_amount = _r.amount, bonus = 0, deduction = 0, updated_at = now() WHERE id = _r.salary_id;
    _id := _r.salary_id;
  ELSE
    INSERT INTO public.salary_payments (company_id, user_id, period_start, period_end, base_amount, bonus, deduction, created_by, salary_kind)
    VALUES (_company, _r.user_id, _period_start, _period_end, _r.amount, 0, 0, _actor, 'manager_percent')
    RETURNING id INTO _id;
  END IF;
  PERFORM public.log_audit('payroll.manager_percent', 'finance', 'salary_payments', _id, NULL,
    jsonb_build_object('partner_id', _partner_id, 'pct', _r.pct, 'base_net_profit', _r.base_net_profit, 'amount', _r.amount), NULL, NULL);
  RETURN _id;
END $$;

REVOKE ALL ON FUNCTION public.hr_manager_percent_pay(date, date), public.record_manager_percent_salary(uuid, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.hr_manager_percent_pay(date, date), public.record_manager_percent_salary(uuid, date, date) TO authenticated;

-- ---------------------------------------------------------------------
-- Partner self-view.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_my_partner_profit_summary()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _partner uuid := public.current_partner_id(); _company uuid := public.current_company_id();
  _d public.profit_distributions; _pct numeric; _amt numeric; _capital numeric := 0; _mine numeric := 0; _lifetime numeric := 0;
BEGIN
  IF public.current_profile_id() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF _partner IS NULL THEN RAISE EXCEPTION 'Not a partner'; END IF;
  SELECT COALESCE(SUM(cc.amount), 0) INTO _capital FROM public.partner_capital_contributions cc
    JOIN public.partners pa ON pa.id = cc.partner_id
   WHERE cc.company_id = _company AND cc.status = 'active' AND pa.status = 'active';
  SELECT COALESCE(SUM(cc.amount), 0) INTO _mine FROM public.partner_capital_contributions cc
   WHERE cc.company_id = _company AND cc.status = 'active' AND cc.partner_id = _partner;
  SELECT COALESCE(SUM(l.amount), 0) INTO _lifetime FROM public.profit_distribution_lines l
    JOIN public.profit_distributions d ON d.id = l.distribution_id
   WHERE d.company_id = _company AND d.status = 'active' AND l.partner_id = _partner;
  SELECT * INTO _d FROM public.profit_distributions
   WHERE company_id = _company AND status = 'active'
   ORDER BY COALESCE(range_to, created_at::date) DESC, created_at DESC LIMIT 1;
  IF _d.id IS NOT NULL THEN
    SELECT l.ownership_percentage, l.amount INTO _pct, _amt
      FROM public.profit_distribution_lines l WHERE l.distribution_id = _d.id AND l.partner_id = _partner;
  END IF;
  RETURN jsonb_build_object(
    'has_period', _d.id IS NOT NULL, 'period_start', _d.range_from, 'period_end', _d.range_to,
    'distributed_at', _d.distributed_at, 'company_net_profit', round(COALESCE(_d.net_profit, 0), 2),
    'my_percentage', round(COALESCE(_pct, CASE WHEN _capital > 0 THEN _mine / _capital * 100 ELSE 0 END), 2),
    'my_profit', round(COALESCE(_amt, 0), 2), 'my_capital', round(_mine, 2), 'lifetime_profit', round(_lifetime, 2));
END $$;

-- ---------------------------------------------------------------------
-- Go-live reset: also clear the new ledgers, never touches periods logic.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.go_live_reset(_confirm text, _reason text, _reset_stock boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _c uuid := public.current_company_id(); _t text; _n int; _out jsonb := '{}'::jsonb;
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF _confirm <> 'RESET' THEN RAISE EXCEPTION 'Type RESET to confirm'; END IF;
  IF length(btrim(COALESCE(_reason, ''))) < 3 THEN RAISE EXCEPTION 'Reason required'; END IF;
  PERFORM set_config('app.allow_test_reset', 'on', true);
  FOREACH _t IN ARRAY ARRAY['order_item_modifiers', 'order_refunds', 'order_payments', 'order_items',
    'partner_tab_settlements', 'partner_tab_orders', 'customer_points_transactions', 'customer_wallet_transactions',
    'electronic_payment_settlements', 'orders',
    'shift_staff', 'cash_transactions', 'expenses', 'stock_movements', 'stocktake_lines', 'stocktakes', 'stock_transfer_items',
    'stock_transfers', 'stock_overrides', 'purchase_return_items', 'purchase_returns', 'purchase_payments', 'purchase_items',
    'purchases', 'payroll_deductions', 'salary_payments', 'employee_advances', 'staff_penalties', 'staff_bonuses', 'attendance',
    'development_fund_ledger', 'partner_advance_settlements', 'profit_distribution_lines', 'partner_dividend_payouts',
    'profit_distributions', 'partner_advances',
    'partner_withdrawal_requests', 'partner_ledger_transactions', 'period_partner_shares', 'partner_period_freezes',
    'shifts', 'order_counters', 'notifications', 'audit_logs']
  LOOP
    BEGIN
      IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = _t AND column_name = 'company_id') THEN
        EXECUTE format('DELETE FROM public.%I WHERE company_id = $1', _t) USING _c;
      ELSE
        EXECUTE format('DELETE FROM public.%I', _t);
      END IF;
      GET DIAGNOSTICS _n = ROW_COUNT; _out := _out || jsonb_build_object(_t, _n);
    EXCEPTION WHEN undefined_table THEN NULL; END;
  END LOOP;
  -- Customers stay, but their wallets restart with the cleared history.
  BEGIN
    UPDATE public.customers SET wallet_balance = 0, cashback_progress = 0 WHERE company_id = _c;
  EXCEPTION WHEN undefined_column THEN NULL; END;
  ALTER TABLE public.accounting_periods DISABLE TRIGGER USER;
  DELETE FROM public.accounting_periods WHERE company_id = _c;
  ALTER TABLE public.accounting_periods ENABLE TRIGGER USER;
  IF _reset_stock THEN
    UPDATE public.branch_stock SET quantity = 0, bar_quantity = 0 WHERE branch_id IN (SELECT id FROM public.branches WHERE company_id = _c);
  END IF;
  PERFORM public.log_audit('system.go_live_reset', 'governance', 'companies', _c, NULL, _out, _reason, NULL);
  RETURN _out;
END $$;

-- ---------------------------------------------------------------------
-- Partner advances (سلف).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_partner_advance(_partner_id uuid, _amount numeric, _method text DEFAULT 'cash',
  _reason text DEFAULT NULL, _advance_date date DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _company uuid := public.current_company_id(); _profile uuid := public.current_profile_id();
  _amt numeric := round(COALESCE(_amount, 0), 2); _acc uuid; _cash uuid; _id uuid; _day date;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only the Super Admin can give a partner an advance'; END IF;
  IF _amt <= 0 THEN RAISE EXCEPTION 'Amount must be greater than zero'; END IF;
  IF COALESCE(_method, 'cash') NOT IN ('cash', 'bank') THEN RAISE EXCEPTION 'Invalid payout method'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.partners WHERE id = _partner_id AND company_id = _company AND status = 'active') THEN
    RAISE EXCEPTION 'Partner not found';
  END IF;
  _day := COALESCE(_advance_date, public.business_today(_company));
  _acc := public.default_cash_account(_company, COALESCE(_method, 'cash'));
  IF _acc IS NULL THEN RAISE EXCEPTION 'No cash account available'; END IF;
  INSERT INTO public.partner_advances (company_id, partner_id, amount, advance_date, method, reason, created_by)
  VALUES (_company, _partner_id, _amt, _day, COALESCE(_method, 'cash'), NULLIF(btrim(COALESCE(_reason, '')), ''), _profile)
  RETURNING id INTO _id;
  _cash := public.post_cash_txn(_company, _acc, 'out', _amt, 'partner_advance', COALESCE(_method, 'cash'), _day,
    'partner_advance', _id, 'سلفة شريك', NULL, COALESCE(_method, 'cash') = 'cash');
  UPDATE public.partner_advances SET cash_transaction_id = _cash WHERE id = _id;
  PERFORM public.log_audit('partner.advance', 'partners', 'partner_advances', _id, NULL,
    jsonb_build_object('partner_id', _partner_id, 'amount', _amt, 'method', _method), _reason, NULL);
  RETURN _id;
END $$;

-- Cancel an advance nothing was recovered from yet; the cash goes back to the account it left.
CREATE OR REPLACE FUNCTION public.cancel_partner_advance(_advance_id uuid, _reason text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _profile uuid := public.current_profile_id(); _a public.partner_advances; _c public.cash_transactions;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF char_length(btrim(COALESCE(_reason, ''))) < 3 THEN RAISE EXCEPTION 'A reason is required'; END IF;
  SELECT * INTO _a FROM public.partner_advances WHERE id = _advance_id AND company_id = public.current_company_id() FOR UPDATE;
  IF _a.id IS NULL OR _a.status <> 'active' THEN RAISE EXCEPTION 'Advance not found'; END IF;
  IF _a.deducted_amount > 0 THEN RAISE EXCEPTION 'Part of this advance was already recovered from a payout'; END IF;
  SELECT * INTO _c FROM public.cash_transactions WHERE id = _a.cash_transaction_id AND status = 'active';
  IF _c.id IS NOT NULL THEN
    INSERT INTO public.cash_transactions (company_id, account_id, direction, amount, method, category, txn_date,
      reference_type, reference_id, description, status, reversal_of, created_by)
    VALUES (_c.company_id, _c.account_id, 'in', _c.amount, _c.method, _c.category, public.business_today(_c.company_id),
      'partner_advance_reversal', _a.id, 'إلغاء سلفة شريك: ' || btrim(_reason), 'active', _c.id, _profile);
    UPDATE public.cash_transactions SET status = 'reversed' WHERE id = _c.id;
  END IF;
  UPDATE public.partner_advances SET status = 'cancelled' WHERE id = _a.id;
  PERFORM public.log_audit('partner.advance_cancel', 'partners', 'partner_advances', _a.id, to_jsonb(_a), NULL, btrim(_reason), NULL);
  RETURN _a.id;
END $$;

REVOKE ALL ON FUNCTION public.record_partner_advance(uuid, numeric, text, text, date), public.cancel_partner_advance(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_partner_advance(uuid, numeric, text, text, date), public.cancel_partner_advance(uuid, text) TO authenticated;

-- ---------------------------------------------------------------------
-- Partner balance = ledger (withdrawals subtract) minus advances not yet
-- recovered. The view behind the Partners page used to ADD withdrawals;
-- both now share this single definition.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.partner_balance(_partner_id uuid)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT round(
    COALESCE((SELECT SUM(CASE WHEN t.transaction_type = 'withdrawal' THEN -abs(t.amount) ELSE t.amount END)
                FROM public.partner_ledger_transactions t
               WHERE t.partner_id = _partner_id AND t.status = 'active'), 0)
    - COALESCE((SELECT SUM(a.amount - a.deducted_amount) FROM public.partner_advances a
                 WHERE a.partner_id = _partner_id AND a.status = 'active'), 0), 2)
$$;

CREATE OR REPLACE VIEW public.partner_balances WITH (security_invoker = true) AS
SELECT p.id AS partner_id, p.company_id, p.name, public.partner_balance(p.id) AS balance
  FROM public.partners p;

-- ---------------------------------------------------------------------
-- Partner dashboard: the signed-in partner's view of any date range.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.my_partner_dashboard(_from date, _to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _company uuid := public.current_company_id(); _partner uuid := public.current_partner_id();
  _pnl jsonb; _t0 timestamptz; _t1 timestamptz; _tabs jsonb; _tab_total numeric; _shifts jsonb; _debts numeric;
  _advances numeric; _share numeric; _p public.partners;
BEGIN
  IF public.current_profile_id() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF _partner IS NULL THEN RAISE EXCEPTION 'Not a partner'; END IF;
  IF _from IS NULL OR _to IS NULL OR _to < _from THEN RAISE EXCEPTION 'Choose a valid date range'; END IF;
  SELECT * INTO _p FROM public.partners WHERE id = _partner;
  _t0 := public.business_day_start(_from, _company);
  _t1 := public.business_day_start(_to + 1, _company);
  _pnl := public._range_pnl(_company, _from, _to);

  SELECT COALESCE(SUM(t.total_amount), 0),
         COALESCE(jsonb_agg(jsonb_build_object('order_number', o.order_number, 'created_at', t.created_at,
           'amount', t.total_amount, 'open', round(t.total_amount - t.settled_amount, 2)) ORDER BY t.created_at DESC), '[]'::jsonb)
    INTO _tab_total, _tabs
    FROM public.partner_tab_orders t JOIN public.orders o ON o.id = t.order_id
   WHERE t.partner_id = _partner AND t.created_at >= _t0 AND t.created_at < _t1;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'shift_id', s.f->>'shiftId', 'opened_at', s.f->>'openedAt', 'closed_at', s.f->>'closedAt',
           'cashier', s.cashier, 'net_sales', (s.f->>'netSales')::numeric, 'gross_margin', (s.f->>'grossMargin')::numeric,
           'variance', (s.f->>'variance')::numeric) ORDER BY s.f->>'openedAt' DESC), '[]'::jsonb)
    INTO _shifts
    FROM (SELECT public._shift_figures(sh) AS f, COALESCE(NULLIF(up.display_name, ''), up.first_name) AS cashier
            FROM public.shifts sh LEFT JOIN public.user_profiles up ON up.id = sh.user_id
           WHERE sh.company_id = _company AND sh.opened_at >= _t0 AND sh.opened_at < _t1) s;

  SELECT COALESCE(SUM(p.total - p.returned_amount - p.paid_amount), 0) INTO _debts
    FROM public.purchases p
   WHERE p.company_id = _company AND p.status <> 'cancelled' AND round(p.total - p.returned_amount - p.paid_amount, 2) > 0;

  SELECT COALESCE(SUM(a.amount - a.deducted_amount), 0) INTO _advances
    FROM public.partner_advances a WHERE a.partner_id = _partner AND a.status = 'active';
  SELECT ownership_percentage INTO _share FROM public.partner_ownership WHERE partner_id = _partner;

  RETURN jsonb_build_object(
    'from', _from, 'to', _to, 'partner_name', _p.name, 'share_pct', COALESCE(_share, 0),
    'gross_sales', _pnl->'gross_sales', 'revenue', _pnl->'revenue', 'net_profit', _pnl->'net_profit',
    'my_share_estimate', CASE WHEN (_pnl->>'net_profit')::numeric > 0
                              THEN round((_pnl->>'net_profit')::numeric * COALESCE(_share, 0) / 100.0, 2) ELSE 0 END,
    'my_tab_total', round(_tab_total, 2), 'my_tabs', _tabs,
    'my_open_advances', round(_advances, 2),
    'my_balance', public.partner_balance(_partner),
    'supplier_debts', round(_debts, 2),
    'shifts', _shifts);
END $$;
REVOKE ALL ON FUNCTION public.my_partner_dashboard(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_partner_dashboard(date, date) TO authenticated;
