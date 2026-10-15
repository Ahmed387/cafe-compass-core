-- =====================================================================
-- Fix: a removed invoice line was deducted from revenue twice.
--
-- void_order_item() drops the line from orders.total / active lines AND records
-- an automatic refund (origin = 'void') for the money handed back. Revenue was
-- built from active lines (or orders.total) and then subtracted every refund,
-- so the removed line came off twice (client report: shift #26 showed 10350
-- instead of 10415).
--
-- Rule after this migration:
--   Revenue = active lines − manual/cancel refunds of non-cancelled orders
--   Drawer  = all payments − all refunds (void refunds included: cash left the drawer)
--
-- The patch is applied to each function's LIVE definition: only the refund
-- filter text changes, so newer edits made elsewhere are preserved. If the
-- expected text is not found the migration aborts and changes nothing.
-- No table data is touched.
-- =====================================================================

CREATE OR REPLACE FUNCTION pg_temp.patch_fn(_sig regprocedure, _old text, _new text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE _def text := pg_get_functiondef(_sig);
BEGIN
  IF position(_new IN _def) > 0 THEN
    RAISE NOTICE '% already patched', _sig; RETURN;
  END IF;
  IF position(_old IN _def) = 0 THEN
    RAISE EXCEPTION 'Expected text not found in %, aborting', _sig;
  END IF;
  EXECUTE replace(_def, _old, _new);
END $$;

-- Shift figures: refunds that cut revenue skip 'void' (drawer cash refunds unchanged).
SELECT pg_temp.patch_fn('public._shift_figures(public.shifts)'::regprocedure,
$o$  SELECT COALESCE(SUM(r.amount) FILTER (WHERE o.status <> 'cancelled'), 0),
         COALESCE(SUM(r.tax_amount) FILTER (WHERE o.status <> 'cancelled'), 0),
         COALESCE(SUM(r.amount) FILTER (WHERE o.status <> 'cancelled' AND COALESCE(r.fault, r.origin) IN ('staff', 'all_staff')), 0),$o$,
$n$  -- 'void' refunds belong to lines already removed from the sale: cash only, not revenue.
  SELECT COALESCE(SUM(r.amount) FILTER (WHERE o.status <> 'cancelled' AND COALESCE(r.origin, 'manual') <> 'void'), 0),
         COALESCE(SUM(r.tax_amount) FILTER (WHERE o.status <> 'cancelled' AND COALESCE(r.origin, 'manual') <> 'void'), 0),
         COALESCE(SUM(r.amount) FILTER (WHERE o.status <> 'cancelled' AND COALESCE(r.origin, 'manual') <> 'void' AND COALESCE(r.fault, r.origin) IN ('staff', 'all_staff')), 0),$n$);

-- Date-range P&L (also feeds profit payouts).
SELECT pg_temp.patch_fn('public._range_pnl(uuid, date, date)'::regprocedure,
$o$    INTO _refunds, _refund_tax
    FROM public.order_refunds r JOIN public.orders o ON o.id = r.order_id
   WHERE r.company_id = _company AND r.status = 'active' AND o.status <> 'cancelled'
     AND r.created_at >= _t0 AND r.created_at < _t1;$o$,
$n$    INTO _refunds, _refund_tax
    FROM public.order_refunds r JOIN public.orders o ON o.id = r.order_id
   WHERE r.company_id = _company AND r.status = 'active' AND o.status <> 'cancelled'
     AND COALESCE(r.origin, 'manual') <> 'void'
     AND r.created_at >= _t0 AND r.created_at < _t1;$n$);

-- Orders page summary (sales = total − refunds per invoice).
SELECT pg_temp.patch_fn('public.orders_period_summary(uuid, date, date, text, text, text, uuid, text)'::regprocedure,
$o$x.order_id=f.id AND x.status='active'),0)$o$,
$n$x.order_id=f.id AND x.status='active' AND COALESCE(x.origin,'manual') <> 'void'),0)$n$);

-- Reports: refunds total (revenue there is SUM(orders.total) of non-cancelled orders).
SELECT pg_temp.patch_fn('public.sales_period_summary(date, date, uuid)'::regprocedure,
$o$    AND r.status = 'active'
    AND r.created_at::date BETWEEN _from AND _to;$o$,
$n$    AND r.status = 'active'
    AND o.status <> 'cancelled' AND COALESCE(r.origin, 'manual') <> 'void'
    AND r.created_at::date BETWEEN _from AND _to;$n$);
