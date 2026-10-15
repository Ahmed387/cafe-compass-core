-- =====================================================================
-- Fix: a removed invoice line was deducted from revenue twice.
--
-- void_order_item() drops the line from orders.total / active lines AND records
-- an automatic refund (origin = 'void') for the money handed back. Revenue was
-- built from active lines (or orders.total) and then subtracted every refund,
-- so the removed line came off twice (client report: shift #26).
--
-- Rule after this migration:
--   Revenue  = active lines − manual/cancel refunds of non-cancelled orders
--   Drawer   = all payments − all refunds (void refunds included: cash left the drawer)
-- Data is untouched; every report recalculates from the corrected functions.
-- =====================================================================

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
  -- Lines removed from an invoice already left the sale (active lines only), so their
  -- automatic 'void' refund only moves cash; it must never be deducted from revenue again.
  SELECT COALESCE(SUM(r.amount) FILTER (WHERE o.status <> 'cancelled' AND COALESCE(r.origin, 'manual') <> 'void'), 0),
         COALESCE(SUM(r.tax_amount) FILTER (WHERE o.status <> 'cancelled' AND COALESCE(r.origin, 'manual') <> 'void'), 0),
         COALESCE(SUM(r.amount) FILTER (WHERE o.status <> 'cancelled' AND COALESCE(r.origin, 'manual') <> 'void' AND COALESCE(r.fault, r.origin) IN ('staff', 'all_staff')), 0),
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
   WHERE r.company_id = _company AND r.status = 'active' AND o.status <> 'cancelled' AND COALESCE(r.origin, 'manual') <> 'void'
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


CREATE OR REPLACE FUNCTION public.period_pnl(_period_id uuid)
 RETURNS TABLE(gross_sales numeric, promo_discount numeric, manual_discounts numeric, points_redeemed numeric, refunds_total numeric, refund_tax_reversed numeric, partner_tab_unsettled numeric, revenue numeric, tax_collected numeric, cogs numeric, waste_cost numeric, expenses_total numeric, payroll_total numeric, gross_profit numeric, net_profit numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _p public.accounting_periods;
  _gross numeric := 0; _promo numeric := 0; _manual numeric := 0; _pts numeric := 0;
  _tax numeric := 0; _ref numeric := 0; _ref_tax numeric := 0; _tab numeric := 0;
  _cogs numeric := 0; _waste numeric := 0; _ref_waste numeric := 0;
  _exp numeric := 0; _pay numeric := 0; _net_rev numeric := 0; _gp numeric := 0;
BEGIN
  IF NOT (public.has_permission('reports.profit') OR public.has_permission('partners.view_profit') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  SELECT * INTO _p FROM public.accounting_periods WHERE id = _period_id AND company_id = public.current_company_id();
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Period not found'; END IF;

  CREATE TEMP TABLE IF NOT EXISTS _pnl_orders (order_id uuid PRIMARY KEY, on_tab boolean) ON COMMIT DROP;
  DELETE FROM _pnl_orders WHERE true;

  INSERT INTO _pnl_orders (order_id, on_tab)
  SELECT o.id,
         EXISTS (SELECT 1 FROM public.partner_tab_orders pt
                  WHERE pt.order_id = o.id AND NOT pt.is_settled)
  FROM public.orders o
  WHERE o.company_id = _p.company_id
    AND o.status IN ('pending','completed','refunded','partially_refunded')
    AND o.created_at::date BETWEEN _p.start_date AND _p.end_date;

  SELECT COALESCE(SUM((oi.base_price + COALESCE(oi.modifiers_total,0)) * oi.quantity),0)
    INTO _gross
  FROM public.order_items oi JOIN _pnl_orders po ON po.order_id = oi.order_id
  WHERE oi.status = 'active' AND NOT po.on_tab;

  SELECT COALESCE(SUM(o.promotional_discount),0), COALESCE(SUM(o.discount_amount),0),
         COALESCE(SUM(o.tax_amount),0)
    INTO _promo, _manual, _tax
  FROM public.orders o JOIN _pnl_orders po ON po.order_id = o.id
  WHERE NOT po.on_tab;

  SELECT COALESCE(SUM(o.total),0) INTO _tab
  FROM public.orders o JOIN _pnl_orders po ON po.order_id = o.id
  WHERE po.on_tab;

  SELECT COALESCE(SUM(op.amount),0) INTO _pts
  FROM public.order_payments op JOIN _pnl_orders po ON po.order_id = op.order_id
  WHERE op.method_key = 'points';

  SELECT COALESCE(SUM(oi.unit_cost * oi.quantity * 1.05),0) INTO _cogs
  FROM public.order_items oi JOIN _pnl_orders po ON po.order_id = oi.order_id
  WHERE oi.status = 'active';

  SELECT COALESCE(SUM(-sm.quantity * sm.unit_cost),0) INTO _waste
  FROM public.stock_movements sm
  WHERE sm.company_id = _p.company_id
    AND sm.movement_type = 'waste'
    AND sm.quantity < 0
    AND sm.created_at::date BETWEEN _p.start_date AND _p.end_date;

  SELECT COALESCE(SUM(COALESCE((entry->>'unit_cost')::numeric,0) * COALESCE((entry->>'quantity')::numeric,0)),0)
    INTO _ref_waste
  FROM public.order_refunds r
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(r.items_payload,'[]'::jsonb)) AS entry
  WHERE r.company_id = _p.company_id AND r.status = 'active'
    AND entry->>'disposition' = 'waste'
    AND r.created_at::date BETWEEN _p.start_date AND _p.end_date;

  _waste := _waste + _ref_waste + COALESCE((SELECT SUM(st.shortage_cost) FROM public.stocktakes st
    WHERE st.company_id = _p.company_id AND COALESCE(st.settlement,'venue') = 'venue'
      AND st.created_at::date BETWEEN _p.start_date AND _p.end_date),0)
    + COALESCE((SELECT SUM(-sh.variance) FROM public.shifts sh
      WHERE sh.company_id = _p.company_id AND sh.status = 'closed' AND sh.shortage_resolution = 'venue'
        AND sh.variance < 0 AND sh.closed_at::date BETWEEN _p.start_date AND _p.end_date),0);

  SELECT COALESCE(SUM(r.amount),0), COALESCE(SUM(r.tax_amount),0)
    INTO _ref, _ref_tax
  FROM public.order_refunds r JOIN public.orders o ON o.id = r.order_id
  WHERE r.company_id = _p.company_id AND r.status = 'active'
    AND o.status IN ('completed','refunded','partially_refunded','pending')
    AND COALESCE(r.origin, 'manual') <> 'void'
    AND r.created_at::date BETWEEN _p.start_date AND _p.end_date;

  SELECT COALESCE(SUM(e.amount),0) INTO _exp FROM public.expenses e
  WHERE e.company_id = _p.company_id AND e.status = 'active' AND e.approved_at IS NOT NULL
    AND e.expense_date BETWEEN _p.start_date AND _p.end_date;

  SELECT COALESCE(SUM(s.net_amount),0) INTO _pay FROM public.salary_payments s
  WHERE s.company_id = _p.company_id AND s.status = 'active'
    AND s.period_start <= _p.end_date AND s.period_end >= _p.start_date;

  _net_rev := _gross - _promo - _manual - _pts - _ref + _ref_tax - _tax;
  _gp := _net_rev - _cogs - _waste;

  RETURN QUERY SELECT
    round(_gross,2), round(_promo,2), round(_manual,2), round(_pts,2),
    round(_ref,2), round(_ref_tax,2), round(_tab,2),
    round(_net_rev,2), round(_tax - _ref_tax,2),
    round(_cogs,2), round(_waste,2),
    round(_exp,2), round(_pay,2),
    round(_gp,2), round(_gp - _exp - _pay, 2);
END
$function$;

REVOKE ALL ON FUNCTION public.period_pnl(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.period_pnl(uuid) TO authenticated, service_role;


CREATE OR REPLACE FUNCTION public.orders_period_summary(
  _branch_id uuid, _from date, _to date,
  _status text DEFAULT 'all', _order_type text DEFAULT 'all',
  _pay_method text DEFAULT 'all', _shift_id uuid DEFAULT NULL,
  _search text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
WITH s AS (SELECT NULLIF(btrim(regexp_replace(COALESCE(_search,''), '[%,()]', '', 'g')), '') AS q),
f AS (
  SELECT o.id, o.status::text AS status, o.total
  FROM orders o, s
  WHERE o.branch_id = _branch_id
    AND o.created_at >= _from::timestamptz AND o.created_at < (_to + 1)::timestamptz
    AND (_shift_id IS NULL OR o.shift_id = _shift_id)
    AND (_order_type = 'all' OR o.order_type::text = _order_type)
    AND (_status = 'all'
         OR (_status = 'refunded' AND o.status IN ('refunded','partially_refunded'))
         OR (_status <> 'refunded' AND o.status::text = _status))
    AND (_pay_method = 'all' OR EXISTS (SELECT 1 FROM order_payments p WHERE p.order_id = o.id AND p.method_key = _pay_method))
    AND (s.q IS NULL
      OR (s.q ~ '^\d{4}-\d{2}-\d{2}$' AND o.created_at::date = s.q::date)
      OR (s.q !~ '^\d{4}-\d{2}-\d{2}$' AND (
           o.order_number ILIKE '%'||s.q||'%' OR o.customer_name ILIKE '%'||s.q||'%' OR o.customer_phone ILIKE '%'||s.q||'%'
           OR EXISTS (SELECT 1 FROM order_items i WHERE i.order_id = o.id AND i.product_name ILIKE '%'||s.q||'%')
           OR EXISTS (SELECT 1 FROM user_profiles u WHERE u.id = o.created_by AND (u.display_name ILIKE '%'||s.q||'%' OR u.first_name ILIKE '%'||s.q||'%' OR u.last_name ILIKE '%'||s.q||'%')))))
),
r AS (SELECT f.id, COALESCE((SELECT SUM(amount) FROM order_refunds x WHERE x.order_id=f.id AND x.status='active' AND COALESCE(x.origin,'manual') <> 'void'),0) AS refunded FROM f),
t AS (
  SELECT CASE
    WHEN lower(p.method_key) ~ '(partner|tab|account)' THEN 'partner_tab'
    WHEN lower(p.method_key) ~ '(insta|bank)' THEN 'instapay'
    WHEN lower(p.method_key) ~ '(wallet|vodafone)' THEN 'wallet'
    WHEN lower(p.method_key) ~ '(card|visa)' THEN 'visa'
    ELSE 'cash' END AS k, SUM(p.amount) AS amt, COUNT(*) AS cnt
  FROM f JOIN order_payments p ON p.order_id = f.id
  WHERE f.status <> 'cancelled' GROUP BY 1
)
SELECT jsonb_build_object(
  'count', (SELECT COUNT(*) FROM f),
  'sales', (SELECT COALESCE(SUM(f.total - r.refunded),0) FROM f JOIN r USING (id) WHERE f.status <> 'cancelled'),
  'cancelled', (SELECT COUNT(*) FROM f WHERE status='cancelled'),
  'refunded', (SELECT COUNT(*) FROM f WHERE status IN ('refunded','partially_refunded')),
  'pending', (SELECT COUNT(*) FROM f WHERE status='pending'),
  'tenders', (SELECT COALESCE(jsonb_object_agg(k, amt),'{}'::jsonb) FROM t),
  'tenderCounts', (SELECT COALESCE(jsonb_object_agg(k, cnt),'{}'::jsonb) FROM t)
);
$$;


CREATE OR REPLACE FUNCTION public.sales_period_summary(_from date, _to date, _branch_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  _cid uuid := public.current_company_id();
  _rev numeric := 0; _disc numeric := 0; _cnt int := 0; _cancelled int := 0;
  _ref numeric := 0; _cogs numeric := 0;
  _by_day jsonb := '[]'::jsonb; _by_product jsonb := '[]'::jsonb;
  _by_method jsonb := '[]'::jsonb; _by_cashier jsonb := '[]'::jsonb;
BEGIN
  IF NOT (public.has_permission('reports.sales') OR public.has_permission('pos.view') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF _branch_id IS NOT NULL AND NOT public.can_access_branch(_branch_id) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT COALESCE(SUM(o.total),0), COALESCE(SUM(o.discount_amount),0), COUNT(*)
    INTO _rev, _disc, _cnt
  FROM public.orders o
  WHERE o.company_id = _cid
    AND (_branch_id IS NULL OR o.branch_id = _branch_id)
    AND o.status IN ('completed','refunded')
    AND o.created_at::date BETWEEN _from AND _to;

  SELECT COUNT(*) INTO _cancelled
  FROM public.orders o
  WHERE o.company_id = _cid
    AND (_branch_id IS NULL OR o.branch_id = _branch_id)
    AND o.status = 'cancelled'
    AND o.created_at::date BETWEEN _from AND _to;

  SELECT COALESCE(SUM(r.amount),0) INTO _ref
  FROM public.order_refunds r JOIN public.orders o ON o.id = r.order_id
  WHERE r.company_id = _cid
    AND (_branch_id IS NULL OR o.branch_id = _branch_id)
    AND r.status = 'active'
    AND o.status <> 'cancelled' AND COALESCE(r.origin, 'manual') <> 'void'
    AND r.created_at::date BETWEEN _from AND _to;

  SELECT COALESCE(SUM(oi.unit_cost * oi.quantity),0) INTO _cogs
  FROM public.order_items oi JOIN public.orders o ON o.id = oi.order_id
  WHERE o.company_id = _cid
    AND (_branch_id IS NULL OR o.branch_id = _branch_id)
    AND o.status = 'completed' AND oi.status = 'active'
    AND o.created_at::date BETWEEN _from AND _to;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('day', d.day, 'revenue', d.revenue, 'count', d.cnt) ORDER BY d.day), '[]'::jsonb)
    INTO _by_day
  FROM (
    SELECT o.created_at::date AS day, ROUND(SUM(o.total),2) AS revenue, COUNT(*) AS cnt
    FROM public.orders o
    WHERE o.company_id = _cid
      AND (_branch_id IS NULL OR o.branch_id = _branch_id)
      AND o.status IN ('completed','refunded')
      AND o.created_at::date BETWEEN _from AND _to
    GROUP BY 1
  ) d;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('name', p.name, 'qty', p.qty, 'revenue', p.revenue) ORDER BY p.revenue DESC), '[]'::jsonb)
    INTO _by_product
  FROM (
    SELECT oi.product_name AS name, SUM(oi.quantity) AS qty, ROUND(SUM(oi.line_total),2) AS revenue
    FROM public.order_items oi JOIN public.orders o ON o.id = oi.order_id
    WHERE o.company_id = _cid
      AND (_branch_id IS NULL OR o.branch_id = _branch_id)
      AND o.status IN ('completed','refunded') AND oi.status = 'active'
      AND o.created_at::date BETWEEN _from AND _to
    GROUP BY 1
    ORDER BY 3 DESC
    LIMIT 200
  ) p;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('method', m.method_key, 'amount', m.amount) ORDER BY m.amount DESC), '[]'::jsonb)
    INTO _by_method
  FROM (
    SELECT op.method_key, ROUND(SUM(op.amount),2) AS amount
    FROM public.order_payments op JOIN public.orders o ON o.id = op.order_id
    WHERE o.company_id = _cid
      AND (_branch_id IS NULL OR o.branch_id = _branch_id)
      AND o.status IN ('completed','refunded')
      AND o.created_at::date BETWEEN _from AND _to
    GROUP BY 1
  ) m;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('name', c.name, 'revenue', c.revenue, 'count', c.cnt) ORDER BY c.revenue DESC), '[]'::jsonb)
    INTO _by_cashier
  FROM (
    SELECT COALESCE(NULLIF(up.display_name,''), up.first_name, '—') AS name,
           ROUND(SUM(o.total),2) AS revenue, COUNT(*) AS cnt
    FROM public.orders o
    LEFT JOIN public.user_profiles up ON up.id = o.created_by
    WHERE o.company_id = _cid
      AND (_branch_id IS NULL OR o.branch_id = _branch_id)
      AND o.status IN ('completed','refunded')
      AND o.created_at::date BETWEEN _from AND _to
    GROUP BY 1
  ) c;

  RETURN jsonb_build_object(
    'revenue', ROUND(_rev,2),
    'refunds', ROUND(_ref,2),
    'discounts', ROUND(_disc,2),
    'cogs', ROUND(_cogs,2),
    'count', _cnt,
    'cancelled', _cancelled,
    'avg', CASE WHEN _cnt > 0 THEN ROUND(_rev / _cnt, 2) ELSE 0 END,
    'by_day', _by_day,
    'by_product', _by_product,
    'by_method', _by_method,
    'by_cashier', _by_cashier
  );
END
$$;

