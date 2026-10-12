DO $$
DECLARE _def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO _def
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'create_pos_order';

  IF _def IS NULL THEN
    RAISE EXCEPTION 'create_pos_order not found';
  END IF;

  -- The internal temp-table cleanup lacked a WHERE clause, which the
  -- database rejects in safe-update mode and blocked every combo sale.
  _def := replace(_def, 'FROM _bundle_grp;', 'FROM _bundle_grp WHERE true;');
  EXECUTE _def;
END $$;