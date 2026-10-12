CREATE TYPE public.kitchen_status AS ENUM ('queued','preparing','ready','served');

ALTER TABLE public.orders
  ADD COLUMN kitchen_status public.kitchen_status NOT NULL DEFAULT 'queued',
  ADD COLUMN kitchen_ready_at timestamptz,
  ADD COLUMN kitchen_served_at timestamptz;

CREATE INDEX IF NOT EXISTS orders_kitchen_status_idx ON public.orders (branch_id, kitchen_status, created_at);

CREATE OR REPLACE FUNCTION public.set_kitchen_status(_order_id uuid, _status public.kitchen_status)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _order public.orders;
BEGIN
  SELECT * INTO _order FROM public.orders WHERE id = _order_id;
  IF _order.id IS NULL THEN
    RAISE EXCEPTION 'Order not found';
  END IF;
  IF NOT public.can_access_branch(_order.branch_id) THEN
    RAISE EXCEPTION 'No access to this branch';
  END IF;
  IF NOT (public.has_permission('kitchen.view') OR public.has_permission('pos.create_order') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Permission denied';
  END IF;
  IF _order.status = 'cancelled' THEN
    RAISE EXCEPTION 'Order is cancelled';
  END IF;

  UPDATE public.orders
     SET kitchen_status = _status,
         kitchen_ready_at = CASE WHEN _status = 'ready' THEN now() ELSE kitchen_ready_at END,
         kitchen_served_at = CASE WHEN _status = 'served' THEN now() ELSE kitchen_served_at END,
         updated_at = now()
   WHERE id = _order_id;

  PERFORM public.log_audit('kitchen_status_change', 'kitchen', 'order', _order_id,
    jsonb_build_object('kitchen_status', _order.kitchen_status),
    jsonb_build_object('kitchen_status', _status), NULL, _order.branch_id);

  RETURN _order_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_kitchen_status(uuid, public.kitchen_status) TO authenticated;