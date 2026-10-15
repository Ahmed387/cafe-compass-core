-- =====================================================================
-- Orders close on payment (owner decision 2026-10-15).
-- create_pos_order only accepts a fully paid order (or a partner tab), so the
-- order is completed the moment it is created. There is no "pending delivery"
-- step any more; after payment a change is a partial or full refund.
-- Applied to the live function text; nothing else in it changes.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.patch_fn(_sig regprocedure, _old text, _new text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE _def text := pg_get_functiondef(_sig);
BEGIN
  IF position(_new IN _def) > 0 THEN RAISE NOTICE '% already patched', _sig; RETURN; END IF;
  IF position(_old IN _def) = 0 THEN RAISE EXCEPTION 'Expected text not found in %, aborting', _sig; END IF;
  EXECUTE replace(_def, _old, _new);
END $$;

SELECT pg_temp.patch_fn(p.oid::regprocedure,
$o$  PERFORM public.log_audit('order.create','pos','orders',_order,NULL,$o$,
$n$  -- Paid in full (or charged to a partner tab): the order is done.
  UPDATE public.orders SET status = 'completed', completed_at = COALESCE(completed_at, now()), updated_at = now()
   WHERE id = _order AND status = 'pending';

  PERFORM public.log_audit('order.create','pos','orders',_order,NULL,$n$)
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'create_pos_order';

-- Orders still waiting today (open shift) are completed now as well.
UPDATE public.orders o SET status = 'completed', completed_at = COALESCE(o.completed_at, now()), updated_at = now()
 WHERE o.status = 'pending'
   AND COALESCE((SELECT SUM(p.amount) FROM public.order_payments p WHERE p.order_id = o.id), 0) >= o.total;

-- Partner-tab orders are charged to the partner, so they are done too.
UPDATE public.orders o SET status = 'completed', completed_at = COALESCE(o.completed_at, now()), updated_at = now()
 WHERE o.status = 'pending' AND EXISTS (SELECT 1 FROM public.partner_tab_orders t WHERE t.order_id = o.id);
