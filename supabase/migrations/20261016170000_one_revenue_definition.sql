-- =====================================================================
-- Money ledger, step 1b (ADR 0002): sales have ONE definition.
--
--   revenue of an invoice = its total − tax − the part paid with cashback
--                           − its refunds (not line removals; those already
--                             left the total). Cancelled invoices = 0.
--   revenue of a period   = _range_pnl (the profit report), which equals the
--                           sum of order_revenue over the period's invoices.
--
-- Screens that computed sales their own way now ask these two:
--   * sales report (sales_period_summary): "revenue" was the sum of invoice
--     totals before refunds and cashback, so it was higher than the profit
--     report and its gross profit ignored refunds. Headline figures now come
--     from _range_pnl; each day's bar is that day's _range_pnl; per-cashier
--     revenue is order_revenue.
--   * orders page (orders_period_summary): "sales" now uses order_revenue
--     (cashback paid part was still counted); the page's "today" cards were
--     failing because two versions had the same parameter names (see below).
--   * treasury operating costs (monthly_operating_costs): sales, cost, waste,
--     payroll and expenses now come from _range_pnl (it had its own copies,
--     left out pending/refunded invoices and used the gross salary).
-- All three also counted days in UTC instead of the cafe's business day.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.order_revenue(_o public.orders)
RETURNS numeric LANGUAGE sql STABLE SET search_path TO 'public' AS $$
  SELECT CASE WHEN _o.status::text NOT IN ('completed', 'pending', 'refunded', 'partially_refunded') THEN 0
    ELSE round(_o.total - COALESCE(_o.tax_amount, 0)
      - COALESCE((SELECT SUM(op.amount) FROM public.order_payments op
                   WHERE op.order_id = _o.id AND public.tender_key(op.method_key) = 'points'), 0)
      - COALESCE((SELECT SUM(r.amount - COALESCE(r.tax_amount, 0)) FROM public.order_refunds r
                   WHERE r.order_id = _o.id AND r.status = 'active' AND COALESCE(r.origin, 'manual') <> 'void'), 0), 2)
  END
$$;
REVOKE EXECUTE ON FUNCTION public.order_revenue(public.orders) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.order_revenue(public.orders) TO authenticated, service_role;

-- ---------------------------------------------------------------------
-- Sales report
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sales_period_summary(_from date, _to date, _branch_id uuid DEFAULT NULL::uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  _cid uuid := public.current_company_id();
  _t0 timestamptz; _t1 timestamptz; _p jsonb; _rev numeric; _cnt int := 0; _cancelled int := 0;
  _by_day jsonb := '[]'::jsonb; _by_product jsonb := '[]'::jsonb;
  _by_method jsonb := '[]'::jsonb; _by_cashier jsonb := '[]'::jsonb;
BEGIN
  IF NOT (public.has_permission('reports.sales') OR public.has_permission('pos.view') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF _branch_id IS NOT NULL AND NOT public.can_access_branch(_branch_id) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF _from IS NULL OR _to IS NULL OR _to < _from THEN RAISE EXCEPTION 'Choose a valid date range'; END IF;

  _t0 := public.business_day_start(_from, _cid);
  _t1 := public.business_day_start(_to + 1, _cid);
  -- Headline figures: the profit report itself (company-wide; one branch today).
  _p := public._range_pnl(_cid, _from, _to);
  _rev := (_p->>'revenue')::numeric;

  SELECT COUNT(*) FILTER (WHERE o.status IN ('pending','completed','refunded','partially_refunded')),
         COUNT(*) FILTER (WHERE o.status = 'cancelled')
    INTO _cnt, _cancelled
    FROM public.orders o
   WHERE o.company_id = _cid AND (_branch_id IS NULL OR o.branch_id = _branch_id)
     AND o.created_at >= _t0 AND o.created_at < _t1;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('day', d.day, 'revenue', (d.p->>'revenue')::numeric,
           'count', (d.p->>'orders_count')::int) ORDER BY d.day), '[]'::jsonb)
    INTO _by_day
    FROM (SELECT g::date AS day, public._range_pnl(_cid, g::date, g::date) AS p
            FROM generate_series(_from, _to, interval '1 day') g) d
   WHERE (d.p->>'orders_count')::int > 0 OR (d.p->>'revenue')::numeric <> 0;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('name', p.name, 'qty', p.qty, 'revenue', p.revenue) ORDER BY p.revenue DESC), '[]'::jsonb)
    INTO _by_product
  FROM (
    SELECT oi.product_name AS name, SUM(oi.quantity) AS qty, ROUND(SUM(oi.line_total),2) AS revenue
    FROM public.order_items oi JOIN public.orders o ON o.id = oi.order_id
    WHERE o.company_id = _cid AND (_branch_id IS NULL OR o.branch_id = _branch_id)
      AND o.status IN ('pending','completed','refunded','partially_refunded') AND oi.status = 'active'
      AND o.created_at >= _t0 AND o.created_at < _t1
    GROUP BY 1 ORDER BY 3 DESC LIMIT 200
  ) p;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('method', m.method_key, 'amount', m.amount) ORDER BY m.amount DESC), '[]'::jsonb)
    INTO _by_method
  FROM (
    SELECT op.method_key, ROUND(SUM(op.amount),2) AS amount
    FROM public.order_payments op JOIN public.orders o ON o.id = op.order_id
    WHERE o.company_id = _cid AND (_branch_id IS NULL OR o.branch_id = _branch_id)
      AND o.status IN ('pending','completed','refunded','partially_refunded')
      AND o.created_at >= _t0 AND o.created_at < _t1
    GROUP BY 1
  ) m;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('name', c.name, 'revenue', c.revenue, 'count', c.cnt) ORDER BY c.revenue DESC), '[]'::jsonb)
    INTO _by_cashier
  FROM (
    SELECT COALESCE(NULLIF(up.display_name,''), up.first_name, '—') AS name,
           ROUND(SUM(public.order_revenue(o)),2) AS revenue, COUNT(*) AS cnt
    FROM public.orders o LEFT JOIN public.user_profiles up ON up.id = o.created_by
    WHERE o.company_id = _cid AND (_branch_id IS NULL OR o.branch_id = _branch_id)
      AND o.status IN ('pending','completed','refunded','partially_refunded')
      AND o.created_at >= _t0 AND o.created_at < _t1
    GROUP BY 1
  ) c;

  RETURN jsonb_build_object(
    'revenue', ROUND(_rev, 2),
    'refunds', (_p->>'refunds_total')::numeric,
    'discounts', (_p->>'manual_discounts')::numeric,
    'cogs', (_p->>'cogs')::numeric,
    'gross_profit', ROUND(_rev - (_p->>'cogs')::numeric, 2),
    'count', _cnt,
    'cancelled', _cancelled,
    'avg', CASE WHEN _cnt > 0 THEN ROUND(_rev / _cnt, 2) ELSE 0 END,
    'by_day', _by_day, 'by_product', _by_product, 'by_method', _by_method, 'by_cashier', _by_cashier);
END
$function$;

-- ---------------------------------------------------------------------
-- Orders page (both versions)
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.orders_period_summary(_branch_id uuid, _from date, _to date, _status text DEFAULT 'all'::text, _order_type text DEFAULT 'all'::text, _pay_method text DEFAULT 'all'::text, _shift_id uuid DEFAULT NULL::uuid, _search text DEFAULT NULL::text)
RETURNS jsonb LANGUAGE sql STABLE SET search_path TO 'public' AS $function$
WITH s AS (SELECT NULLIF(btrim(regexp_replace(COALESCE(_search,''), '[%,()]', '', 'g')), '') AS q),
f AS (
  SELECT o.id, o.status::text AS status, public.order_revenue(o) AS revenue,
         (public.business_date(o.created_at, o.company_id) = public.business_today(o.company_id)) AS is_today
  FROM orders o, s
  WHERE o.branch_id = _branch_id
    AND o.created_at >= public.business_day_start(_from, o.company_id)
    AND o.created_at < public.business_day_start(_to + 1, o.company_id)
    AND (_shift_id IS NULL OR o.shift_id = _shift_id)
    AND (_order_type = 'all' OR o.order_type::text = _order_type)
    AND (_status = 'all'
         OR (_status = 'refunded' AND o.status IN ('refunded','partially_refunded'))
         OR (_status <> 'refunded' AND o.status::text = _status))
    AND (_pay_method = 'all' OR EXISTS (SELECT 1 FROM order_payments p WHERE p.order_id = o.id AND p.method_key = _pay_method))
    AND (s.q IS NULL
      OR (s.q ~ '^\d{4}-\d{2}-\d{2}$' AND public.business_date(o.created_at, o.company_id) = s.q::date)
      OR (s.q !~ '^\d{4}-\d{2}-\d{2}$' AND (
           o.order_number ILIKE '%'||s.q||'%' OR o.customer_name ILIKE '%'||s.q||'%' OR o.customer_phone ILIKE '%'||s.q||'%'
           OR EXISTS (SELECT 1 FROM order_items i WHERE i.order_id = o.id AND i.product_name ILIKE '%'||s.q||'%')
           OR EXISTS (SELECT 1 FROM user_profiles u WHERE u.id = o.created_by AND (u.display_name ILIKE '%'||s.q||'%' OR u.first_name ILIKE '%'||s.q||'%' OR u.last_name ILIKE '%'||s.q||'%')))))
),
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
  'sales', (SELECT COALESCE(SUM(f.revenue),0) FROM f),
  'cancelled', (SELECT COUNT(*) FROM f WHERE status='cancelled'),
  'refunded', (SELECT COUNT(*) FROM f WHERE status IN ('refunded','partially_refunded')),
  'pending', (SELECT COUNT(*) FROM f WHERE status='pending'),
  'today_count', (SELECT COUNT(*) FROM f WHERE is_today AND status <> 'cancelled'),
  'today_sales', (SELECT COALESCE(SUM(revenue),0) FROM f WHERE is_today),
  'tenders', (SELECT COALESCE(jsonb_object_agg(k, amt),'{}'::jsonb) FROM t),
  'tenderCounts', (SELECT COALESCE(jsonb_object_agg(k, cnt),'{}'::jsonb) FROM t)
);
$function$;

-- The old 4-argument version has the same parameter names as the 8-argument one,
-- so the API cannot tell them apart when called with (_from, _to, _branch_id):
-- the orders page "today" cards failed. The page now calls the 8-argument
-- version explicitly. The 4-argument one is kept (nothing is dropped) and uses
-- the same revenue definition.
CREATE OR REPLACE FUNCTION public.orders_period_summary(_from date, _to date, _branch_id uuid DEFAULT NULL::uuid, _status text DEFAULT NULL::text)
RETURNS jsonb LANGUAGE sql STABLE SET search_path TO 'public' AS $function$
  SELECT public.orders_period_summary(_branch_id, _from, _to, COALESCE(_status, 'all'), 'all', 'all', NULL::uuid, NULL::text)
$function$;

-- ---------------------------------------------------------------------
-- Treasury operating costs
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.monthly_operating_costs(_from date, _to date)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE _company uuid := public.current_company_id(); _p jsonb; _t0 timestamptz; _t1 timestamptz;
  _purchases numeric := 0; _purch_paid numeric := 0; _advances numeric := 0; _items jsonb; _cats jsonb;
  _cogs numeric; _waste numeric; _payroll numeric; _expenses numeric;
BEGIN
  IF NOT (public.has_permission('reports.profit') OR public.has_permission('treasury.view')
          OR public.has_permission('partners.view_profit') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  _p := public._range_pnl(_company, _from, _to);
  _t0 := public.business_day_start(_from, _company);
  _t1 := public.business_day_start(_to + 1, _company);
  _cogs := (_p->>'cogs')::numeric;
  _waste := (_p->>'waste_cost')::numeric + (_p->>'stocktake_shortage')::numeric;
  _payroll := (_p->>'payroll_total')::numeric;
  _expenses := (_p->>'expenses_total')::numeric;

  SELECT COALESCE(SUM(p.total - p.returned_amount),0), COALESCE(SUM(p.paid_amount),0)
    INTO _purchases, _purch_paid
  FROM public.purchases p WHERE p.company_id = _company AND p.status <> 'cancelled'
    AND p.purchase_date BETWEEN _from AND _to;

  SELECT COALESCE(SUM(a.amount),0) INTO _advances FROM public.employee_advances a
  WHERE a.company_id = _company AND a.status = 'active' AND a.advance_date BETWEEN _from AND _to;

  SELECT COALESCE(jsonb_agg(x ORDER BY x->>'cost' DESC), '[]'::jsonb) INTO _items FROM (
    SELECT jsonb_build_object('item', i.name, 'item_ar', i.name_ar, 'unit', i.unit,
      'qty', round(SUM(-sm.quantity),3), 'cost', round(SUM(-sm.quantity * sm.unit_cost),2)) AS x
    FROM public.stock_movements sm JOIN public.inventory_items i ON i.id = sm.item_id
    WHERE sm.company_id = _company AND sm.quantity < 0
      AND sm.movement_type IN ('sale_consumption','waste','adjustment','stocktake')
      AND sm.created_at >= _t0 AND sm.created_at < _t1
    GROUP BY i.name, i.name_ar, i.unit
  ) s;

  SELECT COALESCE(jsonb_agg(x ORDER BY x->>'amount' DESC), '[]'::jsonb) INTO _cats FROM (
    SELECT jsonb_build_object('category', COALESCE(c.name,'Other'), 'category_ar', c.name_ar,
      'amount', round(SUM(e.amount),2)) AS x
    FROM public.expenses e LEFT JOIN public.expense_categories c ON c.id = e.category_id
    WHERE e.company_id = _company AND e.status = 'active' AND e.approved_at IS NOT NULL
      AND e.expense_date BETWEEN _from AND _to
    GROUP BY c.name, c.name_ar
  ) s;

  RETURN jsonb_build_object(
    'from', _from, 'to', _to,
    'sales', (_p->>'revenue')::numeric, 'tax', (_p->>'tax_collected')::numeric,
    'cogs', _cogs, 'waste', round(_waste, 2),
    'purchases_total', round(_purchases,2), 'purchases_paid', round(_purch_paid,2),
    'purchases_due', round(_purchases - _purch_paid,2),
    'payroll', _payroll, 'advances', round(_advances,2),
    'expenses', _expenses, 'expenses_pending', (_p->>'expenses_pending')::numeric,
    'operating_total', round(_cogs + _waste + _payroll + _expenses, 2),
    'net_profit', (_p->>'net_profit')::numeric,
    'consumption', COALESCE(_items,'[]'::jsonb),
    'expense_breakdown', COALESCE(_cats,'[]'::jsonb));
END
$function$;
