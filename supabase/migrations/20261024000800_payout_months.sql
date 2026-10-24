-- Profit payouts by month. The super admin can pay out chosen months, so
-- payout_history now also lists every month from the first business day
-- to today with its revenue and net profit; the profit tab shows which
-- months were paid out and starts the next payout at the earliest unpaid
-- month. Display only.
CREATE OR REPLACE FUNCTION public._payout_month_figures(_company uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE _first date; _today date := public.business_today(_company); _m date; _s date; _e date; _p jsonb;
  _out jsonb := '[]'::jsonb;
BEGIN
  SELECT LEAST(
      (SELECT min(s.business_date) FROM public.shifts s WHERE s.company_id = _company),
      (SELECT min(o.business_date) FROM public.orders o WHERE o.company_id = _company),
      (SELECT min(e.expense_date) FROM public.expenses e WHERE e.company_id = _company AND e.status = 'active'),
      (SELECT min(p.purchase_date) FROM public.purchases p WHERE p.company_id = _company AND p.status <> 'cancelled'))
    INTO _first;
  IF _first IS NULL OR _first > _today THEN RETURN _out; END IF;
  FOR _m IN SELECT generate_series(date_trunc('month', _first), date_trunc('month', _today), interval '1 month')::date LOOP
    _s := GREATEST(_m, _first);
    _e := LEAST((_m + interval '1 month - 1 day')::date, _today);
    _p := public._range_pnl(_company, _s, _e);
    _out := _out || jsonb_build_array(jsonb_build_object(
      'month', to_char(_m, 'YYYY-MM'), 'start', _s, 'end', _e,
      'revenue', _p->'revenue', 'net_profit', _p->'net_profit', 'payroll', _p->'payroll_total'));
  END LOOP;
  RETURN _out;
END $function$;
REVOKE EXECUTE ON FUNCTION public._payout_month_figures(uuid) FROM PUBLIC, anon, authenticated;

DO $patch$
DECLARE _def text;
  _o text := $o$p.status <> 'cancelled'))));$o$;
  _n text := $n$p.status <> 'cancelled'))),
    'months', public._payout_month_figures(_company));$n$;
BEGIN
  _def := pg_get_functiondef('public.payout_history(integer)'::regprocedure);
  IF position(_n IN _def) = 0 THEN
    IF position(_o IN _def) = 0 THEN RAISE EXCEPTION 'Expected text not found in payout_history'; END IF;
    EXECUTE replace(_def, _o, _n);
  END IF;
END $patch$;
