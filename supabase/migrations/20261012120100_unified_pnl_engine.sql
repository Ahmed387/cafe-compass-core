-- =====================================================================
-- Core re-architecture 2/6 — the single P&L engine
--   range_pnl(from, to)      : company P&L for any business-date range
--   shift_financials(ids[])  : per-shift figures with the same formulas
--   financial_self_sustainability() : monthly history + runway, on the fly
--
-- Formula reference (all amounts exclude VAT):
--   gross_sales    = Σ (base price + modifiers) × qty of active lines
--   revenue        = gross − offers − manual discounts − points − refunds (ex-tax)
--   cogs           = Σ sale-time raw recipe cost (line_cogs; waste % never marks it up)
--                    − cost of lines returned to stock by refunds
--   gross_profit   = revenue − cogs − stock waste − stocktake shortages
--   net_profit     = gross_profit − approved expenses − payroll cost
--                    − drawer shortages + drawer overages
-- Staff-borne losses (shortages, staff-fault refunds, waste charged to staff)
-- are still counted as
-- losses here; the matching staff penalty lowers payroll cost when deducted,
-- so the café's result is exact instead of double-benefiting.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.tender_key(_method text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO 'public' AS $$
  SELECT CASE
    -- Customer credit (cashback wallet; legacy loyalty points) is not money in the drawer.
    WHEN lower(COALESCE(_method, 'cash')) IN ('points', 'cashback') THEN 'points'
    WHEN lower(COALESCE(_method, 'cash')) ~ '(partner|tab|account)' THEN 'partner_tab'
    WHEN lower(COALESCE(_method, 'cash')) ~ '(insta|bank)' THEN 'instapay'
    WHEN lower(COALESCE(_method, 'cash')) ~ '(wallet|vodafone)' THEN 'wallet'
    WHEN lower(COALESCE(_method, 'cash')) ~ '(card|visa)' THEN 'visa'
    ELSE 'cash'
  END
$$;

-- Labour cost of a salary line = what the café actually bears for that work:
-- net pay + advances recovered from it (advances are prepaid salary, not savings).
CREATE OR REPLACE FUNCTION public.salary_line_cost(_s public.salary_payments)
RETURNS numeric LANGUAGE sql IMMUTABLE SET search_path TO 'public' AS $$
  SELECT COALESCE(_s.net_amount, 0) + COALESCE(_s.advance_deduction, 0)
$$;

-- Internal engine (no permission checks). Callers authorise first.
CREATE OR REPLACE FUNCTION public._range_pnl(_company uuid, _from date, _to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  _t0 timestamptz; _t1 timestamptz;
  _gross numeric := 0; _promo numeric := 0; _manual numeric := 0; _points numeric := 0;
  _tax numeric := 0; _refunds numeric := 0; _refund_tax numeric := 0; _orders int := 0;
  _cogs_sold numeric := 0; _cogs_returned numeric := 0; _refund_waste numeric := 0;
  _waste numeric := 0; _waste_staff numeric := 0; _stocktake numeric := 0; _shortage numeric := 0; _over numeric := 0;
  _expenses numeric := 0; _pending_exp numeric := 0; _pending_cnt int := 0;
  _payroll numeric := 0; _mgmt_recorded numeric := 0; _tab_open numeric := 0;
  _revenue numeric; _cogs numeric; _gp numeric; _ops numeric; _net numeric;
BEGIN
  IF _company IS NULL THEN RAISE EXCEPTION 'Company not found'; END IF;
  IF _from IS NULL OR _to IS NULL OR _to < _from THEN RAISE EXCEPTION 'Choose a valid date range'; END IF;

  _t0 := public.business_day_start(_from, _company);
  _t1 := public.business_day_start(_to + 1, _company);

  -- Sales (orders counted on the business day they were created) -----
  SELECT COUNT(*), COALESCE(SUM(o.promotional_discount), 0), COALESCE(SUM(o.discount_amount), 0),
         COALESCE(SUM(o.tax_amount), 0)
    INTO _orders, _promo, _manual, _tax
    FROM public.orders o
   WHERE o.company_id = _company
     AND o.status IN ('completed', 'pending', 'refunded', 'partially_refunded')
     AND o.created_at >= _t0 AND o.created_at < _t1;

  SELECT COALESCE(SUM((oi.base_price + COALESCE(oi.modifiers_total, 0)) * oi.quantity), 0),
         COALESCE(SUM(public.line_cogs(oi)), 0)
    INTO _gross, _cogs_sold
    FROM public.orders o JOIN public.order_items oi ON oi.order_id = o.id
   WHERE o.company_id = _company
     AND o.status IN ('completed', 'pending', 'refunded', 'partially_refunded')
     AND o.created_at >= _t0 AND o.created_at < _t1
     AND oi.status = 'active';

  SELECT COALESCE(SUM(op.amount), 0) INTO _points
    FROM public.orders o JOIN public.order_payments op ON op.order_id = o.id
   WHERE o.company_id = _company
     AND o.status IN ('completed', 'pending', 'refunded', 'partially_refunded')
     AND o.created_at >= _t0 AND o.created_at < _t1
     AND public.tender_key(op.method_key) = 'points';

  -- Refunds are recognised on the day they happen. Refunds of cancelled orders are
  -- skipped: a cancelled order's sale is already excluded, so its refund would
  -- otherwise be deducted twice.
  SELECT COALESCE(SUM(r.amount), 0), COALESCE(SUM(r.tax_amount), 0)
    INTO _refunds, _refund_tax
    FROM public.order_refunds r JOIN public.orders o ON o.id = r.order_id
   WHERE r.company_id = _company AND r.status = 'active' AND o.status <> 'cancelled'
     AND r.created_at >= _t0 AND r.created_at < _t1;

  -- Restocked refund lines give their cost back; wasted ones were already in COGS.
  SELECT COALESCE(SUM(CASE WHEN e->>'disposition' = 'restock'
                           THEN COALESCE(public.order_item_unit_cogs(NULLIF(e->>'order_item_id', '')::uuid),
                                         COALESCE((e->>'unit_cost')::numeric, 0) * 1.05)
                                * COALESCE((e->>'quantity')::numeric, 0) END), 0),
         COALESCE(SUM(CASE WHEN e->>'disposition' = 'waste'
                           THEN COALESCE((e->>'unit_cost')::numeric, 0) * COALESCE((e->>'quantity')::numeric, 0) END), 0)
    INTO _cogs_returned, _refund_waste
    FROM public.order_refunds r JOIN public.orders o ON o.id = r.order_id
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(r.items_payload, '[]'::jsonb)) e
   WHERE r.company_id = _company AND r.status = 'active' AND o.status <> 'cancelled'
     AND r.created_at >= _t0 AND r.created_at < _t1;

  -- A full refund (refund_order) returns every active line to stock, so its cost comes back too.
  _cogs_returned := _cogs_returned + COALESCE((
    SELECT SUM(public.line_cogs(oi))
      FROM public.order_refunds r
      JOIN public.orders o ON o.id = r.order_id
      JOIN public.order_items oi ON oi.order_id = o.id AND oi.status = 'active'
     WHERE r.company_id = _company AND r.status = 'active' AND r.kind = 'full' AND r.items_payload IS NULL
       AND COALESCE(r.origin, 'manual') = 'manual' AND o.status = 'refunded'
       AND r.created_at >= _t0 AND r.created_at < _t1), 0);

  -- Stock losses -----------------------------------------------------
  -- Waste charged to staff (record_waste) is recovered as payroll penalties,
  -- which lower payroll cost when deducted; it is listed apart for clarity.
  SELECT COALESCE(SUM(-sm.quantity * sm.unit_cost), 0),
         COALESCE(SUM(-sm.quantity * sm.unit_cost) FILTER (WHERE sm.waste_bearer IN ('staff', 'all_staff')), 0)
    INTO _waste, _waste_staff
    FROM public.stock_movements sm
   WHERE sm.company_id = _company AND sm.movement_type = 'waste' AND sm.quantity < 0
     AND sm.created_at >= _t0 AND sm.created_at < _t1;

  SELECT COALESCE(SUM(st.shortage_cost), 0) INTO _stocktake
    FROM public.stocktakes st
   WHERE st.company_id = _company AND st.shortage_cost > 0
     AND st.created_at >= _t0 AND st.created_at < _t1;

  -- Drawer differences (by closing time) --------------------------------
  SELECT COALESCE(SUM(GREATEST(-sh.variance, 0)), 0), COALESCE(SUM(GREATEST(sh.variance, 0)), 0)
    INTO _shortage, _over
    FROM public.shifts sh
   WHERE sh.company_id = _company AND sh.status = 'closed'
     AND sh.closed_at >= _t0 AND sh.closed_at < _t1;

  -- Operating expenses --------------------------------------------------
  SELECT COALESCE(SUM(e.amount) FILTER (WHERE e.approved_at IS NOT NULL), 0),
         COALESCE(SUM(e.amount) FILTER (WHERE e.approved_at IS NULL), 0),
         COUNT(*) FILTER (WHERE e.approved_at IS NULL)
    INTO _expenses, _pending_exp, _pending_cnt
    FROM public.expenses e
   WHERE e.company_id = _company AND e.status = 'active'
     AND e.expense_date BETWEEN _from AND _to;

  -- Payroll: each salary line is spread over its own days, so any range gets
  -- exactly its share and nothing is counted twice.
  SELECT COALESCE(SUM(public.salary_line_cost(s)
           * (LEAST(s.period_end, _to) - GREATEST(s.period_start, _from) + 1)::numeric
           / (s.period_end - s.period_start + 1)), 0),
         COALESCE(SUM(public.salary_line_cost(s)
           * (LEAST(s.period_end, _to) - GREATEST(s.period_start, _from) + 1)::numeric
           / (s.period_end - s.period_start + 1)) FILTER (WHERE s.salary_kind = 'manager_percent'), 0)
    INTO _payroll, _mgmt_recorded
    FROM public.salary_payments s
   WHERE s.company_id = _company AND s.status = 'active'
     AND s.period_start <= _to AND s.period_end >= _from;

  -- Informational: partner tab balance still owed from sales in this range.
  SELECT COALESCE(SUM(t.total_amount - t.settled_amount), 0) INTO _tab_open
    FROM public.partner_tab_orders t
   WHERE t.company_id = _company AND NOT t.is_settled
     AND t.created_at >= _t0 AND t.created_at < _t1;

  -- Results ------------------------------------------------------------
  _revenue := _gross - _promo - _manual - _points - (_refunds - _refund_tax);
  _cogs := _cogs_sold - _cogs_returned;
  _gp := _revenue - _cogs - _waste - _stocktake;
  _ops := _expenses + _payroll + _shortage - _over;
  _net := _gp - _ops;

  RETURN jsonb_build_object(
    'from', _from, 'to', _to, 'days', (_to - _from + 1), 'orders_count', _orders,
    'gross_sales', round(_gross, 2),
    'promo_discount', round(_promo, 2),
    'manual_discounts', round(_manual, 2),
    'points_redeemed', round(_points, 2),
    'refunds_total', round(_refunds - _refund_tax, 2),
    'revenue', round(_revenue, 2),
    'tax_collected', round(_tax - _refund_tax, 2),
    'cogs', round(_cogs, 2),
    'cogs_returned', round(_cogs_returned, 2),
    'refund_waste_info', round(_refund_waste, 2),
    'waste_cost', round(_waste, 2),
    'waste_business', round(_waste - _waste_staff, 2),
    'waste_charged_staff', round(_waste_staff, 2),
    'stocktake_shortage', round(_stocktake, 2),
    'gross_profit', round(_gp, 2),
    'expenses_total', round(_expenses, 2),
    'expenses_pending', round(_pending_exp, 2),
    'expenses_pending_count', _pending_cnt,
    'payroll_total', round(_payroll, 2),
    'management_salary_recorded', round(_mgmt_recorded, 2),
    'cash_shortage', round(_shortage, 2),
    'cash_over', round(_over, 2),
    'operating_total', round(_ops, 2),
    'net_profit', round(_net, 2),
    'partner_tab_open', round(_tab_open, 2),
    'departments', jsonb_build_array(
      jsonb_build_object('key', 'sales', 'income', round(_revenue, 2), 'cost', round(_cogs, 2),
                         'result', round(_revenue - _cogs, 2)),
      jsonb_build_object('key', 'warehouse', 'income', 0, 'cost', round(_waste + _stocktake, 2),
                         'result', round(-(_waste + _stocktake), 2)),
      jsonb_build_object('key', 'operations', 'income', round(_over, 2),
                         'cost', round(_expenses + _payroll + _shortage, 2), 'result', round(-_ops, 2))
    )
  );
END $$;
REVOKE ALL ON FUNCTION public._range_pnl(uuid, date, date) FROM PUBLIC, anon, authenticated;

-- Public P&L for the caller's company.
CREATE OR REPLACE FUNCTION public.range_pnl(_from date, _to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF public.current_profile_id() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('reports.profit') OR public.has_permission('partners.view_profit')
          OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  RETURN public._range_pnl(public.current_company_id(), _from, _to);
END $$;
REVOKE ALL ON FUNCTION public.range_pnl(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.range_pnl(date, date) TO authenticated;

-- ---------------------------------------------------------------------
-- Per-shift figures. Same formulas as range_pnl, scoped to the shift.
-- Drawer figures for closed shifts come from the stored handover so the
-- screen always matches what was attributed at closing.
-- ---------------------------------------------------------------------
-- Internal: every money figure of one shift. Callers check access first.
CREATE OR REPLACE FUNCTION public._shift_figures(_s public.shifts)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _end timestamptz := COALESCE(_s.closed_at, now());
  _gross numeric; _promo numeric; _manual numeric; _points numeric; _raw numeric; _ret numeric;
  _cogsum numeric; _retc numeric; _fr_raw numeric; _fr_cogs numeric;
  _refunds numeric; _refund_tax numeric; _staff_ref numeric; _cash_ref numeric;
  _waste numeric; _shrink numeric; _exp numeric; _net numeric; _expected numeric; _tenders jsonb; _counts jsonb;
BEGIN
  SELECT COALESCE(SUM((oi.base_price + COALESCE(oi.modifiers_total, 0)) * oi.quantity), 0),
         COALESCE(SUM(oi.unit_cost * oi.quantity), 0), COALESCE(SUM(public.line_cogs(oi)), 0)
    INTO _gross, _raw, _cogsum
    FROM public.orders o JOIN public.order_items oi ON oi.order_id = o.id
   WHERE o.shift_id = _s.id AND o.status IN ('completed', 'pending', 'refunded', 'partially_refunded')
     AND oi.status = 'active';

  SELECT COALESCE(SUM(o.promotional_discount), 0), COALESCE(SUM(o.discount_amount), 0)
    INTO _promo, _manual
    FROM public.orders o
   WHERE o.shift_id = _s.id AND o.status IN ('completed', 'pending', 'refunded', 'partially_refunded');

  SELECT COALESCE(jsonb_object_agg(k, v), '{}'::jsonb), COALESCE(jsonb_object_agg(k, c), '{}'::jsonb),
         COALESCE(SUM(v) FILTER (WHERE k = 'points'), 0)
    INTO _tenders, _counts, _points
    FROM (SELECT public.tender_key(op.method_key) k, round(SUM(op.amount), 2) v, COUNT(*) c
            FROM public.orders o JOIN public.order_payments op ON op.order_id = o.id
           WHERE o.shift_id = _s.id   -- every payment received, whatever happened to the order later
           GROUP BY 1) t;

  -- Drawer: every cash refund paid back. Revenue: only refunds of orders still counted as sales.
  SELECT COALESCE(SUM(r.amount) FILTER (WHERE o.status <> 'cancelled'), 0),
         COALESCE(SUM(r.tax_amount) FILTER (WHERE o.status <> 'cancelled'), 0),
         COALESCE(SUM(r.amount) FILTER (WHERE o.status <> 'cancelled' AND COALESCE(r.fault, r.origin) IN ('staff', 'all_staff')), 0),
         COALESCE(SUM(r.amount) FILTER (WHERE COALESCE(r.method_key, 'cash') = 'cash'), 0)
    INTO _refunds, _refund_tax, _staff_ref, _cash_ref
    FROM public.order_refunds r JOIN public.orders o ON o.id = r.order_id
   WHERE r.shift_id = _s.id AND r.status = 'active';

  SELECT COALESCE(SUM(CASE WHEN e->>'disposition' = 'restock'
                           THEN COALESCE((e->>'unit_cost')::numeric, 0) * COALESCE((e->>'quantity')::numeric, 0) END), 0),
         COALESCE(SUM(CASE WHEN e->>'disposition' = 'restock'
                           THEN COALESCE(public.order_item_unit_cogs(NULLIF(e->>'order_item_id', '')::uuid),
                                         COALESCE((e->>'unit_cost')::numeric, 0) * 1.05)
                                * COALESCE((e->>'quantity')::numeric, 0) END), 0)
    INTO _ret, _retc
    FROM public.order_refunds r JOIN public.orders o ON o.id = r.order_id
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(r.items_payload, '[]'::jsonb)) e
   WHERE r.shift_id = _s.id AND r.status = 'active' AND o.status <> 'cancelled';

  SELECT COALESCE(SUM(public.line_raw_cost(oi)), 0), COALESCE(SUM(public.line_cogs(oi)), 0)
    INTO _fr_raw, _fr_cogs
    FROM public.order_refunds r JOIN public.orders o ON o.id = r.order_id
    JOIN public.order_items oi ON oi.order_id = o.id AND oi.status = 'active'
   WHERE r.shift_id = _s.id AND r.status = 'active' AND r.kind = 'full' AND r.items_payload IS NULL
     AND COALESCE(r.origin, 'manual') = 'manual' AND o.status = 'refunded';
  _ret := _ret + _fr_raw;
  _retc := _retc + _fr_cogs;

  SELECT COALESCE(SUM(-sm.quantity * sm.unit_cost), 0) INTO _waste
    FROM public.stock_movements sm
   WHERE sm.branch_id = _s.branch_id AND sm.movement_type = 'waste' AND sm.quantity < 0
     AND sm.created_at >= _s.opened_at AND sm.created_at <= _end;

  SELECT COALESCE(SUM(st.shortage_cost), 0) INTO _shrink
    FROM public.stocktakes st
   WHERE st.branch_id = _s.branch_id AND st.shortage_cost > 0
     AND st.created_at >= _s.opened_at AND st.created_at <= _end;

  _exp := public.shift_expense_total(_s.id);
  _net := _gross - _promo - _manual - _points - (_refunds - _refund_tax);
  -- Closed shifts keep the expected cash fixed at handover; open shifts are live.
  _expected := CASE WHEN _s.status = 'closed' AND _s.expected_cash IS NOT NULL THEN _s.expected_cash
                    ELSE _s.opening_cash + COALESCE((_tenders->>'cash')::numeric, 0) - _cash_ref - _exp END;

  RETURN jsonb_build_object(
    'shiftId', _s.id, 'status', _s.status, 'openedAt', _s.opened_at, 'closedAt', _s.closed_at,
    'openingCash', _s.opening_cash, 'closingCash', _s.closing_cash,
    'retainedFloat', _s.retained_float, 'cashDrop', _s.cash_drop,
    'gross', round(_gross, 2), 'offers', round(_promo, 2), 'discounts', round(_manual, 2),
    'points', round(_points, 2),
    'refunds', round(_refunds - _refund_tax, 2), 'staffRefunds', round(_staff_ref, 2),
    'venueRefunds', round(_refunds - _staff_ref, 2),
    'netSales', round(_net, 2),
    'rawCogs', round(_raw - _ret, 2), 'cogs', round(_cogsum - _retc, 2),
    'waste', round(_waste, 2), 'shrinkage', round(_shrink, 2),
    'grossMargin', round(_net - (_cogsum - _retc) - _waste - _shrink, 2),
    'tenders', _tenders - 'points', 'tenderCounts', _counts - 'points',
    'cashRefunds', round(_cash_ref, 2),
    'shiftExpenses', round(_exp, 2),
    'expectedCash', round(_expected, 2),
    'variance', CASE WHEN _s.status = 'closed' THEN _s.variance END,
    'shortageResolution', _s.shortage_resolution);
END $$;
REVOKE ALL ON FUNCTION public._shift_figures(public.shifts) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._shift_figures(public.shifts) TO service_role;

-- Public: figures for the shifts the caller may see.
CREATE OR REPLACE FUNCTION public.shift_financials(_shift_ids uuid[])
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT COALESCE(jsonb_agg(public._shift_figures(s) ORDER BY s.opened_at), '[]'::jsonb)
    FROM public.shifts s
   WHERE s.id = ANY (_shift_ids) AND s.company_id = public.current_company_id()
     AND public.current_profile_id() IS NOT NULL
     AND public.can_access_branch(s.branch_id)
     AND (s.user_id = public.current_profile_id() OR public.has_permission('shifts.view')
          OR public.has_permission('reports.profit') OR public.is_super_admin())
$$;
REVOKE ALL ON FUNCTION public.shift_financials(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.shift_financials(uuid[]) TO authenticated;

-- ---------------------------------------------------------------------
-- Self-sustainability & runway, read straight from month-by-month P&L.
-- Rule: the last 3 complete months were all profitable.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.financial_self_sustainability()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _company uuid := public.current_company_id(); _today date; _first date; _m date; _end date;
  _p jsonb; _history jsonb := '[]'::jsonb; _consecutive int := 0; _streak_open boolean := true;
  _complete int := 0; _net_sum numeric := 0; _cost_sum numeric := 0; _cash numeric := 0;
  _avg_net numeric; _avg_cost numeric; _started date;
BEGIN
  IF public.current_profile_id() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('reports.profit') OR public.has_permission('partners.view_profit') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  _today := public.business_today(_company);
  _first := date_trunc('month', _today)::date;
  SELECT public.business_date(MIN(created_at), _company) INTO _started FROM public.orders WHERE company_id = _company;

  -- Current month to date, then the 6 previous complete months (newest first).
  FOR i IN 0..6 LOOP
    _m := (_first - make_interval(months => i))::date;
    _end := CASE WHEN i = 0 THEN _today ELSE (_m + interval '1 month - 1 day')::date END;
    EXIT WHEN _started IS NULL OR _end < _started;
    _p := public._range_pnl(_company, GREATEST(_m, _started), _end);
    _history := _history || jsonb_build_array(jsonb_build_object(
      'month', to_char(_m, 'YYYY-MM'), 'from', GREATEST(_m, _started), 'to', _end, 'complete', i > 0,
      'revenue', _p->'revenue', 'costs', round((_p->>'revenue')::numeric - (_p->>'net_profit')::numeric, 2),
      'net_profit', _p->'net_profit'));
    IF i > 0 THEN
      _complete := _complete + 1;
      _net_sum := _net_sum + (_p->>'net_profit')::numeric;
      _cost_sum := _cost_sum + (_p->>'operating_total')::numeric;
      IF _streak_open AND (_p->>'net_profit')::numeric > 0 THEN _consecutive := _consecutive + 1;
      ELSE _streak_open := false; END IF;
    END IF;
  END LOOP;

  SELECT COALESCE(SUM(public.cash_balance(a.id)), 0) INTO _cash
    FROM public.cash_accounts a WHERE a.company_id = _company AND a.is_active;

  _avg_net := CASE WHEN _complete > 0 THEN round(_net_sum / _complete, 2) END;
  _avg_cost := CASE WHEN _complete > 0 THEN round(_cost_sum / _complete, 2) END;

  RETURN jsonb_build_object(
    'reached', _consecutive >= 3,
    'required_consecutive_months', 3,
    'consecutive_profitable_months', _consecutive,
    'complete_months', _complete,
    'months_remaining', GREATEST(3 - _consecutive, 0),
    'average_net_profit', _avg_net,
    'average_operating_cost', _avg_cost,
    'treasury_balance', round(_cash, 2),
    -- Runway: how many months the treasury covers at the current average loss.
    'runway_months', CASE WHEN _avg_net IS NOT NULL AND _avg_net < 0 THEN round(_cash / -_avg_net, 1) END,
    'history', _history);
END $$;
REVOKE ALL ON FUNCTION public.financial_self_sustainability() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.financial_self_sustainability() TO authenticated;
