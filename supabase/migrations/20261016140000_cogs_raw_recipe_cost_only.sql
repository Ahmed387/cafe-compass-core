-- =====================================================================
-- Sale cost = raw recipe cost, always (owner decision 2026-10-16, ADR 0001).
-- Lines sold before per-item waste existed (18 Sep – 12 Oct, 1,362 lines)
-- were still charged a flat 5% extra in every P&L. Waste never enters the
-- drink's cost: real loss reaches profit once, through the stocktake.
-- The accounting period is still open, so this is allowed.
-- Also removes the same 5% from the restocked-refund fallbacks in the live
-- _range_pnl and _shift_figures (text patch; nothing else in them changes).
-- =====================================================================
CREATE OR REPLACE FUNCTION public.line_cogs(_oi order_items)
RETURNS numeric LANGUAGE sql IMMUTABLE SET search_path TO 'public' AS $$
  SELECT COALESCE(_oi.quantity, 0) * COALESCE(_oi.unit_cost, 0)
$$;

CREATE OR REPLACE FUNCTION pg_temp.patch_fn(_sig regprocedure, _old text, _new text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE _def text := pg_get_functiondef(_sig);
BEGIN
  IF position(_old IN _def) = 0 THEN RAISE NOTICE '% already patched', _sig; RETURN; END IF;
  IF position(_old IN substr(_def, position(_old IN _def) + 1)) > 0 THEN
    RAISE EXCEPTION 'Anchor appears more than once in %', _sig;
  END IF;
  EXECUTE replace(_def, _old, _new);
END $$;

SELECT pg_temp.patch_fn('public._range_pnl(uuid, date, date)'::regprocedure,
  $o$COALESCE((e->>'unit_cost')::numeric, 0) * 1.05)$o$, $n$COALESCE((e->>'unit_cost')::numeric, 0))$n$);
SELECT pg_temp.patch_fn('public._shift_figures(shifts)'::regprocedure,
  $o$COALESCE((e->>'unit_cost')::numeric, 0) * 1.05)$o$, $n$COALESCE((e->>'unit_cost')::numeric, 0))$n$);
