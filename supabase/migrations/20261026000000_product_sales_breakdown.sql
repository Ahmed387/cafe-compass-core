-- Product sales by size and by the price each one was sold at (Ahmed, 2026-10-26).
-- Only clean sales: completed invoices with no refund and no cancellation at all
-- (any active order_refunds row, whatever its origin, leaves the whole invoice
-- out), and only lines still active. Price = what the line was sold at per
-- piece (line_total / quantity, add-ons and offers included). Invoice-level
-- discounts are not split over lines; their total is returned apart.
-- Cost and profit only for the super admin or reports.profit. Read only.
-- Lines are grouped under the product's current menu name, so a renamed
-- product (e.g. "ليمون نعناع / Lemon Mint" -> "Lemon Mint") is one row.
CREATE OR REPLACE FUNCTION public.product_sales_breakdown(_from date, _to date, _branch_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  _cid uuid := public.current_company_id();
  _costs boolean := public.is_super_admin() OR public.has_permission('reports.profit');
  _rows jsonb; _excluded jsonb; _discounts numeric;
BEGIN
  IF NOT (public.has_permission('reports.sales') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF _branch_id IS NOT NULL AND NOT public.can_access_branch(_branch_id) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF _from IS NULL OR _to IS NULL OR _to < _from THEN RAISE EXCEPTION 'Choose a valid date range'; END IF;

  WITH clean AS (
    SELECT o.id, o.discount_amount FROM public.orders o
     WHERE o.company_id = _cid AND (_branch_id IS NULL OR o.branch_id = _branch_id)
       AND o.business_date BETWEEN _from AND _to
       AND o.status = 'completed'
       AND NOT EXISTS (SELECT 1 FROM public.order_refunds r WHERE r.order_id = o.id AND r.status = 'active')
  ), lines AS (
    -- One name per product: the menu's current name (by id, or by the old
    -- "عربي / English" name); typed-in items by their name, case ignored.
    SELECT COALESCE(p.name, pm.name, min(btrim(oi.product_name)) OVER (PARTITION BY lower(btrim(oi.product_name)))) AS product,
           COALESCE(NULLIF(btrim(oi.size_name), ''), '') AS size,
           round(oi.line_total / NULLIF(oi.quantity, 0), 2) AS price,
           oi.quantity AS qty, oi.line_total AS revenue, oi.unit_cost * oi.quantity AS cost
      FROM public.order_items oi JOIN clean c ON c.id = oi.order_id
      LEFT JOIN public.products p ON p.id = oi.product_id
      LEFT JOIN LATERAL (
        SELECT m.name FROM public.products m
         WHERE oi.product_id IS NULL AND m.company_id = _cid
           AND lower(m.name) IN (lower(btrim(oi.product_name)), lower(btrim(split_part(oi.product_name, ' / ', 2))))
         ORDER BY m.is_active DESC NULLS LAST, m.created_at LIMIT 1) pm ON true
     WHERE oi.status = 'active' AND oi.quantity > 0
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'product', g.product, 'size', g.size, 'price', g.price, 'qty', g.qty,
           'revenue', round(g.revenue, 2),
           'cost', CASE WHEN _costs THEN round(g.cost, 2) END,
           'profit', CASE WHEN _costs THEN round(g.revenue - g.cost, 2) END)
         ORDER BY g.product, g.size, g.price DESC), '[]'::jsonb)
    INTO _rows
    FROM (SELECT product, size, price, SUM(qty) AS qty, SUM(revenue) AS revenue, SUM(cost) AS cost
            FROM lines GROUP BY 1, 2, 3) g;

  SELECT COALESCE(SUM(o.discount_amount), 0) INTO _discounts
    FROM public.orders o
   WHERE o.company_id = _cid AND (_branch_id IS NULL OR o.branch_id = _branch_id)
     AND o.business_date BETWEEN _from AND _to AND o.status = 'completed'
     AND NOT EXISTS (SELECT 1 FROM public.order_refunds r WHERE r.order_id = o.id AND r.status = 'active');

  SELECT jsonb_build_object('count', COUNT(*), 'total', round(COALESCE(SUM(o.total), 0), 2)) INTO _excluded
    FROM public.orders o
   WHERE o.company_id = _cid AND (_branch_id IS NULL OR o.branch_id = _branch_id)
     AND o.business_date BETWEEN _from AND _to
     AND (o.status IN ('cancelled', 'refunded', 'partially_refunded')
          OR (o.status = 'completed'
              AND EXISTS (SELECT 1 FROM public.order_refunds r WHERE r.order_id = o.id AND r.status = 'active')));

  RETURN jsonb_build_object('rows', _rows, 'excluded', _excluded,
    'invoice_discounts', round(_discounts, 2), 'with_costs', _costs);
END $function$;
REVOKE EXECUTE ON FUNCTION public.product_sales_breakdown(date, date, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.product_sales_breakdown(date, date, uuid) TO authenticated;
