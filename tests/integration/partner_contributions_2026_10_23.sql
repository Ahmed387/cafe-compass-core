-- =====================================================================
-- Partner contributions test (2026-10-23): capital vs loan, shares from the
-- 1st of next month, split payouts, loan repayment, manual edits, warning.
-- Runs on the real "20s" database in ONE transaction that ends in ROLLBACK.
-- =====================================================================
BEGIN;

CREATE TEMP TABLE _results (n serial, step text, ok boolean, detail text) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.act_as(_role_key text) RETURNS boolean LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', up.auth_user_id, 'role', 'authenticated')::text, true) IS NOT NULL
    FROM public.user_profiles up
    JOIN public.user_roles ur ON ur.user_id = up.id
    JOIN public.roles r ON r.id = ur.role_id
   WHERE r.key = _role_key AND up.is_active AND up.auth_user_id IS NOT NULL
   ORDER BY up.created_at LIMIT 1
$$;
CREATE OR REPLACE FUNCTION pg_temp.ok(_step text, _ok boolean, _detail text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$
  INSERT INTO _results (step, ok, detail) VALUES (_step, COALESCE(_ok, false), _detail)
$$;
CREATE OR REPLACE FUNCTION pg_temp.pid(_name text) RETURNS uuid LANGUAGE sql AS $$
  SELECT id FROM public.partners WHERE name = _name AND company_id = public.current_company_id()
$$;
CREATE OR REPLACE FUNCTION pg_temp.pct(_name text) RETURNS numeric LANGUAGE sql AS $$
  SELECT profit_share_percentage FROM public.partners WHERE id = pg_temp.pid(_name)
$$;
CREATE OR REPLACE FUNCTION pg_temp.at(_name text, _d date) RETURNS numeric LANGUAGE sql AS $$
  SELECT COALESCE((SELECT pct FROM public._partner_shares_at(public.current_company_id(), _d) WHERE partner_id = pg_temp.pid(_name)), 0)
$$;

SELECT pg_temp.act_as('super_admin');

DO $$
DECLARE
  _co uuid := public.current_company_id(); _today date; _id uuid; _x uuid; _y uuid; _l uuid;
  _pv jsonb; _c jsonb; _n numeric; _m numeric; _txt text; _sep numeric; _oct numeric; _exp numeric;
  _dist uuid; _seg jsonb;
BEGIN
  IF public.current_profile_id() IS NULL THEN RAISE EXCEPTION 'setup: no super admin'; END IF;
  _today := public.business_today(_co);

  -- 1. Migration changes nothing on its own.
  PERFORM pg_temp.ok('1 shares unchanged after migration',
    pg_temp.pct('احمد حافظ') = 10 AND pg_temp.pct('مهند') = 25 AND pg_temp.pct('حسام عبد الغني') = 20,
    (SELECT string_agg(name || '=' || profit_share_percentage, ', ') FROM public.partners WHERE company_id = _co));
  PERFORM pg_temp.ok('1b no manual snapshot created', NOT EXISTS (SELECT 1 FROM public.partner_share_snapshots WHERE company_id = _co));
  PERFORM pg_temp.ok('1c old contributions count from their date',
    NOT EXISTS (SELECT 1 FROM public.partner_capital_contributions WHERE effective_from <> contribution_date OR kind <> 'capital'));
  PERFORM pg_temp.ok('1d shares-at today = partners', pg_temp.at('مهند', _today) = 25 AND pg_temp.at('ميدو', _today) = 15);

  -- 2. Backdated capital: مهند +250k on 10/09 → counts from 1/10 (already in force).
  _x := public.record_partner_contribution(pg_temp.pid('مهند'), 250000, 'capital', '2026-09-10');
  PERFORM pg_temp.ok('2 effective from 1st of next month',
    (SELECT effective_from FROM public.partner_capital_contributions WHERE id = _x) = '2026-10-01');
  PERFORM pg_temp.ok('2b today shares updated (40 / 8)', pg_temp.pct('مهند') = 40 AND pg_temp.pct('احمد حافظ') = 8,
    pg_temp.pct('مهند') || ' / ' || pg_temp.pct('احمد حافظ'));
  PERFORM pg_temp.ok('2c September keeps old shares', pg_temp.at('مهند', '2026-09-30') = 25 AND pg_temp.at('مهند', '2026-10-01') = 40);
  PERFORM pg_temp.ok('2d capital ledger entry', EXISTS (SELECT 1 FROM public.partner_ledger_transactions
    WHERE reference_id = _x AND transaction_type = 'capital_contribution' AND amount = 250000));

  -- 3. Split payout Sep 1 → Oct 21: Sep with old shares, Oct with new.
  _c := public._payout_calc(_co, '2026-09-01', '2026-10-21', 0);
  _sep := (public._range_pnl(_co, '2026-09-01', '2026-09-30')->>'net_profit')::numeric;
  _oct := (public._range_pnl(_co, '2026-10-01', '2026-10-21')->>'net_profit')::numeric;
  PERFORM pg_temp.ok('3 two share periods', jsonb_array_length(_c->'segments') = 2, (_c->'segments')::text);
  SELECT (l->>'pct')::numeric INTO _n FROM jsonb_array_elements(_c->'lines') l WHERE l->>'partner_id' = pg_temp.pid('مهند')::text;
  _exp := CASE WHEN GREATEST(_sep, 0) + GREATEST(_oct, 0) > 0
               THEN round((GREATEST(_sep, 0) * 25 + GREATEST(_oct, 0) * 40) / (GREATEST(_sep, 0) + GREATEST(_oct, 0)), 4) ELSE 40 END;
  PERFORM pg_temp.ok('3b blended share = profit-weighted', _n = _exp, 'got ' || _n || ' expected ' || _exp || ' sep ' || _sep || ' oct ' || _oct);
  SELECT SUM((l->>'amount')::numeric) INTO _m FROM jsonb_array_elements(_c->'lines') l;
  PERFORM pg_temp.ok('3c lines add up to the pool', _m = (_c->>'partner_pool')::numeric, _m || ' vs ' || (_c->>'partner_pool'));
  PERFORM pg_temp.ok('3d shares check passes', (_c->'checks'->>'shares_total_100')::boolean);
  _c := public._payout_calc(_co, '2026-09-01', '2026-09-30', 0);
  SELECT (l->>'pct')::numeric INTO _n FROM jsonb_array_elements(_c->'lines') l WHERE l->>'partner_id' = pg_temp.pid('مهند')::text;
  PERFORM pg_temp.ok('3e September alone = old 25%', _n = 25 AND jsonb_array_length(_c->'segments') = 1, _n::text);

  -- 4. Capital today: احمد +100k → old % for the rest of this month, new from the 1st.
  _pv := public.preview_partner_contribution(pg_temp.pid('احمد حافظ'), 100000, 'capital', _today);
  SELECT (p->>'old_pct')::numeric, (p->>'new_pct')::numeric INTO _n, _m FROM jsonb_array_elements(_pv->'partners') p
   WHERE p->>'partner_id' = pg_temp.pid('احمد حافظ')::text;
  PERFORM pg_temp.ok('4 preview old 8 → new 14.8148', _n = 8 AND _m = 14.8148 AND (_pv->>'effective_from')::date = (date_trunc('month', _today) + interval '1 month')::date,
    _n || ' → ' || _m || ' from ' || (_pv->>'effective_from'));
  SELECT SUM((p->>'new_pct')::numeric) INTO _n FROM jsonb_array_elements(_pv->'partners') p;
  PERFORM pg_temp.ok('4b preview new shares total 100', _n = 100, _n::text);
  _y := public.record_partner_contribution(pg_temp.pid('احمد حافظ'), 100000, 'capital', _today, 'TEST', NULL, NULL);
  PERFORM pg_temp.ok('4c today share unchanged (8)', pg_temp.pct('احمد حافظ') = 8);
  PERFORM pg_temp.ok('4d new share from the 1st', pg_temp.at('احمد حافظ', (date_trunc('month', _today) + interval '1 month')::date) = 14.8148);
  SELECT body INTO _txt FROM public.notifications WHERE type = 'partner.contribution' AND data->>'contribution_id' = _y::text LIMIT 1;
  PERFORM pg_temp.ok('4e super admin warning with old/new %',
    _txt LIKE '%8.00%' AND _txt LIKE '%14.81%' AND (SELECT count(*) FROM public.notifications WHERE data->>'contribution_id' = _y::text) >= 1
    AND (SELECT bool_and(severity = 'warning') FROM public.notifications WHERE data->>'contribution_id' = _y::text), _txt);

  -- 5. Loan: ميدو lends 50k → shares fixed, not capital, repaid before partners.
  _l := public.record_partner_contribution(pg_temp.pid('ميدو'), 50000, 'loan', '2026-10-01');
  PERFORM pg_temp.ok('5 loan keeps shares', pg_temp.pct('ميدو') = 12 AND pg_temp.at('ميدو', '2026-12-01') = pg_temp.at('ميدو', '2026-11-01') - 0
    AND (SELECT total_contributions FROM public.partner_ownership WHERE partner_id = pg_temp.pid('ميدو')) = 150000
    AND (SELECT open_loans FROM public.partner_ownership WHERE partner_id = pg_temp.pid('ميدو')) = 50000,
    pg_temp.pct('ميدو')::text);
  PERFORM pg_temp.ok('5b loan not credited yet', NOT EXISTS (SELECT 1 FROM public.partner_ledger_transactions WHERE reference_id = _l));
  SELECT body INTO _txt FROM public.notifications WHERE data->>'contribution_id' = _l::text LIMIT 1;
  PERFORM pg_temp.ok('5c loan warning', _txt LIKE '%سلّف%' AND _txt LIKE '%12.00%', _txt);
  _c := public._payout_calc(_co, '2026-09-01', '2026-10-21', 0);
  PERFORM pg_temp.ok('5d loan repaid first',
    (_c->>'loan_repayment')::numeric = LEAST(50000, (_c->>'available_before_loans')::numeric)
    AND (_c->>'available_before_fund')::numeric = (_c->>'available_before_loans')::numeric - (_c->>'loan_repayment')::numeric,
    'avail ' || (_c->>'available_before_loans') || ' repay ' || (_c->>'loan_repayment') || ' pool ' || (_c->>'partner_pool'));

  -- 6. Execute + reverse the payout.
  BEGIN
    _dist := public.execute_payout('2026-09-01', '2026-10-21', 0, 'TEST');
    PERFORM pg_temp.ok('6 payout repays the loan',
      (SELECT repaid_amount FROM public.partner_capital_contributions WHERE id = _l) = (_c->>'loan_repayment')::numeric
      AND (SELECT loan_repaid FROM public.profit_distributions WHERE id = _dist) = (_c->>'loan_repayment')::numeric
      AND EXISTS (SELECT 1 FROM public.partner_ledger_transactions WHERE reference_id = _dist AND reference_type = 'partner_loan'
                   AND partner_id = pg_temp.pid('ميدو') AND amount = (_c->>'loan_repayment')::numeric),
      'repaid ' || (SELECT repaid_amount FROM public.partner_capital_contributions WHERE id = _l));
    SELECT ownership_percentage INTO _n FROM public.profit_distribution_lines WHERE distribution_id = _dist AND partner_id = pg_temp.pid('مهند');
    PERFORM pg_temp.ok('6b line keeps blended share', _n = _exp OR _n IS NULL, COALESCE(_n::text, 'no line'));
    PERFORM public.reverse_payout(_dist, 'test reverse');
    PERFORM pg_temp.ok('6c reverse restores the loan',
      (SELECT repaid_amount FROM public.partner_capital_contributions WHERE id = _l) = 0
      AND NOT EXISTS (SELECT 1 FROM public.partner_loan_repayments WHERE distribution_id = _dist AND status = 'active')
      AND (SELECT COALESCE(SUM(amount), 0) FROM public.partner_ledger_transactions WHERE reference_id = _dist AND partner_id = pg_temp.pid('ميدو')) = 0);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.ok('6 payout', false, SQLERRM || ' checks ' || (_c->'checks')::text);
  END;

  -- 7. Manual edit: counts from today only; a later capital change still wins.
  UPDATE public.partners SET profit_share_percentage = CASE name WHEN 'زياد مصطفي' THEN 13 WHEN 'عاصم صلاح' THEN 11 END
   WHERE company_id = _co AND name IN ('زياد مصطفي', 'عاصم صلاح');
  PERFORM pg_temp.ok('7 manual snapshot from today',
    (SELECT count(*) FROM public.partner_share_snapshots WHERE company_id = _co AND effective_from = _today) = 1
    AND pg_temp.at('زياد مصطفي', _today) = 13 AND pg_temp.at('زياد مصطفي', _today - 1) = 12,
    pg_temp.at('زياد مصطفي', _today) || ' / ' || pg_temp.at('زياد مصطفي', _today - 1));
  PERFORM pg_temp.ok('7b capital effective later wins', pg_temp.at('زياد مصطفي', (date_trunc('month', _today) + interval '1 month')::date) <> 13);
  UPDATE public.partners SET updated_at = now() WHERE company_id = _co;
  PERFORM pg_temp.ok('7c touching partners adds no snapshot',
    (SELECT count(*) FROM public.partner_share_snapshots WHERE company_id = _co) = 1);
  PERFORM public.apply_partner_shares(_co);
  PERFORM pg_temp.ok('7d hourly refresh keeps manual', pg_temp.pct('زياد مصطفي') = 13);

  -- 8. Old callers record capital.
  _id := public.record_capital_contribution(pg_temp.pid('ميدو'), 1000, _today);
  PERFORM pg_temp.ok('8 old RPC = capital', (SELECT kind FROM public.partner_capital_contributions WHERE id = _id) = 'capital');

  -- 9. Cashier cannot record or preview.
  PERFORM pg_temp.act_as('cashier');
  BEGIN
    PERFORM public.record_partner_contribution(pg_temp.pid('ميدو'), 10, 'loan', NULL);
    PERFORM pg_temp.ok('9 cashier blocked', false);
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('9 cashier blocked', SQLERRM LIKE '%Super Admin%', SQLERRM); END;
  BEGIN
    PERFORM public.preview_partner_contribution(pg_temp.pid('ميدو'), 10, 'loan', NULL);
    PERFORM pg_temp.ok('9b cashier preview blocked', false);
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('9b cashier preview blocked', true); END;
  PERFORM pg_temp.act_as('super_admin');

  PERFORM pg_temp.ok('10 hourly job scheduled', EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'apply-partner-shares'));

END $$;

SELECT n, step, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, detail FROM _results ORDER BY n;

ROLLBACK;
