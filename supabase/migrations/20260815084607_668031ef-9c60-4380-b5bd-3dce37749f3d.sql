-- 1) Void must not fabricate a refund; the customer money stays refundable.
CREATE OR REPLACE FUNCTION public.void_order_item(_order_item_id uuid, _reason text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _profile uuid := public.current_profile_id(); _oi public.order_items; _o public.orders;
  _before numeric; _after numeric;
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

  PERFORM public.log_audit('order.void_item','pos','order_items',_order_item_id,
    jsonb_build_object('line_total',_oi.line_total,'order_total',_before),
    jsonb_build_object('order_total',_after), _reason, _o.branch_id);
  RETURN _order_item_id;
END $$;

REVOKE ALL ON FUNCTION public.void_order_item(uuid, text) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.void_order_item(uuid, text) TO authenticated, service_role;

-- 2) Refundable amount is based on what was actually collected.
CREATE OR REPLACE FUNCTION public.refund_order(_order_id uuid, _amount numeric, _reason text, _method_key text DEFAULT 'cash')
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _profile uuid := public.current_profile_id(); _o public.orders;
  _paid numeric := 0; _already numeric := 0; _remaining numeric; _tax_share numeric := 0;
  _kind text; _id uuid; _r record;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('pos.process_refund') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF _reason IS NULL OR length(btrim(_reason)) < 3 THEN RAISE EXCEPTION 'A reason is required'; END IF;

  SELECT * INTO _o FROM public.orders WHERE id = _order_id;
  IF _o.id IS NULL THEN RAISE EXCEPTION 'Order not found'; END IF;
  IF NOT public.can_access_branch(_o.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _o.status <> 'completed' THEN RAISE EXCEPTION 'Only completed orders can be refunded'; END IF;

  SELECT COALESCE(SUM(amount),0) INTO _paid FROM public.order_payments WHERE order_id = _order_id;
  SELECT COALESCE(SUM(amount),0) INTO _already
  FROM public.order_refunds WHERE order_id = _order_id AND status = 'active';

  _remaining := round(_paid - _already, 2);
  IF _remaining <= 0 THEN RAISE EXCEPTION 'This order is fully refunded'; END IF;
  IF _amount IS NULL OR _amount <= 0 THEN RAISE EXCEPTION 'Refund amount must be greater than zero'; END IF;
  IF round(_amount,2) > _remaining THEN
    RAISE EXCEPTION 'Refund (%) is more than the refundable amount (%)', round(_amount,2), _remaining;
  END IF;

  IF _paid > 0 AND _o.tax_amount > 0 THEN
    _tax_share := round(_o.tax_amount * LEAST(round(_amount,2) / _paid, 1), 2);
  END IF;
  _kind := CASE WHEN round(_amount,2) = _remaining THEN 'full' ELSE 'partial' END;

  INSERT INTO public.order_refunds (company_id, branch_id, order_id, shift_id, kind, amount,
    tax_amount, method_key, reason, created_by)
  VALUES (_o.company_id, _o.branch_id, _o.id, _o.shift_id, _kind, round(_amount,2),
    _tax_share, COALESCE(NULLIF(_method_key,''),'cash'), _reason, _profile)
  RETURNING id INTO _id;

  IF _kind = 'full' THEN
    FOR _r IN SELECT id FROM public.order_items WHERE order_id = _order_id AND status = 'active' LOOP
      PERFORM public.return_line_stock(_r.id);
    END LOOP;
    UPDATE public.orders SET status = 'refunded', updated_at = now() WHERE id = _order_id;
  END IF;

  PERFORM public.log_audit('order.refund','pos','orders',_order_id,
    jsonb_build_object('paid',_paid,'refunded_before',_already),
    jsonb_build_object('refund_amount',round(_amount,2),'kind',_kind), _reason, _o.branch_id);
  RETURN _id;
END $$;

REVOKE ALL ON FUNCTION public.refund_order(uuid, numeric, text, text) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.refund_order(uuid, numeric, text, text) TO authenticated, service_role;

-- 3) Profit statement: refunded orders must be counted once, not twice.
DROP FUNCTION IF EXISTS public.period_pnl(uuid);
CREATE OR REPLACE FUNCTION public.period_pnl(_period_id uuid)
RETURNS TABLE(revenue numeric, tax_collected numeric, cogs numeric, waste_cost numeric,
  refunds_total numeric, expenses_total numeric, payroll_total numeric, net_profit numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _p public.accounting_periods;
  _rev numeric := 0; _tax numeric := 0; _cogs numeric := 0; _waste numeric := 0;
  _ref numeric := 0; _ref_tax numeric := 0; _exp numeric := 0; _pay numeric := 0;
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

  -- Refunded orders returned their stock, so their cost is not a cost of sale.
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

  SELECT COALESCE(SUM(r.amount),0), COALESCE(SUM(r.tax_amount),0) INTO _ref, _ref_tax
  FROM public.order_refunds r JOIN public.orders o ON o.id = r.order_id
  WHERE r.company_id = _p.company_id AND r.status = 'active'
    AND o.status IN ('completed','refunded')
    AND r.created_at::date BETWEEN _p.start_date AND _p.end_date;

  SELECT COALESCE(SUM(e.amount),0) INTO _exp FROM public.expenses e
  WHERE e.company_id = _p.company_id AND e.status = 'active'
    AND e.expense_date BETWEEN _p.start_date AND _p.end_date;

  SELECT COALESCE(SUM(s.net_amount),0) INTO _pay FROM public.salary_payments s
  WHERE s.company_id = _p.company_id AND s.status = 'active'
    AND s.period_start <= _p.end_date AND s.period_end >= _p.start_date;

  RETURN QUERY SELECT round(_rev - (_ref - _ref_tax),2), round(_tax - _ref_tax,2),
    round(_cogs,2), round(_waste,2), round(_ref,2), round(_exp,2), round(_pay,2),
    round((_rev - (_ref - _ref_tax)) - _cogs - _waste - _exp - _pay, 2);
END $$;

REVOKE ALL ON FUNCTION public.period_pnl(uuid) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.period_pnl(uuid) TO authenticated, service_role;

-- 4) Guarded period close (no open shifts / open orders) instead of a direct client update.
CREATE OR REPLACE FUNCTION public.close_accounting_period(_period_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _profile uuid := public.current_profile_id(); _p public.accounting_periods;
  _open_shifts integer := 0; _open_orders integer := 0;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('settings.manage') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO _p FROM public.accounting_periods
   WHERE id = _period_id AND company_id = public.current_company_id();
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Period not found'; END IF;
  IF _p.status = 'closed' THEN RAISE EXCEPTION 'Period is already closed'; END IF;

  SELECT count(*) INTO _open_shifts FROM public.shifts s
   WHERE s.company_id = _p.company_id AND s.status = 'open'
     AND s.opened_at::date <= _p.end_date;
  IF _open_shifts > 0 THEN
    RAISE EXCEPTION 'Close the % open shift(s) in this period first', _open_shifts;
  END IF;

  SELECT count(*) INTO _open_orders FROM public.orders o
   WHERE o.company_id = _p.company_id AND o.status = 'open'
     AND o.created_at::date BETWEEN _p.start_date AND _p.end_date;
  IF _open_orders > 0 THEN
    RAISE EXCEPTION 'Settle the % unpaid order(s) in this period first', _open_orders;
  END IF;

  UPDATE public.accounting_periods
     SET status = 'closed', closed_at = now(), closed_by = _profile
   WHERE id = _period_id;

  PERFORM public.log_audit('period.close','finance','accounting_periods',_period_id,
    jsonb_build_object('status','open'), jsonb_build_object('status','closed'), NULL, NULL);
  RETURN _period_id;
END $$;

REVOKE ALL ON FUNCTION public.close_accounting_period(uuid) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.close_accounting_period(uuid) TO authenticated, service_role;

-- 5) Guarded expense approval.
CREATE OR REPLACE FUNCTION public.approve_expense(_expense_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _profile uuid := public.current_profile_id(); _e public.expenses;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('expenses.approve') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;

  SELECT * INTO _e FROM public.expenses
   WHERE id = _expense_id AND company_id = public.current_company_id();
  IF _e.id IS NULL THEN RAISE EXCEPTION 'Expense not found'; END IF;
  IF _e.status <> 'active' THEN RAISE EXCEPTION 'Only active expenses can be approved'; END IF;
  IF _e.approved_at IS NOT NULL THEN RAISE EXCEPTION 'Expense is already approved'; END IF;
  IF _e.branch_id IS NOT NULL AND NOT public.can_access_branch(_e.branch_id) THEN
    RAISE EXCEPTION 'Not authorized for this branch';
  END IF;

  UPDATE public.expenses SET approved_by = _profile, approved_at = now(), updated_at = now()
   WHERE id = _expense_id;

  PERFORM public.log_audit('expense.approve','finance','expenses',_expense_id, NULL,
    jsonb_build_object('amount',_e.amount), NULL, _e.branch_id);
  RETURN _expense_id;
END $$;

REVOKE ALL ON FUNCTION public.approve_expense(uuid) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.approve_expense(uuid) TO authenticated, service_role;

-- 6) Repair existing data: the fabricated 'void' refunds blocked real refunds.
UPDATE public.order_refunds SET status = 'voided'
 WHERE kind = 'void' AND status = 'active';
