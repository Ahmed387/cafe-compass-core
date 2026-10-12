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

REVOKE ALL ON FUNCTION public.sales_period_summary(date, date, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.sales_period_summary(date, date, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.sales_period_summary(date, date, uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.expenses_period_summary(_from date, _to date)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  _cid uuid := public.current_company_id();
  _approved numeric := 0; _pending numeric := 0; _by_cat jsonb := '[]'::jsonb;
BEGIN
  IF NOT (public.has_permission('reports.expenses') OR public.has_permission('expenses.view') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT COALESCE(SUM(e.amount) FILTER (WHERE e.approved_at IS NOT NULL),0),
         COALESCE(SUM(e.amount) FILTER (WHERE e.approved_at IS NULL),0)
    INTO _approved, _pending
  FROM public.expenses e
  WHERE e.company_id = _cid AND e.status = 'active'
    AND e.expense_date BETWEEN _from AND _to;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('category', x.category, 'amount', x.amount) ORDER BY x.amount DESC), '[]'::jsonb)
    INTO _by_cat
  FROM (
    SELECT COALESCE(ec.name, '—') AS category, ROUND(SUM(e.amount),2) AS amount
    FROM public.expenses e
    LEFT JOIN public.expense_categories ec ON ec.id = e.category_id
    WHERE e.company_id = _cid AND e.status = 'active' AND e.approved_at IS NOT NULL
      AND e.expense_date BETWEEN _from AND _to
    GROUP BY 1
  ) x;

  RETURN jsonb_build_object(
    'approved_total', ROUND(_approved,2),
    'pending_total', ROUND(_pending,2),
    'by_category', _by_cat
  );
END
$$;

REVOKE ALL ON FUNCTION public.expenses_period_summary(date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.expenses_period_summary(date, date) FROM anon;
GRANT EXECUTE ON FUNCTION public.expenses_period_summary(date, date) TO authenticated, service_role;