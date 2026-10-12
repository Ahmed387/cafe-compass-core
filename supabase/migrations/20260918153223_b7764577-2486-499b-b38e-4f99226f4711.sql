DO $$
DECLARE _def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO _def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'sales_period_summary';

  IF _def IS NULL THEN RAISE EXCEPTION 'sales_period_summary not found'; END IF;

  _def := replace(
    _def,
    '''pending'',''completed'',''refunded''',
    '''pending'',''completed'',''refunded'',''partially_refunded'''
  );
  EXECUTE _def;
END $$;