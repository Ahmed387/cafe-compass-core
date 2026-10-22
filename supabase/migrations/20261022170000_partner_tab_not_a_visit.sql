-- =====================================================================
-- Owner rule (2026-10-22): when a partner takes something on their tab, that is
-- "a partner with an invoice on their account", never a customer visit. Until
-- now create_pos_order added the tab invoice to the linked customer's visits and
-- total spent (cashback and stamps were already skipped for tab invoices).
-- Fix: the visits / total_spent update skips partner-tab invoices.
-- No existing data is changed.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.patch_fn(_sig regprocedure, _old text, _new text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE _def text := replace(pg_get_functiondef(_sig), E'\r', '');
BEGIN
  IF position(_new IN _def) > 0 THEN RAISE NOTICE '% already patched', _sig; RETURN; END IF;
  IF position(_old IN _def) = 0 THEN RAISE EXCEPTION 'Expected text not found in %: %', _sig, left(_old, 60); END IF;
  IF position(_old IN substr(_def, position(_old IN _def) + 1)) > 0 THEN
    RAISE EXCEPTION 'Anchor appears more than once in %', _sig;
  END IF;
  EXECUTE replace(_def, _old, _new);
END $$;

SELECT pg_temp.patch_fn(
  'public.create_pos_order(uuid, jsonb, jsonb, order_type, numeric, text, text, text, text, uuid, text, uuid, boolean)'::regprocedure,
$o$           last_visit_at = now(), updated_at = now()
     WHERE id = _cust;$o$,
$n$           last_visit_at = now(), updated_at = now()
     WHERE id = _cust AND NOT _tab;$n$);
