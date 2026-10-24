-- =====================================================================
-- "Revenue by payment method" cards: one rule for the orders tab and the
-- shifts tab, so the cards always add up to the revenue card.
--   Per method: what was paid on it − every amount handed back on it
--   (removed item, cancelled order or a refund), whatever the invoice was
--   paid with: paid by card and returned in cash = cash going out.
--   Partner tab: what is on the partner's account for the invoice (the
--   tab already shrinks when an item is removed).
-- Found 2026-10-24: revenue matched in all 42 shifts, but the cards did
-- not: the orders tab kept old removed-item money (10 shifts), both tabs
-- kept refunded money (4 shifts) and the partner card was always 0.
-- Display only; no data is changed.
-- =====================================================================
CREATE OR REPLACE FUNCTION public._tender_net(_order_ids uuid[])
RETURNS TABLE (k text, amt numeric, cnt bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  WITH pay AS (
    SELECT op.order_id, public.tender_key(op.method_key) k, SUM(op.amount) amt
      FROM public.order_payments op
     WHERE op.order_id = ANY (_order_ids)
     GROUP BY 1, 2
  ), back AS (
    -- Money handed back goes out on its own method (paid by card, returned in cash = cash out).
    -- Partner tabs shrink on their own when an item is removed, so they are left out here.
    SELECT r.order_id, public.tender_key(COALESCE(r.method_key, 'cash')) k, SUM(r.amount) amt
      FROM public.order_refunds r
     WHERE r.order_id = ANY (_order_ids) AND r.status = 'active'
       AND public.tender_key(COALESCE(r.method_key, 'cash')) <> 'partner_tab'
     GROUP BY 1, 2
  ), tab AS (
    SELECT pt.order_id, 'partner_tab'::text k, pt.total_amount amt
      FROM public.partner_tab_orders pt
     WHERE pt.order_id = ANY (_order_ids)
  ), lines AS (
    SELECT order_id, k, amt FROM pay
    UNION ALL SELECT order_id, k, -amt FROM back
    UNION ALL SELECT order_id, k, amt FROM tab
  ), per_order AS (
    SELECT order_id, k, SUM(amt) net FROM lines GROUP BY 1, 2
  )
  -- A transaction counts while something of it is left.
  SELECT k, round(SUM(net), 2), COUNT(*) FILTER (WHERE net > 0) FROM per_order GROUP BY 1
$$;
REVOKE EXECUTE ON FUNCTION public._tender_net(uuid[]) FROM PUBLIC, anon, authenticated;

DO $patch$
DECLARE _def text;
  _o1 text := $o$    FROM (SELECT p.k, round(SUM(p.paid - COALESCE(b.back, 0)), 2) v,
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
           GROUP BY 1) t;$o$;
  _n1 text := $n$    FROM (SELECT n.k, n.amt v, n.cnt c
            FROM public._tender_net(ARRAY(SELECT o.id FROM public.orders o WHERE o.shift_id = _s.id)) n) t;$n$;
  _o2 text := $o$    SELECT x.k, SUM(x.amt) AS amt, COUNT(*) FILTER (WHERE x.is_payment) AS cnt FROM (
      SELECT public.tender_key(p.method_key) AS k, p.amount AS amt, true AS is_payment
      FROM f JOIN order_payments p ON p.order_id = f.id
      WHERE f.status <> 'cancelled'
      UNION ALL
      -- Cancelled items after payment: as if never sold.
      SELECT public.tender_key(r.method_key), -r.amount, false
      FROM f JOIN order_refunds r ON r.order_id = f.id
      WHERE f.status <> 'cancelled' AND r.status = 'active' AND r.is_cancellation
        AND public.tender_key(r.method_key) <> 'partner_tab'
    ) x GROUP BY 1$o$;
  _n2 text := $n$    SELECT n.k, n.amt, n.cnt FROM public._tender_net(ARRAY(SELECT f.id FROM f)) n$n$;
BEGIN
  _def := pg_get_functiondef('public._shift_figures(public.shifts)'::regprocedure);
  IF position(_n1 IN _def) = 0 THEN
    IF position(_o1 IN _def) = 0 THEN RAISE EXCEPTION 'Expected text not found in _shift_figures'; END IF;
    EXECUTE replace(_def, _o1, _n1);
  END IF;
  _def := pg_get_functiondef('public.orders_period_summary(uuid, date, date, text, text, text, uuid, text)'::regprocedure);
  IF position(_n2 IN _def) = 0 THEN
    IF position(_o2 IN _def) = 0 THEN RAISE EXCEPTION 'Expected text not found in orders_period_summary'; END IF;
    EXECUTE replace(_def, _o2, _n2);
  END IF;
END $patch$;
