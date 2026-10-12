CREATE OR REPLACE FUNCTION public.cancel_pos_order(_order_id uuid, _reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _o public.orders;
  _earned integer := 0;
  _bal integer;
BEGIN
  SELECT * INTO _o FROM public.orders WHERE id = _order_id;
  IF _o.id IS NULL THEN RAISE EXCEPTION 'Order not found'; END IF;
  IF _o.status = 'cancelled' THEN RAISE EXCEPTION 'Order already cancelled'; END IF;
  IF _o.status IN ('completed','partially_refunded','refunded') THEN
    RAISE EXCEPTION 'لا يمكن إلغاء طلب مكتمل أو مسترجع. يرجى استخدام مسار الاسترجاع (Refund) لتحديد مصير المخزون والنقدية.';
  END IF;
  IF _o.status NOT IN ('pending','open') THEN
    RAISE EXCEPTION 'لا يمكن إلغاء هذا الطلب في حالته الحالية';
  END IF;
  IF NOT (public.has_permission('pos.cancel_order') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF NOT public.can_access_branch(_o.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _reason IS NULL OR length(trim(_reason)) < 3 THEN RAISE EXCEPTION 'A cancellation reason is required'; END IF;

  UPDATE public.orders SET status = 'cancelled', cancel_reason = _reason, cancelled_at = now() WHERE id = _order_id;
  -- stock restore happens in trigger t_orders_return_stock (before items are voided)
  UPDATE public.order_items SET status = 'voided', void_reason = _reason WHERE order_id = _order_id;

  -- reverse loyalty points earned on this order (if any)
  IF _o.customer_id IS NOT NULL THEN
    SELECT COALESCE(SUM(points),0) INTO _earned
    FROM public.customer_points_transactions
    WHERE order_id = _order_id AND points > 0;

    IF _earned > 0 THEN
      UPDATE public.customers
      SET points_balance = GREATEST(points_balance - _earned, 0)
      WHERE id = _o.customer_id
      RETURNING points_balance INTO _bal;

      INSERT INTO public.customer_points_transactions
        (company_id, customer_id, order_id, kind, points, balance_after, description, created_by)
      VALUES (_o.company_id, _o.customer_id, _order_id, 'adjust', -_earned, COALESCE(_bal,0),
              'إلغاء طلب: ' || btrim(_reason), public.current_profile_id());
    END IF;
  END IF;

  PERFORM public.log_audit('order.cancel','pos','orders',_order_id,
    jsonb_build_object('status',_o.status),
    jsonb_build_object('status','cancelled','points_reversed',_earned,'cash_reversed',_o.total),
    _reason,_o.branch_id);
  RETURN _order_id;
END $function$;