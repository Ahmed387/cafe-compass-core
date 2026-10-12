DO $$
DECLARE _def text; _new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO _def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'create_pos_order';
  IF _def IS NULL THEN RAISE EXCEPTION 'create_pos_order not found'; END IF;

  -- 1) Partner tab: skip bundle pricing entirely instead of rejecting the order.
  _new := replace(
    _def,
    'IF _tab THEN RAISE EXCEPTION ''Partner tab orders cannot include promotional bundles''; END IF;',
    'IF _tab THEN CONTINUE; END IF;  -- partner tab: unpack bundle at full retail menu prices'
  );
  IF _new = _def THEN RAISE EXCEPTION 'bundle guard not found'; END IF;
  _def := _new;

  -- 2) Item loop: drop the bundle key on partner tab lines so they price at full base price.
  _new := replace(
    _def,
    E'    _bkey := NULLIF(_item->>''bundle_key'','''');\n    _oid := NULL;\n    _offer := NULL;',
    E'    _bkey := NULLIF(_item->>''bundle_key'','''');\n    IF _tab THEN _bkey := NULL; END IF;\n    _oid := NULL;\n    _offer := NULL;'
  );
  IF _new = _def THEN RAISE EXCEPTION 'item loop bundle key assignment not found'; END IF;

  EXECUTE _new;
END $$;