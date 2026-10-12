DROP FUNCTION IF EXISTS public.period_pnl(uuid);

CREATE FUNCTION public.period_pnl(_period_id uuid)
RETURNS TABLE(
  gross_sales numeric,
  promo_discount numeric,
  manual_discounts numeric,
  points_redeemed numeric,
  refunds_total numeric,
  refund_tax_reversed numeric,
  partner_tab_unsettled numeric,
  revenue numeric,
  tax_collected numeric,
  cogs numeric,
  waste_cost numeric,
  expenses_total numeric,
  payroll_total numeric,
  gross_profit numeric,
  net_profit numeric
)
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

  -- Orders in scope: revenue-bearing statuses inside the period.
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

  -- Gross menu sales at official prices (menu base price + add-ons), before any discount.
  SELECT COALESCE(SUM((oi.base_price + COALESCE(oi.modifiers_total,0)) * oi.quantity),0)
    INTO _gross
  FROM public.order_items oi JOIN _pnl_orders po ON po.order_id = oi.order_id
  WHERE oi.status = 'active' AND NOT po.on_tab;

  SELECT COALESCE(SUM(o.promotional_discount),0), COALESCE(SUM(o.discount_amount),0),
         COALESCE(SUM(o.tax_amount),0)
    INTO _promo, _manual, _tax
  FROM public.orders o JOIN _pnl_orders po ON po.order_id = o.id
  WHERE NOT po.on_tab;

  -- Unsettled partner tab sales are reported separately until settlement.
  SELECT COALESCE(SUM(o.total),0) INTO _tab
  FROM public.orders o JOIN _pnl_orders po ON po.order_id = o.id
  WHERE po.on_tab;

  SELECT COALESCE(SUM(op.amount),0) INTO _pts
  FROM public.order_payments op JOIN _pnl_orders po ON po.order_id = op.order_id
  WHERE op.method_key = 'points';

  SELECT COALESCE(SUM(oi.unit_cost * oi.quantity),0) INTO _cogs
  FROM public.order_items oi JOIN _pnl_orders po ON po.order_id = oi.order_id
  WHERE oi.status = 'active';

  SELECT COALESCE(SUM(-sm.quantity * sm.unit_cost),0) INTO _waste
  FROM public.stock_movements sm
  WHERE sm.company_id = _p.company_id
    AND sm.movement_type IN ('waste','stocktake')
    AND sm.quantity < 0
    AND sm.created_at::date BETWEEN _p.start_date AND _p.end_date;

  -- Items refunded as operational waste never return to stock; their consumed
  -- recipe cost is a period loss, tracked in the refund payload.
  SELECT COALESCE(SUM(COALESCE((entry->>'unit_cost')::numeric,0) * COALESCE((entry->>'quantity')::numeric,0)),0)
    INTO _ref_waste
  FROM public.order_refunds r
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(r.items_payload,'[]'::jsonb)) AS entry
  WHERE r.company_id = _p.company_id AND r.status = 'active'
    AND entry->>'disposition' = 'waste'
    AND r.created_at::date BETWEEN _p.start_date AND _p.end_date;

  _waste := _waste + _ref_waste;

  -- Refunds at full value (tax included) plus the tax portion reversed back.
  SELECT COALESCE(SUM(r.amount),0), COALESCE(SUM(r.tax_amount),0)
    INTO _ref, _ref_tax
  FROM public.order_refunds r JOIN public.orders o ON o.id = r.order_id
  WHERE r.company_id = _p.company_id AND r.status = 'active'
    AND o.status IN ('completed','refunded','partially_refunded','cancelled')
    AND r.created_at::date BETWEEN _p.start_date AND _p.end_date;

  SELECT COALESCE(SUM(e.amount),0) INTO _exp FROM public.expenses e
  WHERE e.company_id = _p.company_id AND e.status = 'active' AND e.approved_at IS NOT NULL
    AND e.expense_date BETWEEN _p.start_date AND _p.end_date;

  SELECT COALESCE(SUM(s.net_amount),0) INTO _pay FROM public.salary_payments s
  WHERE s.company_id = _p.company_id AND s.status = 'active'
    AND s.period_start <= _p.end_date AND s.period_end >= _p.start_date;

  -- Net revenue identity (exact to the piastre):
  -- gross - promo - manual discounts - points - (refunds incl. tax) + refunded tax - tax collected
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

REVOKE ALL ON FUNCTION public.period_pnl(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.period_pnl(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.period_pnl(uuid) TO service_role;