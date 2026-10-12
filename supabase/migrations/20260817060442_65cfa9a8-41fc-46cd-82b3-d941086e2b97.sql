ALTER TABLE public.order_refunds ADD COLUMN IF NOT EXISTS origin text NOT NULL DEFAULT 'manual';
ALTER TABLE public.order_refunds ADD CONSTRAINT order_refunds_origin_check CHECK (origin IN ('manual','void'));
UPDATE public.order_refunds SET origin = 'void' WHERE reason LIKE 'Auto refund for voided item%';

CREATE OR REPLACE FUNCTION public.void_order_item(_order_item_id uuid, _reason text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _profile uuid := public.current_profile_id(); _oi public.order_items; _o public.orders;
  _before numeric; _after numeric; _active integer;
  _paid numeric := 0; _already numeric := 0; _over numeric := 0; _tax_share numeric := 0;
  _refund_id uuid;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('pos.void_item') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF _reason IS NULL OR length(btrim(_reason)) < 3 THEN RAISE EXCEPTION 'A reason is required'; END IF;

  SELECT * INTO _oi FROM public.order_items WHERE id = _order_item_id;
  IF _oi.id IS NULL THEN RAISE EXCEPTION 'Order line not found'; END IF;
  IF _oi.status = 'voided' THEN RAISE EXCEPTION 'This line is already voided'; END IF;

  SELECT * INTO _o FROM public.orders WHERE id = _oi.order_id;
  IF NOT public.can_access_branch(_o.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _o.status IN ('cancelled','refunded') THEN RAISE EXCEPTION 'Order is already closed'; END IF;

  _before := _o.total;
  UPDATE public.order_items SET status = 'voided', void_reason = _reason WHERE id = _order_item_id;
  PERFORM public.return_line_stock(_order_item_id);
  PERFORM public.recalc_order_totals(_oi.order_id);
  SELECT total INTO _after FROM public.orders WHERE id = _oi.order_id;

  SELECT count(*) INTO _active FROM public.order_items
   WHERE order_id = _oi.order_id AND status = 'active';

  SELECT COALESCE(SUM(amount),0) INTO _paid FROM public.order_payments WHERE order_id = _oi.order_id;
  SELECT COALESCE(SUM(amount),0) INTO _already
    FROM public.order_refunds WHERE order_id = _oi.order_id AND status = 'active';
  _over := round(LEAST(_paid, _before) - _already - COALESCE(_after,0), 2);

  IF _over > 0 THEN
    IF _paid > 0 AND COALESCE(_o.tax_amount,0) > 0 THEN
      _tax_share := round(_o.tax_amount * LEAST(_over / GREATEST(_paid,1), 1), 2);
    END IF;
    INSERT INTO public.order_refunds (company_id, branch_id, order_id, shift_id, kind, amount,
      tax_amount, method_key, reason, origin, created_by)
    VALUES (_o.company_id, _o.branch_id, _o.id, _o.shift_id,
      CASE WHEN _active = 0 THEN 'full' ELSE 'partial' END, _over,
      _tax_share,
      COALESCE((SELECT p.method_key FROM public.order_payments p WHERE p.order_id = _o.id
                ORDER BY p.amount DESC LIMIT 1), 'cash'),
      'Auto refund for voided item: ' || _reason, 'void', _profile)
    RETURNING id INTO _refund_id;
  END IF;

  IF _active = 0 THEN
    UPDATE public.orders
       SET status = 'cancelled',
           cancel_reason = COALESCE(cancel_reason, 'All lines voided: ' || _reason),
           cancelled_at = COALESCE(cancelled_at, now()),
           updated_at = now()
     WHERE id = _oi.order_id;
  END IF;

  PERFORM public.log_audit('order.void_item','pos','order_items',_order_item_id,
    jsonb_build_object('line_total',_oi.line_total,'order_total',_before),
    jsonb_build_object('order_total',_after,'order_cancelled', _active = 0,
      'auto_refund', _over, 'refund_id', _refund_id), _reason, _o.branch_id);
  RETURN _order_item_id;
END $$;

CREATE OR REPLACE FUNCTION public.period_pnl(_period_id uuid)
RETURNS TABLE(revenue numeric, tax_collected numeric, cogs numeric, waste_cost numeric,
  refunds_total numeric, expenses_total numeric, payroll_total numeric, net_profit numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _p public.accounting_periods;
  _rev numeric := 0; _tax numeric := 0; _cogs numeric := 0; _waste numeric := 0;
  _ref numeric := 0; _ref_tax numeric := 0; _ref_all numeric := 0; _exp numeric := 0; _pay numeric := 0;
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

  -- Void refunds already left the order total, so only manual refunds reduce revenue.
  SELECT COALESCE(SUM(r.amount) FILTER (WHERE r.origin = 'manual'),0),
         COALESCE(SUM(r.tax_amount) FILTER (WHERE r.origin = 'manual'),0),
         COALESCE(SUM(r.amount),0)
    INTO _ref, _ref_tax, _ref_all
  FROM public.order_refunds r JOIN public.orders o ON o.id = r.order_id
  WHERE r.company_id = _p.company_id AND r.status = 'active'
    AND o.status IN ('completed','refunded','cancelled')
    AND r.created_at::date BETWEEN _p.start_date AND _p.end_date;

  SELECT COALESCE(SUM(e.amount),0) INTO _exp FROM public.expenses e
  WHERE e.company_id = _p.company_id AND e.status = 'active'
    AND e.expense_date BETWEEN _p.start_date AND _p.end_date;

  SELECT COALESCE(SUM(s.net_amount),0) INTO _pay FROM public.salary_payments s
  WHERE s.company_id = _p.company_id AND s.status = 'active'
    AND s.period_start <= _p.end_date AND s.period_end >= _p.start_date;

  RETURN QUERY SELECT round(_rev - (_ref - _ref_tax),2), round(_tax - _ref_tax,2),
    round(_cogs,2), round(_waste,2), round(_ref_all,2), round(_exp,2), round(_pay,2),
    round((_rev - (_ref - _ref_tax)) - _cogs - _waste - _exp - _pay, 2);
END $$;