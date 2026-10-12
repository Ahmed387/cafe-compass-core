-- =====================================================================
-- Orders: refunds counted once, partner tabs follow refunds, and lines can
-- be removed freely before an order is final.
--
-- One rule everywhere:
--   Drawer cash = every cash payment received − every cash refund paid back
--                 (whatever later happened to the order)
--   Revenue     = sales of non-cancelled orders − refunds of non-cancelled orders
-- Cancelling a paid order therefore always records the money given back.
-- =====================================================================

-- Cancellations record their refund with their own origin.
ALTER TABLE public.order_refunds DROP CONSTRAINT IF EXISTS order_refunds_origin_check;
ALTER TABLE public.order_refunds ADD CONSTRAINT order_refunds_origin_check CHECK (origin = ANY (ARRAY['manual', 'void', 'cancel']));

-- ---------------------------------------------------------------------
-- Which drawer pays a refund: the order's own shift while it is still open,
-- otherwise today's open shift (refund_target_shift). A refund never lands
-- on a shift that is already closed.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.refund_shift_for(_o public.orders, _method_key text)
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT CASE WHEN EXISTS (SELECT 1 FROM public.shifts s WHERE s.id = _o.shift_id AND s.status = 'open')
              THEN _o.shift_id
              ELSE public.refund_target_shift(_o.branch_id, _method_key) END
$$;
REVOKE ALL ON FUNCTION public.refund_shift_for(public.orders, text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- Live drawer figures for the open shift (POS closing screen).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.shift_expected_cash(_shift_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _s public.shifts; _cash_in numeric := 0; _cash_out numeric := 0; _sales numeric := 0; _orders integer := 0; _exp numeric := 0;
BEGIN
  IF public.current_profile_id() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO _s FROM public.shifts WHERE id = _shift_id;
  IF _s.id IS NULL THEN RAISE EXCEPTION 'Shift not found'; END IF;
  IF NOT public.can_access_branch(_s.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _s.user_id <> public.current_profile_id() AND NOT (public.has_permission('shifts.view') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  SELECT COALESCE(SUM(p.amount), 0) INTO _cash_in
    FROM public.orders o JOIN public.order_payments p ON p.order_id = o.id
   WHERE o.shift_id = _shift_id AND p.method_key = 'cash';
  SELECT COALESCE(SUM(r.amount), 0) INTO _cash_out
    FROM public.order_refunds r
   WHERE r.shift_id = _shift_id AND r.status = 'active' AND COALESCE(r.method_key, 'cash') = 'cash';
  SELECT COALESCE(SUM(o.total), 0), count(*) INTO _sales, _orders
    FROM public.orders o WHERE o.shift_id = _shift_id AND o.status NOT IN ('cancelled', 'open');
  _exp := public.shift_expense_total(_shift_id);
  RETURN jsonb_build_object(
    'opening_cash', _s.opening_cash, 'cash_in', _cash_in, 'cash_refunds', _cash_out, 'shift_expenses', _exp,
    'expected_cash', round(_s.opening_cash + _cash_in - _cash_out - _exp, 2),
    'sales_total', _sales, 'orders_count', _orders);
END $$;

-- ---------------------------------------------------------------------
-- Partner tabs follow refunds. A refund on a tab-paid order lowers what the
-- partner still owes; any part already settled through a payout is credited
-- back to the partner's ledger so nothing is charged for a cancelled sale.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_refund_adjusts_partner_tab()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _t public.partner_tab_orders; _open numeric; _reduce numeric; _credit numeric; _currency text;
BEGIN
  IF NEW.status <> 'active' OR public.tender_key(NEW.method_key) <> 'partner_tab' THEN RETURN NEW; END IF;
  SELECT * INTO _t FROM public.partner_tab_orders WHERE order_id = NEW.order_id FOR UPDATE;
  IF _t.id IS NULL THEN RETURN NEW; END IF;

  _open := GREATEST(_t.total_amount - _t.settled_amount, 0);
  _reduce := LEAST(round(NEW.amount, 2), _open);
  _credit := round(NEW.amount - _reduce, 2);

  -- The open part shrinks first; the tab never drops below what was already settled.
  UPDATE public.partner_tab_orders
     SET total_amount = round(total_amount - _reduce, 2),
         is_settled = round(total_amount - _reduce, 2) <= settled_amount,
         settled_at = CASE WHEN round(total_amount - _reduce, 2) <= settled_amount THEN COALESCE(settled_at, now()) ELSE settled_at END,
         updated_at = now()
   WHERE id = _t.id;

  IF _credit > 0 THEN
    SELECT currency INTO _currency FROM public.companies WHERE id = NEW.company_id;
    INSERT INTO public.partner_ledger_transactions (company_id, partner_id, transaction_type, amount, currency,
      reference_type, reference_id, description, transaction_date, status, created_by)
    VALUES (NEW.company_id, _t.partner_id, 'adjustment', _credit, COALESCE(_currency, 'EGP'), 'partner_tab_refund', NEW.id,
      'مرتجع فاتورة على الحساب اتخصمت قبل كده', public.business_date(NEW.created_at, NEW.company_id), 'active', NEW.created_by);
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS t_refund_adjusts_partner_tab ON public.order_refunds;
CREATE TRIGGER t_refund_adjusts_partner_tab AFTER INSERT ON public.order_refunds
  FOR EACH ROW EXECUTE FUNCTION public.trg_refund_adjusts_partner_tab();

-- ---------------------------------------------------------------------
-- Cancel a not-yet-completed order: everything paid is recorded as given back,
-- per payment method, so the drawer and P&L both stay exact.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_pos_order(_order_id uuid, _reason text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _o public.orders; _p record; _left numeric; _given numeric := 0;
BEGIN
  SELECT * INTO _o FROM public.orders WHERE id = _order_id FOR UPDATE;
  IF _o.id IS NULL THEN RAISE EXCEPTION 'Order not found'; END IF;
  IF _o.status = 'cancelled' THEN RAISE EXCEPTION 'Order already cancelled'; END IF;
  IF _o.status IN ('completed', 'partially_refunded', 'refunded') THEN
    RAISE EXCEPTION 'لا يمكن إلغاء طلب مكتمل أو مسترجع. يرجى استخدام مسار الاسترجاع (Refund) لتحديد مصير المخزون والنقدية.';
  END IF;
  IF _o.status NOT IN ('pending', 'open') THEN RAISE EXCEPTION 'لا يمكن إلغاء هذا الطلب في حالته الحالية'; END IF;
  IF NOT (public.has_permission('pos.cancel_order') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF NOT public.can_access_branch(_o.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _reason IS NULL OR length(btrim(_reason)) < 3 THEN RAISE EXCEPTION 'A cancellation reason is required'; END IF;

  -- Refund whatever is still un-refunded, method by method.
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
        _p.method_key, 'إلغاء طلب: ' || btrim(_reason), 'active', 'cancel', public.current_profile_id());
      _given := _given + _left;
    END IF;
  END LOOP;

  UPDATE public.orders SET status = 'cancelled', cancel_reason = _reason, cancelled_at = now() WHERE id = _order_id;
  -- Stock comes back in trigger t_orders_return_stock (before lines are voided).
  UPDATE public.order_items SET status = 'voided', void_reason = _reason WHERE order_id = _order_id;

  -- Cashback: the refund rows above give wallet money back and reduce reward progress (trg_refund_cashback).

  PERFORM public.log_audit('order.cancel', 'pos', 'orders', _order_id, jsonb_build_object('status', _o.status),
    jsonb_build_object('status', 'cancelled', 'refunded', _given), _reason, _o.branch_id);
  RETURN _order_id;
END $$;

-- ---------------------------------------------------------------------
-- Remove a line. While the order is not final (open / pending on an open
-- shift) any cashier can remove lines without a manager; completed orders
-- still need the void permission and a reason.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.void_order_item(_order_item_id uuid, _reason text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _profile uuid := public.current_profile_id(); _oi public.order_items; _o public.orders;
  _before numeric; _after numeric; _active integer; _paid numeric := 0; _already numeric := 0; _over numeric := 0;
  _tax_share numeric := 0; _refund_id uuid; _draft boolean; _why text;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO _oi FROM public.order_items WHERE id = _order_item_id;
  IF _oi.id IS NULL THEN RAISE EXCEPTION 'Order line not found'; END IF;
  IF _oi.status = 'voided' THEN RAISE EXCEPTION 'This line is already voided'; END IF;
  SELECT * INTO _o FROM public.orders WHERE id = _oi.order_id FOR UPDATE;
  IF NOT public.can_access_branch(_o.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _o.status IN ('cancelled', 'refunded') THEN RAISE EXCEPTION 'Order is already closed'; END IF;

  _draft := _o.status IN ('open', 'pending')
            AND EXISTS (SELECT 1 FROM public.shifts s WHERE s.id = _o.shift_id AND s.status = 'open');
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

  _before := _o.total;
  UPDATE public.order_items SET status = 'voided', void_reason = _why WHERE id = _order_item_id;
  PERFORM public.return_line_stock(_order_item_id);
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
    INSERT INTO public.order_refunds (company_id, branch_id, order_id, shift_id, kind, amount, tax_amount, method_key, reason, origin, created_by)
    VALUES (_o.company_id, _o.branch_id, _o.id,
      public.refund_shift_for(_o, COALESCE((SELECT p.method_key FROM public.order_payments p WHERE p.order_id = _o.id ORDER BY p.amount DESC LIMIT 1), 'cash')),
      CASE WHEN _active = 0 THEN 'full' ELSE 'partial' END, _over, _tax_share,
      COALESCE((SELECT p.method_key FROM public.order_payments p WHERE p.order_id = _o.id ORDER BY p.amount DESC LIMIT 1), 'cash'),
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
    jsonb_build_object('order_total', _after, 'order_cancelled', _active = 0, 'auto_refund', _over, 'refund_id', _refund_id),
    _why, _o.branch_id);
  RETURN _order_item_id;
END $$;

REVOKE ALL ON FUNCTION public.shift_expected_cash(uuid), public.cancel_pos_order(uuid, text), public.void_order_item(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.shift_expected_cash(uuid), public.cancel_pos_order(uuid, text), public.void_order_item(uuid, text) TO authenticated;
REVOKE ALL ON FUNCTION public.trg_refund_adjusts_partner_tab() FROM PUBLIC, anon, authenticated;
