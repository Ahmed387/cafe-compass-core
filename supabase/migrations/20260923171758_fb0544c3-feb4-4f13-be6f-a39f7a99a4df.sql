DO $$
DECLARE d text;
BEGIN
  d := pg_get_functiondef('public.distribute_period_profit(uuid)'::regprocedure);
  d := replace(d, 'FROM public.period_partner_shares WHERE period_id=_period_id ORDER BY partner_id LOOP',
                  'FROM public.period_partner_shares WHERE period_id=_period_id ORDER BY (partner_id=_last), partner_id LOOP');
  IF d !~ 'ORDER BY \(partner_id=_last\)' THEN RAISE EXCEPTION 'patch failed'; END IF;
  EXECUTE d;
END $$;