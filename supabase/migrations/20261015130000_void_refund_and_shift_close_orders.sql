-- =====================================================================
-- Two order-lifecycle fixes found in the live data audit (2026-10-15).
--
-- 1) Removing a 2nd/3rd line from a paid invoice refunded too little.
--    void_order_item computed  LEAST(paid, total_before) − already_refunded − total_after.
--    total_before already excludes earlier removed lines, so earlier refunds were
--    subtracted twice. Example: paid 275, remove 30 then 85 → the 85 line only
--    refunded 55. When the last line went, the rest of the money was never
--    returned and the cancelled order kept it (9 orders, 780 EGP).
--    Now: refund = what was paid − what was already refunded − what still remains.
--
-- 2) Closing a shift left its paid orders "pending" forever (43 orders from
--    shift #26). Pending orders cannot be refunded later and look unfinished.
--    Now: closing a shift marks its fully-paid pending orders as completed.
--
-- Both are applied to the LIVE function text; nothing else in them changes.
-- No order is deleted (orders are protected by trigger t_orders_no_delete).
-- =====================================================================

CREATE OR REPLACE FUNCTION pg_temp.patch_fn(_sig regprocedure, _old text, _new text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE _def text := pg_get_functiondef(_sig);
BEGIN
  IF position(_new IN _def) > 0 THEN RAISE NOTICE '% already patched', _sig; RETURN; END IF;
  IF position(_old IN _def) = 0 THEN RAISE EXCEPTION 'Expected text not found in %, aborting', _sig; END IF;
  EXECUTE replace(_def, _old, _new);
END $$;

SELECT pg_temp.patch_fn('public.void_order_item(uuid, text, boolean, text, uuid)'::regprocedure,
$o$  _over := round(LEAST(_paid, _before) - _already - COALESCE(_after, 0), 2);$o$,
$n$  -- Money paid, minus refunds already given, minus what the invoice still costs.
  _over := round(GREATEST(_paid - _already - COALESCE(_after, 0), 0), 2);$n$);

SELECT pg_temp.patch_fn('public._finalize_shift_close(uuid, numeric, numeric, text, uuid, text, text, uuid)'::regprocedure,
$o$  -- Treasury gets exactly the cash that physically left the drawer.$o$,
$n$  -- Paid orders still "pending" when the shift ends were served: complete them so
  -- they can be refunded later and don't look unfinished.
  UPDATE public.orders o SET status = 'completed', completed_at = COALESCE(o.completed_at, _closed_at), updated_at = now()
   WHERE o.shift_id = _s.id AND o.status = 'pending'
     AND COALESCE((SELECT SUM(p.amount) FROM public.order_payments p WHERE p.order_id = o.id), 0) >= o.total;

  -- Treasury gets exactly the cash that physically left the drawer.$n$);
