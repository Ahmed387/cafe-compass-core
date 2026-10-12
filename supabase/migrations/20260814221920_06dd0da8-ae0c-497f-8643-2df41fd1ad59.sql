CREATE TABLE public.order_refunds (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  branch_id uuid NOT NULL REFERENCES public.branches(id),
  order_id uuid NOT NULL REFERENCES public.orders(id),
  order_item_id uuid REFERENCES public.order_items(id),
  shift_id uuid REFERENCES public.shifts(id),
  kind text NOT NULL CHECK (kind IN ('void','partial','full')),
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  tax_amount numeric(12,2) NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
  method_key text,
  reason text NOT NULL,
  status record_status NOT NULL DEFAULT 'active',
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT ON public.order_refunds TO authenticated;
GRANT ALL ON public.order_refunds TO service_role;
ALTER TABLE public.order_refunds ENABLE ROW LEVEL SECURITY;

CREATE POLICY "refunds_select" ON public.order_refunds FOR SELECT TO authenticated
USING (
  company_id = public.current_company_id()
  AND public.can_access_branch(branch_id)
  AND (public.has_permission('pos.view') OR public.has_permission('reports.sales') OR public.is_super_admin())
);

CREATE TRIGGER t_refunds_no_delete BEFORE DELETE ON public.order_refunds
FOR EACH ROW EXECUTE FUNCTION public.forbid_hard_delete();

CREATE INDEX order_refunds_order_idx ON public.order_refunds(order_id);
CREATE INDEX order_refunds_company_created_idx ON public.order_refunds(company_id, created_at DESC);

-- Internal: recompute order money from its remaining active lines.
CREATE OR REPLACE FUNCTION public.recalc_order_totals(_order_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _o public.orders; _sub numeric := 0; _taxable numeric := 0;
  _rate numeric := 0; _enabled boolean := false; _disc numeric; _tax numeric := 0;
BEGIN
  SELECT * INTO _o FROM public.orders WHERE id = _order_id;
  IF _o.id IS NULL THEN RAISE EXCEPTION 'Order not found'; END IF;

  SELECT COALESCE(SUM(oi.line_total),0),
         COALESCE(SUM(CASE WHEN COALESCE(p.is_taxable, true) THEN oi.line_total ELSE 0 END),0)
    INTO _sub, _taxable
  FROM public.order_items oi
  LEFT JOIN public.products p ON p.id = oi.product_id
  WHERE oi.order_id = _order_id AND oi.status = 'active';

  SELECT c.tax_enabled, c.tax_rate INTO _enabled, _rate
  FROM public.companies c WHERE c.id = _o.company_id;

  _disc := LEAST(COALESCE(_o.discount_amount,0), _sub);
  IF _enabled AND _sub > 0 THEN
    _tax := round(((_taxable - (_disc * (_taxable / _sub))) * _rate / 100)::numeric, 2);
  END IF;

  UPDATE public.orders
     SET subtotal = round(_sub,2), discount_amount = round(_disc,2),
         tax_amount = _tax, total = round(_sub - _disc + _tax, 2), updated_at = now()
   WHERE id = _order_id;
END $$;

REVOKE ALL ON FUNCTION public.recalc_order_totals(uuid) FROM anon, public, authenticated;
GRANT EXECUTE ON FUNCTION public.recalc_order_totals(uuid) TO service_role;

-- Internal: send the ingredients of one order line back to stock.
CREATE OR REPLACE FUNCTION public.return_line_stock(_order_item_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _r record;
BEGIN
  FOR _r IN
    SELECT sm.item_id, sm.quantity, sm.branch_id FROM public.stock_movements sm
    WHERE sm.reference_type = 'order_item' AND sm.movement_type = 'sale_consumption'
      AND sm.reference_id = _order_item_id
  LOOP
    PERFORM public.apply_stock_movement(_r.branch_id, _r.item_id, 'sale_return', -_r.quantity,
      NULL, 'Line voided/refunded', 'order_item', _order_item_id);
  END LOOP;
END $$;

REVOKE ALL ON FUNCTION public.return_line_stock(uuid) FROM anon, public, authenticated;
GRANT EXECUTE ON FUNCTION public.return_line_stock(uuid) TO service_role;

-- Void a single line of an order.
CREATE OR REPLACE FUNCTION public.void_order_item(_order_item_id uuid, _reason text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _profile uuid := public.current_profile_id(); _oi public.order_items; _o public.orders;
  _before numeric; _after numeric; _refund uuid;
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

  IF _before - _after > 0 THEN
    INSERT INTO public.order_refunds (company_id, branch_id, order_id, order_item_id, shift_id,
      kind, amount, tax_amount, method_key, reason, created_by)
    VALUES (_o.company_id, _o.branch_id, _o.id, _order_item_id, _o.shift_id, 'void',
      round(_before - _after, 2), 0,
      (SELECT p.method_key FROM public.order_payments p WHERE p.order_id = _o.id ORDER BY p.amount DESC LIMIT 1),
      _reason, _profile)
    RETURNING id INTO _refund;
  END IF;

  PERFORM public.log_audit('order.void_item','pos','order_items',_order_item_id,
    jsonb_build_object('line_total',_oi.line_total,'order_total',_before),
    jsonb_build_object('order_total',_after), _reason, _o.branch_id);
  RETURN _refund;
END $$;

REVOKE ALL ON FUNCTION public.void_order_item(uuid, text) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.void_order_item(uuid, text) TO authenticated, service_role;

-- Refund part or all of an order.
CREATE OR REPLACE FUNCTION public.refund_order(_order_id uuid, _amount numeric, _reason text, _method_key text DEFAULT 'cash')
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _profile uuid := public.current_profile_id(); _o public.orders;
  _already numeric; _remaining numeric; _tax_share numeric := 0; _kind text; _id uuid; _r record;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('pos.process_refund') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF _reason IS NULL OR length(btrim(_reason)) < 3 THEN RAISE EXCEPTION 'A reason is required'; END IF;

  SELECT * INTO _o FROM public.orders WHERE id = _order_id;
  IF _o.id IS NULL THEN RAISE EXCEPTION 'Order not found'; END IF;
  IF NOT public.can_access_branch(_o.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _o.status <> 'completed' THEN RAISE EXCEPTION 'Only completed orders can be refunded'; END IF;

  SELECT COALESCE(SUM(amount),0) INTO _already
  FROM public.order_refunds WHERE order_id = _order_id AND status = 'active';
  _remaining := round(_o.total - _already, 2);
  IF _remaining <= 0 THEN RAISE EXCEPTION 'This order is fully refunded'; END IF;
  IF _amount IS NULL OR _amount <= 0 THEN RAISE EXCEPTION 'Refund amount must be greater than zero'; END IF;
  IF round(_amount,2) > _remaining THEN
    RAISE EXCEPTION 'Refund (%) is more than the refundable amount (%)', round(_amount,2), _remaining;
  END IF;

  IF _o.total > 0 THEN
    _tax_share := round(_o.tax_amount * (round(_amount,2) / _o.total), 2);
  END IF;
  _kind := CASE WHEN round(_amount,2) = _remaining AND _already = 0 THEN 'full' ELSE 'partial' END;

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
    jsonb_build_object('total',_o.total,'refunded_before',_already),
    jsonb_build_object('refund_amount',round(_amount,2),'kind',_kind), _reason, _o.branch_id);
  RETURN _id;
END $$;

REVOKE ALL ON FUNCTION public.refund_order(uuid, numeric, text, text) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.refund_order(uuid, numeric, text, text) TO authenticated, service_role;

-- Cash reconciliation must account for cash refunds.
CREATE OR REPLACE FUNCTION public.close_shift(_shift_id uuid, _closing_cash numeric, _notes text DEFAULT NULL::text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _s public.shifts; _expected numeric; _cash_in numeric := 0; _cash_out numeric := 0;
  _profile uuid := public.current_profile_id();
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO _s FROM public.shifts WHERE id = _shift_id;
  IF _s.id IS NULL THEN RAISE EXCEPTION 'Shift not found'; END IF;
  IF _s.status = 'closed' THEN RAISE EXCEPTION 'Shift already closed'; END IF;
  IF NOT (public.has_permission('shifts.close') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF NOT public.can_access_branch(_s.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _s.user_id <> _profile AND NOT (public.has_permission('shifts.adjust_cash') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'You can only close your own shift';
  END IF;

  SELECT COALESCE(SUM(p.amount),0) INTO _cash_in
  FROM public.orders o JOIN public.order_payments p ON p.order_id = o.id
  WHERE o.shift_id = _shift_id AND o.status <> 'cancelled' AND p.method_key = 'cash';

  SELECT COALESCE(SUM(r.amount),0) INTO _cash_out
  FROM public.order_refunds r
  WHERE r.shift_id = _shift_id AND r.status = 'active' AND COALESCE(r.method_key,'cash') = 'cash';

  _expected := _s.opening_cash + _cash_in - _cash_out;

  UPDATE public.shifts SET status = 'closed', closing_cash = _closing_cash, expected_cash = _expected,
    variance = COALESCE(_closing_cash,0) - _expected, notes = _notes, closed_at = now(), closed_by = _profile
  WHERE id = _shift_id;
  PERFORM public.log_audit('shift.close','pos','shifts',_shift_id,NULL,
    jsonb_build_object('closing_cash',_closing_cash,'expected_cash',_expected),_notes,_s.branch_id);
  RETURN _shift_id;
END $$;

REVOKE ALL ON FUNCTION public.close_shift(uuid, numeric, text) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.close_shift(uuid, numeric, text) TO authenticated, service_role;

-- Profit statement must be net of refunds.
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
  WHERE o.company_id = _p.company_id AND o.status = 'completed'
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

  SELECT COALESCE(SUM(r.amount),0), COALESCE(SUM(r.tax_amount),0) INTO _ref, _ref_tax
  FROM public.order_refunds r JOIN public.orders o ON o.id = r.order_id
  WHERE r.company_id = _p.company_id AND r.status = 'active' AND o.status = 'completed'
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
