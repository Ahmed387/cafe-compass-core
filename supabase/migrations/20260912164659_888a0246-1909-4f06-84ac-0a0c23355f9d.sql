-- ============ Phase 6: performance indexes ============
CREATE INDEX IF NOT EXISTS idx_orders_company_created_at
  ON public.orders (company_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_orders_company_status_created_at
  ON public.orders (company_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_orders_branch_created_at
  ON public.orders (branch_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_cash_txn_company_account_created_at
  ON public.cash_transactions (company_id, account_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_cash_txn_company_date
  ON public.cash_transactions (company_id, txn_date DESC);
CREATE INDEX IF NOT EXISTS idx_stock_moves_company_item_created_at
  ON public.stock_movements (company_id, item_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_expenses_company_status_date
  ON public.expenses (company_id, status, expense_date DESC);
CREATE INDEX IF NOT EXISTS idx_purchases_company_date
  ON public.purchases (company_id, purchase_date DESC);
CREATE INDEX IF NOT EXISTS idx_purchases_branch_date
  ON public.purchases (branch_id, purchase_date DESC);
CREATE INDEX IF NOT EXISTS idx_order_items_order
  ON public.order_items (order_id);
CREATE INDEX IF NOT EXISTS idx_order_refunds_order
  ON public.order_refunds (order_id);
CREATE INDEX IF NOT EXISTS idx_order_payments_order
  ON public.order_payments (order_id);

-- ============ Phase 6: range-accurate aggregates ============

CREATE OR REPLACE FUNCTION public.orders_period_summary(
  _from date,
  _to date,
  _branch_id uuid DEFAULT NULL,
  _status text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE _company uuid := public.current_company_id();
  _result jsonb;
BEGIN
  IF NOT (public.has_permission('pos.view') OR public.has_permission('reports.sales')
          OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF _branch_id IS NOT NULL AND NOT public.can_access_branch(_branch_id) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT jsonb_build_object(
    'count', COUNT(*),
    'sales', round(COALESCE(SUM(o.total) FILTER (WHERE o.status IN ('completed','refunded')),0),2),
    'cancelled', COUNT(*) FILTER (WHERE o.status = 'cancelled'),
    'refunded', COUNT(*) FILTER (WHERE o.status = 'refunded'),
    'today_count', COUNT(*) FILTER (WHERE o.created_at::date = CURRENT_DATE AND o.status <> 'cancelled'),
    'today_sales', round(COALESCE(SUM(o.total) FILTER (
        WHERE o.created_at::date = CURRENT_DATE AND o.status IN ('completed','refunded')),0),2)
  )
  INTO _result
  FROM public.orders o
  WHERE o.company_id = _company
    AND (_branch_id IS NULL OR o.branch_id = _branch_id)
    AND o.created_at >= _from::timestamptz
    AND o.created_at < (_to + 1)::timestamptz
    AND (_status IS NULL OR o.status::text = _status);

  RETURN COALESCE(_result, '{}'::jsonb);
END
$function$;

CREATE OR REPLACE FUNCTION public.cash_movements_summary(
  _from date,
  _to date,
  _account_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE _company uuid := public.current_company_id();
  _result jsonb;
BEGIN
  IF NOT (public.has_permission('treasury.view') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT jsonb_build_object(
    'count', COUNT(*),
    'total_in', round(COALESCE(SUM(c.amount) FILTER (WHERE c.direction = 'in'),0),2),
    'total_out', round(COALESCE(SUM(c.amount) FILTER (WHERE c.direction = 'out'),0),2),
    'net', round(COALESCE(SUM(CASE WHEN c.direction = 'in' THEN c.amount ELSE -c.amount END),0),2)
  )
  INTO _result
  FROM public.cash_transactions c
  WHERE c.company_id = _company
    AND c.status = 'active'
    AND c.txn_date BETWEEN _from AND _to
    AND (_account_id IS NULL OR c.account_id = _account_id);

  RETURN COALESCE(_result, '{}'::jsonb);
END
$function$;

CREATE OR REPLACE FUNCTION public.purchases_period_summary(
  _from date,
  _to date,
  _branch_id uuid DEFAULT NULL,
  _status text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE _company uuid := public.current_company_id();
  _result jsonb;
BEGIN
  IF NOT (public.has_permission('purchases.view') OR public.has_permission('inventory.view')
          OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF _branch_id IS NOT NULL AND NOT public.can_access_branch(_branch_id) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT jsonb_build_object(
    'count', COUNT(*),
    'total', round(COALESCE(SUM(p.total) FILTER (WHERE p.status <> 'cancelled'),0),2),
    'paid', round(COALESCE(SUM(p.paid_amount) FILTER (WHERE p.status <> 'cancelled'),0),2),
    'returned', round(COALESCE(SUM(p.returned_amount) FILTER (WHERE p.status <> 'cancelled'),0),2),
    'due', round(COALESCE(SUM(p.total - p.returned_amount - p.paid_amount)
                   FILTER (WHERE p.status <> 'cancelled'),0),2)
  )
  INTO _result
  FROM public.purchases p
  WHERE p.company_id = _company
    AND (_branch_id IS NULL OR p.branch_id = _branch_id)
    AND p.purchase_date BETWEEN _from AND _to
    AND (_status IS NULL OR p.status::text = _status);

  RETURN COALESCE(_result, '{}'::jsonb);
END
$function$;

CREATE OR REPLACE FUNCTION public.sales_period_summary(
  _from date,
  _to date,
  _branch_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE _company uuid := public.current_company_id();
  _from_ts timestamptz := _from::timestamptz;
  _to_ts timestamptz := (_to + 1)::timestamptz;
  _revenue numeric := 0; _refunds numeric := 0; _discounts numeric := 0; _cogs numeric := 0;
  _count int := 0; _total_rows int := 0; _billable int := 0;
  _by_day jsonb; _by_product jsonb; _by_method jsonb; _by_cashier jsonb;
BEGIN
  IF NOT (public.has_permission('reports.sales') OR public.has_permission('pos.view')
          OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF _branch_id IS NOT NULL AND NOT public.can_access_branch(_branch_id) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS _sps_orders (
    id uuid, created_at timestamptz, status text, total numeric, tax_amount numeric,
    discount_amount numeric, created_by uuid, net_total numeric, refund_net numeric
  ) ON COMMIT DROP;
  DELETE FROM _sps_orders;

  INSERT INTO _sps_orders
  SELECT o.id, o.created_at, o.status::text, o.total, o.tax_amount, o.discount_amount, o.created_by,
         o.total - o.tax_amount - COALESCE(r.manual_net, 0),
         COALESCE(r.all_net, 0)
  FROM public.orders o
  LEFT JOIN (
    SELECT x.order_id,
      COALESCE(SUM(x.amount - x.tax_amount) FILTER (WHERE x.origin <> 'void'),0) AS manual_net,
      COALESCE(SUM(x.amount - x.tax_amount),0) AS all_net
    FROM public.order_refunds x
    WHERE x.company_id = _company AND x.status = 'active'
    GROUP BY x.order_id
  ) r ON r.order_id = o.id
  WHERE o.company_id = _company
    AND (_branch_id IS NULL OR o.branch_id = _branch_id)
    AND o.created_at >= _from_ts AND o.created_at < _to_ts
    AND o.status <> 'cancelled';

  SELECT COUNT(*), COALESCE(SUM(net_total),0), COALESCE(SUM(refund_net),0),
         COALESCE(SUM(discount_amount),0), COUNT(*) FILTER (WHERE total > 0)
    INTO _count, _revenue, _refunds, _discounts, _billable
  FROM _sps_orders;

  SELECT COUNT(*) INTO _total_rows
  FROM public.orders o
  WHERE o.company_id = _company
    AND (_branch_id IS NULL OR o.branch_id = _branch_id)
    AND o.created_at >= _from_ts AND o.created_at < _to_ts;

  SELECT COALESCE(SUM(oi.unit_cost * oi.quantity),0) INTO _cogs
  FROM public.order_items oi
  JOIN _sps_orders s ON s.id = oi.order_id
  WHERE oi.status = 'active' AND s.status <> 'refunded';

  SELECT COALESCE(jsonb_agg(jsonb_build_object('day', day, 'revenue', revenue, 'count', cnt)
                            ORDER BY day DESC), '[]'::jsonb)
    INTO _by_day
  FROM (
    SELECT created_at::date AS day, round(SUM(net_total),2) AS revenue, COUNT(*) AS cnt
    FROM _sps_orders GROUP BY created_at::date
  ) d;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('name', name, 'qty', qty, 'revenue', revenue)
                            ORDER BY revenue DESC), '[]'::jsonb)
    INTO _by_product
  FROM (
    SELECT CASE WHEN oi.size_name IS NULL OR oi.size_name = '' THEN oi.product_name
                ELSE oi.product_name || ' (' || oi.size_name || ')' END AS name,
           SUM(oi.quantity) AS qty, round(SUM(oi.line_total),2) AS revenue
    FROM public.order_items oi
    JOIN _sps_orders s ON s.id = oi.order_id
    WHERE oi.status = 'active'
    GROUP BY 1
    ORDER BY revenue DESC
    LIMIT 20
  ) p;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('method', method, 'amount', amount)
                            ORDER BY amount DESC), '[]'::jsonb)
    INTO _by_method
  FROM (
    SELECT method, round(SUM(amount),2) AS amount FROM (
      SELECT COALESCE(NULLIF(op.method_key,''),'cash') AS method, op.amount
      FROM public.order_payments op JOIN _sps_orders s ON s.id = op.order_id
      UNION ALL
      SELECT COALESCE(NULLIF(orf.method_key,''),'cash') AS method, -orf.amount
      FROM public.order_refunds orf JOIN _sps_orders s ON s.id = orf.order_id
      WHERE orf.status = 'active'
    ) m GROUP BY method
  ) mm;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('name', name, 'revenue', revenue, 'count', cnt)
                            ORDER BY revenue DESC), '[]'::jsonb)
    INTO _by_cashier
  FROM (
    SELECT COALESCE(NULLIF(up.display_name,''), up.first_name, '—') AS name,
           round(SUM(s.net_total),2) AS revenue, COUNT(*) AS cnt
    FROM _sps_orders s
    LEFT JOIN public.user_profiles up ON up.id = s.created_by
    GROUP BY 1
  ) c;

  RETURN jsonb_build_object(
    'from', _from, 'to', _to,
    'revenue', round(_revenue,2),
    'refunds', round(_refunds,2),
    'discounts', round(_discounts,2),
    'cogs', round(_cogs,2),
    'count', _count,
    'cancelled', _total_rows - _count,
    'avg', CASE WHEN _billable > 0 THEN round(_revenue / _billable,2) ELSE 0 END,
    'by_day', _by_day,
    'by_product', _by_product,
    'by_method', _by_method,
    'by_cashier', _by_cashier
  );
END
$function$;

CREATE OR REPLACE FUNCTION public.expenses_period_summary(_from date, _to date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE _company uuid := public.current_company_id();
  _approved numeric := 0; _pending numeric := 0; _cats jsonb;
BEGIN
  IF NOT (public.has_permission('reports.expenses') OR public.has_permission('expenses.view')
          OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT COALESCE(SUM(e.amount) FILTER (WHERE e.approved_at IS NOT NULL),0),
         COALESCE(SUM(e.amount) FILTER (WHERE e.approved_at IS NULL),0)
    INTO _approved, _pending
  FROM public.expenses e
  WHERE e.company_id = _company AND e.status = 'active'
    AND e.expense_date BETWEEN _from AND _to;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('category', category, 'amount', amount)
                            ORDER BY amount DESC), '[]'::jsonb)
    INTO _cats
  FROM (
    SELECT COALESCE(c.name,'—') AS category, round(SUM(e.amount),2) AS amount
    FROM public.expenses e
    LEFT JOIN public.expense_categories c ON c.id = e.category_id
    WHERE e.company_id = _company AND e.status = 'active' AND e.approved_at IS NOT NULL
      AND e.expense_date BETWEEN _from AND _to
    GROUP BY 1
  ) s;

  RETURN jsonb_build_object(
    'approved_total', round(_approved,2),
    'pending_total', round(_pending,2),
    'by_category', _cats
  );
END
$function$;

-- Internal staff functions only: no anonymous access.
REVOKE ALL ON FUNCTION public.orders_period_summary(date, date, uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cash_movements_summary(date, date, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.purchases_period_summary(date, date, uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.sales_period_summary(date, date, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.expenses_period_summary(date, date) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.orders_period_summary(date, date, uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cash_movements_summary(date, date, uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.purchases_period_summary(date, date, uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.sales_period_summary(date, date, uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.expenses_period_summary(date, date) TO authenticated, service_role;
