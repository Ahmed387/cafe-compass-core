DROP FUNCTION IF EXISTS public.period_pnl(uuid);

CREATE OR REPLACE FUNCTION public.period_pnl(_period_id uuid)
 RETURNS TABLE(revenue numeric, tax_collected numeric, cogs numeric, waste_cost numeric, refunds_total numeric, points_redeemed numeric, expenses_total numeric, payroll_total numeric, net_profit numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _p public.accounting_periods;
  _rev numeric := 0; _tax numeric := 0; _cogs numeric := 0; _waste numeric := 0;
  _ref numeric := 0; _ref_tax numeric := 0; _ref_all numeric := 0; _exp numeric := 0; _pay numeric := 0;
  _pts numeric := 0; _net_rev numeric := 0;
BEGIN
  IF NOT (public.has_permission('reports.profit') OR public.has_permission('partners.view_profit') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  SELECT * INTO _p FROM public.accounting_periods WHERE id = _period_id AND company_id = public.current_company_id();
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Period not found'; END IF;

  SELECT COALESCE(SUM(o.total - o.tax_amount),0), COALESCE(SUM(o.tax_amount),0)
    INTO _rev, _tax
  FROM public.orders o
  WHERE o.company_id = _p.company_id AND o.status IN ('completed','refunded')
    AND o.created_at::date BETWEEN _p.start_date AND _p.end_date;

  -- Loyalty points settle invoices without collecting cash or bank money.
  -- They are a promotional discount, never realized revenue.
  SELECT COALESCE(SUM(op.amount),0) INTO _pts
  FROM public.order_payments op JOIN public.orders o ON o.id = op.order_id
  WHERE o.company_id = _p.company_id AND o.status IN ('completed','refunded')
    AND op.method_key = 'points'
    AND o.created_at::date BETWEEN _p.start_date AND _p.end_date;

  SELECT COALESCE(SUM(oi.unit_cost * oi.quantity),0) INTO _cogs
  FROM public.order_items oi JOIN public.orders o ON o.id = oi.order_id
  WHERE o.company_id = _p.company_id AND o.status = 'completed' AND oi.status = 'active'
    AND o.created_at::date BETWEEN _p.start_date AND _p.end_date;

  SELECT COALESCE(SUM(-sm.quantity * sm.unit_cost),0) INTO _waste
  FROM public.stock_movements sm
  WHERE sm.company_id = _p.company_id
    AND sm.movement_type IN ('waste','stocktake')
    AND sm.quantity < 0
    AND sm.created_at::date BETWEEN _p.start_date AND _p.end_date;

  SELECT COALESCE(SUM(r.amount) FILTER (WHERE r.origin = 'manual'),0),
         COALESCE(SUM(r.tax_amount) FILTER (WHERE r.origin = 'manual'),0),
         COALESCE(SUM(r.amount),0)
    INTO _ref, _ref_tax, _ref_all
  FROM public.order_refunds r JOIN public.orders o ON o.id = r.order_id
  WHERE r.company_id = _p.company_id AND r.status = 'active'
    AND o.status IN ('completed','refunded','cancelled')
    AND r.created_at::date BETWEEN _p.start_date AND _p.end_date;

  SELECT COALESCE(SUM(e.amount),0) INTO _exp FROM public.expenses e
  WHERE e.company_id = _p.company_id AND e.status = 'active' AND e.approved_at IS NOT NULL
    AND e.expense_date BETWEEN _p.start_date AND _p.end_date;

  SELECT COALESCE(SUM(s.net_amount),0) INTO _pay FROM public.salary_payments s
  WHERE s.company_id = _p.company_id AND s.status = 'active'
    AND s.period_start <= _p.end_date AND s.period_end >= _p.start_date;

  -- Net realized revenue = gross sales excl. tax - net refunds - points redeemed.
  _net_rev := _rev - (_ref - _ref_tax) - _pts;

  RETURN QUERY SELECT round(_net_rev,2), round(_tax - _ref_tax,2),
    round(_cogs,2), round(_waste,2), round(_ref_all,2), round(_pts,2),
    round(_exp,2), round(_pay,2),
    round(_net_rev - _cogs - _waste - _exp - _pay, 2);
END
$function$;

REVOKE ALL ON FUNCTION public.period_pnl(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.period_pnl(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.period_pnl(uuid) TO service_role;