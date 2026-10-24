-- =====================================================================
-- Shift "revenue by payment method" counted every payment received, even
-- when the items were removed later and the money handed back. Example:
-- 261024-0001 paid 115 cash, both lines removed, 115 back -> the cash card
-- still showed 115 (1 txn) while revenue was 0.
-- Tenders now subtract money handed back for removed items / cancelled
-- orders (origin void or cancel) on the same method, per order. A payment
-- only counts as a transaction while something of it is left. Manual
-- refunds stay as they are (shown as refunds). Partner tabs have no
-- payments and are not touched. No data is changed.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.patch_fn(_sig regprocedure, _old text, _new text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE _def text := pg_get_functiondef(_sig);
BEGIN
  IF position(_new IN _def) > 0 THEN RAISE NOTICE '% already patched', _sig; RETURN; END IF;
  IF position(_old IN _def) = 0 THEN RAISE EXCEPTION 'Expected text not found in %: %', _sig, left(_old, 60); END IF;
  EXECUTE replace(_def, _old, _new);
END $$;

SELECT pg_temp.patch_fn('public._shift_figures(public.shifts)'::regprocedure,
$o$    FROM (SELECT public.tender_key(op.method_key) k, round(SUM(op.amount), 2) v, COUNT(*) c
            FROM public.orders o JOIN public.order_payments op ON op.order_id = o.id
           WHERE o.shift_id = _s.id   -- every payment received, whatever happened to the order later
           GROUP BY 1) t;$o$,
$n$    FROM (SELECT p.k, round(SUM(p.paid - COALESCE(b.back, 0)), 2) v,
                 COUNT(*) FILTER (WHERE p.paid - COALESCE(b.back, 0) > 0) c
            FROM (SELECT o.id, public.tender_key(op.method_key) k, SUM(op.amount) paid
                    FROM public.orders o JOIN public.order_payments op ON op.order_id = o.id
                   WHERE o.shift_id = _s.id
                   GROUP BY 1, 2) p
            -- Money handed back for removed items / cancelled orders: as if never sold.
            LEFT JOIN (SELECT r.order_id, public.tender_key(COALESCE(r.method_key, 'cash')) k, SUM(r.amount) back
                         FROM public.order_refunds r JOIN public.orders o ON o.id = r.order_id
                        WHERE o.shift_id = _s.id AND r.status = 'active' AND r.origin IN ('void', 'cancel')
                        GROUP BY 1, 2) b ON b.order_id = p.id AND b.k = p.k
           GROUP BY 1) t;$n$);
