-- =====================================================================
-- Money ledger, step 1 (ADR 0002): the drawer has ONE definition.
--
--   expected drawer = opening cash + every cash payment of the shift's invoices
--                     − every cash refund paid from the shift − drawer expenses
--
-- Until now four functions each wrote this formula themselves
-- (_finalize_shift_close, shift_expected_cash, _shift_figures, live_position),
-- and an older copy inside the force close left cancelled invoices out, which
-- is how the 6–8 Oct shifts reached the treasury wrong. They now all ask
-- _shift_drawer. Same numbers today; one place to change tomorrow.
--
-- Also: the close-shift screen's "sales" figure (shift_expected_cash.sales_total)
-- was SUM(invoice totals) with no refunds or cashback taken off, so it did not
-- match the shift report. It now returns the shift report's net sales.
-- Live text patches; nothing else in these functions changes.
-- =====================================================================
CREATE OR REPLACE FUNCTION public._shift_drawer(_s public.shifts)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  WITH x AS (
    SELECT
      (SELECT COALESCE(SUM(p.amount), 0) FROM public.orders o JOIN public.order_payments p ON p.order_id = o.id
        WHERE o.shift_id = _s.id AND p.method_key = 'cash') AS cash_in,
      (SELECT COALESCE(SUM(r.amount), 0) FROM public.order_refunds r
        WHERE r.shift_id = _s.id AND r.status = 'active' AND COALESCE(r.method_key, 'cash') = 'cash') AS cash_out,
      public.shift_expense_total(_s.id) AS exp)
  SELECT jsonb_build_object('opening_cash', _s.opening_cash, 'cash_in', cash_in, 'cash_refunds', cash_out,
           'expenses', exp, 'expected', round(_s.opening_cash + cash_in - cash_out - exp, 2))
    FROM x
$$;
REVOKE EXECUTE ON FUNCTION public._shift_drawer(public.shifts) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._shift_drawer(public.shifts) TO service_role;

CREATE OR REPLACE FUNCTION pg_temp.patch_fn(_sig regprocedure, _old text, _new text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE _def text := pg_get_functiondef(_sig);
BEGIN
  IF position(_new IN _def) > 0 THEN RAISE NOTICE '% already patched', _sig; RETURN; END IF;
  IF position(_old IN _def) = 0 THEN RAISE EXCEPTION 'Expected text not found in %: %', _sig, left(_old, 60); END IF;
  IF position(_old IN substr(_def, position(_old IN _def) + 1)) > 0 THEN
    RAISE EXCEPTION 'Anchor appears more than once in %', _sig;
  END IF;
  EXECUTE replace(_def, _old, _new);
END $$;

-- a) closing a shift
SELECT pg_temp.patch_fn('public._finalize_shift_close(uuid, numeric, numeric, text, uuid, text, text, uuid)'::regprocedure,
$o$  SELECT COALESCE(SUM(p.amount), 0) INTO _cash_in
    FROM public.orders o JOIN public.order_payments p ON p.order_id = o.id
   WHERE o.shift_id = _s.id AND p.method_key = 'cash';  -- all cash received; refunds (incl. cancellations) are subtracted below
  SELECT COALESCE(SUM(r.amount), 0) INTO _cash_out
    FROM public.order_refunds r
   WHERE r.shift_id = _s.id AND r.status = 'active' AND COALESCE(r.method_key, 'cash') = 'cash';
  _exp := public.shift_expense_total(_s.id);
  _expected := round(_s.opening_cash + _cash_in - _cash_out - _exp, 2);$o$,
$n$  -- The drawer has one definition: _shift_drawer.
  _fig := public._shift_drawer(_s);
  _cash_in := (_fig->>'cash_in')::numeric; _cash_out := (_fig->>'cash_refunds')::numeric;
  _exp := (_fig->>'expenses')::numeric; _expected := (_fig->>'expected')::numeric;$n$);

-- b) the close-shift preview
SELECT pg_temp.patch_fn('public.shift_expected_cash(uuid)'::regprocedure,
$o$_orders integer := 0; _exp numeric := 0;$o$,
$n$_orders integer := 0; _exp numeric := 0; _d jsonb;$n$);
SELECT pg_temp.patch_fn('public.shift_expected_cash(uuid)'::regprocedure,
$o$  SELECT COALESCE(SUM(p.amount), 0) INTO _cash_in
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
    'expected_cash', round(_s.opening_cash + _cash_in - _cash_out - _exp, 2),$o$,
$n$  _d := public._shift_drawer(_s);
  _cash_in := (_d->>'cash_in')::numeric; _cash_out := (_d->>'cash_refunds')::numeric; _exp := (_d->>'expenses')::numeric;
  -- Net sales from the same shift figures as the close report (after refunds and cashback).
  _sales := (public._shift_figures(_s)->>'netSales')::numeric;
  SELECT count(*) INTO _orders FROM public.orders o WHERE o.shift_id = _shift_id AND o.status NOT IN ('cancelled', 'open');
  RETURN jsonb_build_object(
    'opening_cash', _s.opening_cash, 'cash_in', _cash_in, 'cash_refunds', _cash_out, 'shift_expenses', _exp,
    'expected_cash', (_d->>'expected')::numeric,$n$);

-- c) the shift report
SELECT pg_temp.patch_fn('public._shift_figures(shifts)'::regprocedure,
$o$                    ELSE _s.opening_cash + COALESCE((_tenders->>'cash')::numeric, 0) - _cash_ref - _exp END;$o$,
$n$                    ELSE (public._shift_drawer(_s)->>'expected')::numeric END;$n$);

-- d) the live position panel
SELECT pg_temp.patch_fn('public.live_position()'::regprocedure,
$o$      'drawer_now', round(s.opening_cash + x.cash_in - x.cash_out - x.exp, 2),$o$,
$n$      'drawer_now', (public._shift_drawer(s)->>'expected')::numeric,$n$);
