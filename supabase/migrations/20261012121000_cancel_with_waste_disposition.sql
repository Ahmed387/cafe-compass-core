-- =====================================================================
-- Cancelling / removing lines of an order that is not delivered yet.
--
-- The cashier says whether the bar had already made the items:
--   not prepared → ingredients go back to the bar, zero loss (as before)
--   prepared     → ingredients are NOT restocked; they are booked as waste
--                  and "who bears the cost?" is mandatory:
--                    business  → operating loss in the P&L (stock waste)
--                    staff     → payroll penalty for one employee
--                    all_staff → split evenly over the whole team
--
-- The same rule now applies to cancelling the whole order and to removing
-- a single line: while the order's shift is still open a cashier
-- (pos.create_order) may do it without a manager; anything else needs
-- pos.cancel_order / pos.void_item.
-- Money given back always lands on an open drawer (refund_shift_for).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Book a made-but-not-served line (or part of it) as waste.
-- The sale already took the ingredients from the bar, so stock does not
-- move: the consumption is reversed and the same quantity is written off
-- as waste at the bar, at the cost frozen at sale time.
-- Returns the ingredient cost written off.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._order_line_to_waste(_order_item_id uuid, _qty numeric, _bearer text,
  _staff_id uuid, _reason text)
RETURNS numeric LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _oi public.order_items; _r record; _q numeric; _bal numeric; _cost numeric := 0;
  _profile uuid := public.current_profile_id();
BEGIN
  SELECT * INTO _oi FROM public.order_items WHERE id = _order_item_id;
  IF _oi.id IS NULL OR COALESCE(_oi.quantity, 0) <= 0 THEN RETURN 0; END IF;
  FOR _r IN
    SELECT sm.company_id, sm.branch_id, sm.item_id, sm.location, sm.unit_cost, SUM(-sm.quantity) AS used
      FROM public.stock_movements sm
     WHERE sm.reference_type = 'order_item' AND sm.reference_id = _order_item_id
       AND sm.movement_type IN ('sale_consumption', 'sale_return')
     GROUP BY 1, 2, 3, 4, 5
  LOOP
    _q := round(_r.used * LEAST(_qty, _oi.quantity) / _oi.quantity, 4);
    CONTINUE WHEN _q <= 0;
    SELECT quantity INTO _bal FROM public.branch_stock WHERE item_id = _r.item_id AND branch_id = _r.branch_id;
    INSERT INTO public.stock_movements (company_id, branch_id, item_id, movement_type, quantity, unit_cost,
      balance_after, reference_type, reference_id, reason, created_by, location)
    VALUES (_r.company_id, _r.branch_id, _r.item_id, 'sale_return', _q, _r.unit_cost, COALESCE(_bal, 0),
      'order_item', _order_item_id, 'Prepared — moved to waste', _profile, _r.location);
    INSERT INTO public.stock_movements (company_id, branch_id, item_id, movement_type, quantity, unit_cost,
      balance_after, reference_type, reference_id, reason, created_by, location, waste_bearer, waste_staff_id)
    VALUES (_r.company_id, _r.branch_id, _r.item_id, 'waste', -_q, _r.unit_cost, COALESCE(_bal, 0),
      'order_item', _order_item_id, _reason, _profile, _r.location, _bearer,
      CASE WHEN _bearer = 'staff' THEN _staff_id END);
    _cost := _cost + _q * COALESCE(_r.unit_cost, 0);
  END LOOP;
  RETURN round(_cost, 2);
END $$;
REVOKE ALL ON FUNCTION public._order_line_to_waste(uuid, numeric, text, uuid, text) FROM PUBLIC, anon, authenticated;

-- Validate a "who bears the cost?" choice for made-but-not-served items.
CREATE OR REPLACE FUNCTION public._check_waste_bearer(_bearer text, _staff_id uuid)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF _bearer IS NULL OR _bearer NOT IN ('business', 'staff', 'all_staff') THEN
    RAISE EXCEPTION 'Choose who bears the cost of the prepared items';
  END IF;
  IF _bearer = 'staff' AND (_staff_id IS NULL OR NOT EXISTS (
       SELECT 1 FROM public.user_profiles WHERE id = _staff_id AND company_id = public.current_company_id() AND is_active)) THEN
    RAISE EXCEPTION 'Select the employee who bears the cost';
  END IF;
END $$;
REVOKE ALL ON FUNCTION public._check_waste_bearer(text, uuid) FROM PUBLIC, anon, authenticated;

-- The order belongs to a shift that is still open (a live counter order).
CREATE OR REPLACE FUNCTION public._on_open_order_shift(_o public.orders)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT EXISTS (SELECT 1 FROM public.shifts s WHERE s.id = _o.shift_id AND s.status = 'open')
$$;
REVOKE ALL ON FUNCTION public._on_open_order_shift(public.orders) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- Cancel a not-yet-delivered order.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.cancel_pos_order(uuid, text);
CREATE OR REPLACE FUNCTION public.cancel_pos_order(_order_id uuid, _reason text, _prepared boolean DEFAULT false,
  _bearer text DEFAULT NULL, _staff_id uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _o public.orders; _p record; _left numeric; _given numeric := 0; _line record; _waste numeric := 0;
  _why text;
BEGIN
  IF public.current_profile_id() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO _o FROM public.orders WHERE id = _order_id FOR UPDATE;
  IF _o.id IS NULL THEN RAISE EXCEPTION 'Order not found'; END IF;
  IF _o.status = 'cancelled' THEN RAISE EXCEPTION 'Order already cancelled'; END IF;
  IF _o.status IN ('completed', 'partially_refunded', 'refunded') THEN
    RAISE EXCEPTION 'لا يمكن إلغاء طلب مكتمل أو مسترجع. يرجى استخدام مسار الاسترجاع (Refund) لتحديد مصير المخزون والنقدية.';
  END IF;
  IF _o.status NOT IN ('pending', 'open') THEN RAISE EXCEPTION 'لا يمكن إلغاء هذا الطلب في حالته الحالية'; END IF;
  IF NOT (public.has_permission('pos.cancel_order') OR public.is_super_admin()
          OR (public.has_permission('pos.create_order') AND public._on_open_order_shift(_o))) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF NOT public.can_access_branch(_o.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _reason IS NULL OR length(btrim(_reason)) < 3 THEN RAISE EXCEPTION 'A cancellation reason is required'; END IF;
  IF _prepared THEN PERFORM public._check_waste_bearer(_bearer, _staff_id); END IF;
  _why := btrim(_reason);

  -- Refund whatever is still un-refunded, method by method, from an open drawer.
  FOR _p IN
    SELECT p.method_key, SUM(p.amount) AS paid,
           COALESCE((SELECT SUM(r.amount) FROM public.order_refunds r
                      WHERE r.order_id = _order_id AND r.status = 'active' AND r.method_key = p.method_key), 0) AS refunded
      FROM public.order_payments p WHERE p.order_id = _order_id
     GROUP BY p.method_key
  LOOP
    _left := round(_p.paid - _p.refunded, 2);
    IF _left > 0 THEN
      INSERT INTO public.order_refunds (company_id, branch_id, order_id, shift_id, kind, amount, tax_amount,
        method_key, reason, status, origin, created_by)
      VALUES (_o.company_id, _o.branch_id, _o.id, public.refund_shift_for(_o, _p.method_key), 'full', _left,
        CASE WHEN _o.total > 0 THEN round(_o.tax_amount * _left / _o.total, 2) ELSE 0 END,
        _p.method_key, 'إلغاء طلب: ' || _why, 'active', 'cancel', public.current_profile_id());
      _given := _given + _left;
    END IF;
  END LOOP;

  IF _prepared THEN
    -- Made already: write the ingredients off as waste; lines are voided first so
    -- the cancel trigger (t_orders_return_stock) has nothing left to restock.
    FOR _line IN SELECT id, quantity FROM public.order_items WHERE order_id = _order_id AND status = 'active' LOOP
      _waste := _waste + public._order_line_to_waste(_line.id, _line.quantity, _bearer, _staff_id,
        'طلب ملغي بعد التحضير: ' || _why);
    END LOOP;
    UPDATE public.order_items SET status = 'voided', void_reason = _why WHERE order_id = _order_id AND status = 'active';
    UPDATE public.orders SET status = 'cancelled', cancel_reason = _reason, cancelled_at = now() WHERE id = _order_id;
    PERFORM public._charge_staff(_o.company_id, _waste, _bearer, _staff_id,
      'هالك طلب ملغي #' || _o.order_number || ': ' || _why, _o.id, _o.shift_id, 'order_waste');
  ELSE
    -- Not made: stock comes back in trigger t_orders_return_stock (before lines are voided).
    UPDATE public.orders SET status = 'cancelled', cancel_reason = _reason, cancelled_at = now() WHERE id = _order_id;
    UPDATE public.order_items SET status = 'voided', void_reason = _why WHERE order_id = _order_id AND status = 'active';
  END IF;

  PERFORM public.log_audit('order.cancel', 'pos', 'orders', _order_id, jsonb_build_object('status', _o.status),
    jsonb_build_object('status', 'cancelled', 'refunded', _given, 'prepared', _prepared,
                       'waste_cost', _waste, 'bearer', _bearer, 'staff_id', _staff_id), _reason, _o.branch_id);
  RETURN _order_id;
END $$;

-- ---------------------------------------------------------------------
-- Remove one line.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.void_order_item(uuid, text);
CREATE OR REPLACE FUNCTION public.void_order_item(_order_item_id uuid, _reason text, _prepared boolean DEFAULT false,
  _bearer text DEFAULT NULL, _staff_id uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _profile uuid := public.current_profile_id(); _oi public.order_items; _o public.orders;
  _before numeric; _after numeric; _active integer; _paid numeric := 0; _already numeric := 0; _over numeric := 0;
  _tax_share numeric := 0; _refund_id uuid; _draft boolean; _why text; _method text; _waste numeric := 0;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO _oi FROM public.order_items WHERE id = _order_item_id;
  IF _oi.id IS NULL THEN RAISE EXCEPTION 'Order line not found'; END IF;
  IF _oi.status = 'voided' THEN RAISE EXCEPTION 'This line is already voided'; END IF;
  SELECT * INTO _o FROM public.orders WHERE id = _oi.order_id FOR UPDATE;
  IF NOT public.can_access_branch(_o.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _o.status IN ('cancelled', 'refunded') THEN RAISE EXCEPTION 'Order is already closed'; END IF;

  _draft := _o.status IN ('open', 'pending') AND public._on_open_order_shift(_o);
  IF _draft THEN
    IF NOT (public.has_permission('pos.create_order') OR public.has_permission('pos.void_item') OR public.is_super_admin()) THEN
      RAISE EXCEPTION 'Not authorized';
    END IF;
    _why := COALESCE(NULLIF(btrim(COALESCE(_reason, '')), ''), 'اتشال قبل إنهاء الطلب');
  ELSE
    IF NOT (public.has_permission('pos.void_item') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
    IF _reason IS NULL OR length(btrim(_reason)) < 3 THEN RAISE EXCEPTION 'A reason is required'; END IF;
    _why := btrim(_reason);
  END IF;
  IF _prepared THEN PERFORM public._check_waste_bearer(_bearer, _staff_id); END IF;

  _before := _o.total;
  UPDATE public.order_items SET status = 'voided', void_reason = _why WHERE id = _order_item_id;
  IF _prepared THEN
    _waste := public._order_line_to_waste(_order_item_id, _oi.quantity, _bearer, _staff_id, 'صنف اتشال بعد التحضير: ' || _why);
    PERFORM public._charge_staff(_o.company_id, _waste, _bearer, _staff_id,
      'هالك صنف ' || _oi.product_name || ' (#' || _o.order_number || '): ' || _why, _o.id, _o.shift_id, 'order_waste');
  ELSE
    PERFORM public.return_line_stock(_order_item_id);
  END IF;
  PERFORM public.recalc_order_totals(_oi.order_id);
  SELECT total INTO _after FROM public.orders WHERE id = _oi.order_id;
  SELECT count(*) INTO _active FROM public.order_items WHERE order_id = _oi.order_id AND status = 'active';

  SELECT COALESCE(SUM(amount), 0) INTO _paid FROM public.order_payments WHERE order_id = _oi.order_id;
  SELECT COALESCE(SUM(amount), 0) INTO _already FROM public.order_refunds WHERE order_id = _oi.order_id AND status = 'active';
  _over := round(LEAST(_paid, _before) - _already - COALESCE(_after, 0), 2);

  IF _over > 0 THEN
    IF _paid > 0 AND COALESCE(_o.tax_amount, 0) > 0 THEN
      _tax_share := round(_o.tax_amount * LEAST(_over / GREATEST(_paid, 1), 1), 2);
    END IF;
    _method := COALESCE((SELECT p.method_key FROM public.order_payments p WHERE p.order_id = _o.id ORDER BY p.amount DESC LIMIT 1), 'cash');
    INSERT INTO public.order_refunds (company_id, branch_id, order_id, shift_id, kind, amount, tax_amount, method_key, reason, origin, created_by)
    VALUES (_o.company_id, _o.branch_id, _o.id, public.refund_shift_for(_o, _method),
      CASE WHEN _active = 0 THEN 'full' ELSE 'partial' END, _over, _tax_share, _method,
      'Auto refund for removed item: ' || _why, 'void', _profile)
    RETURNING id INTO _refund_id;
  END IF;

  IF _active = 0 THEN
    UPDATE public.orders SET status = 'cancelled', cancel_reason = COALESCE(cancel_reason, 'All lines removed: ' || _why),
      cancelled_at = COALESCE(cancelled_at, now()), updated_at = now()
     WHERE id = _oi.order_id;
  END IF;

  PERFORM public.log_audit('order.void_item', 'pos', 'order_items', _order_item_id,
    jsonb_build_object('line_total', _oi.line_total, 'order_total', _before, 'before_checkout', _draft),
    jsonb_build_object('order_total', _after, 'order_cancelled', _active = 0, 'auto_refund', _over, 'refund_id', _refund_id,
                       'prepared', _prepared, 'waste_cost', _waste, 'bearer', _bearer),
    _why, _o.branch_id);
  RETURN _order_item_id;
END $$;

REVOKE ALL ON FUNCTION public.cancel_pos_order(uuid, text, boolean, text, uuid), public.void_order_item(uuid, text, boolean, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_pos_order(uuid, text, boolean, text, uuid), public.void_order_item(uuid, text, boolean, text, uuid) TO authenticated;
