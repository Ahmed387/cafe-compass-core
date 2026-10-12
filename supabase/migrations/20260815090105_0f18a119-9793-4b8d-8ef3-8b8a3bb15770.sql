CREATE OR REPLACE FUNCTION public.return_stock_on_cancel()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE _r record;
BEGIN
  IF NEW.status = 'cancelled' AND OLD.status <> 'cancelled' THEN
    FOR _r IN
      SELECT sm.item_id, sm.quantity, sm.branch_id FROM public.stock_movements sm
      JOIN public.order_items oi ON oi.id = sm.reference_id
      WHERE sm.reference_type = 'order_item' AND sm.movement_type = 'sale_consumption'
        AND oi.order_id = NEW.id AND oi.status = 'active'
    LOOP
      PERFORM public.apply_stock_movement(_r.branch_id, _r.item_id, 'sale_return', -_r.quantity, NULL,
        'Order cancelled', 'order', NEW.id);
    END LOOP;
  END IF;
  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.void_order_item(_order_item_id uuid, _reason text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE _profile uuid := public.current_profile_id(); _oi public.order_items; _o public.orders;
  _before numeric; _after numeric; _active integer;
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
    jsonb_build_object('order_total',_after,'order_cancelled', _active = 0), _reason, _o.branch_id);
  RETURN _order_item_id;
END $function$;