-- Renaming a partner without sending a share wiped profit_share_percentage
-- (found on 2026-10-15: one partner had NULL share, so their own statement
-- showed no share). Keep the existing share when none is given, and restore
-- shares from capital (the documented rule).
CREATE OR REPLACE FUNCTION pg_temp.patch_fn(_sig regprocedure, _old text, _new text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE _def text := pg_get_functiondef(_sig);
BEGIN
  IF position(_new IN _def) > 0 THEN RAISE NOTICE '% already patched', _sig; RETURN; END IF;
  IF position(_old IN _def) = 0 THEN RAISE EXCEPTION 'Expected text not found in %, aborting', _sig; END IF;
  EXECUTE replace(_def, _old, _new);
END $$;

SELECT pg_temp.patch_fn('public.update_partner_details(uuid, text, numeric)'::regprocedure,
$o$profit_share_percentage=_profit_share_percentage, updated_at=now()$o$,
$n$profit_share_percentage=COALESCE(_profit_share_percentage, profit_share_percentage), updated_at=now()$n$);

SELECT public.recompute_capital_equity(c.id) FROM public.companies c;
