-- Nothing has ever been paid out, so the profit waiting to be distributed
-- starts on the first business day, not on the 1st of this month
-- (September's profit was being left out). payout_history now returns
-- that day; the client uses it until the first payout. Display only.
DO $patch$
DECLARE _def text;
  _o text := $o$  RETURN jsonb_build_object('payouts', _out, 'development_fund_balance', public.development_fund_balance());$o$;
  _n text := $n$  RETURN jsonb_build_object('payouts', _out, 'development_fund_balance', public.development_fund_balance(),
    'first_business_day', (SELECT LEAST(
        (SELECT min(s.business_date) FROM public.shifts s WHERE s.company_id = _company),
        (SELECT min(o.business_date) FROM public.orders o WHERE o.company_id = _company),
        (SELECT min(e.expense_date) FROM public.expenses e WHERE e.company_id = _company AND e.status = 'active'),
        (SELECT min(p.purchase_date) FROM public.purchases p WHERE p.company_id = _company AND p.status <> 'cancelled'))));$n$;
BEGIN
  _def := pg_get_functiondef('public.payout_history(integer)'::regprocedure);
  IF position(_n IN _def) = 0 THEN
    IF position(_o IN _def) = 0 THEN RAISE EXCEPTION 'Expected text not found in payout_history'; END IF;
    EXECUTE replace(_def, _o, _n);
  END IF;
END $patch$;
