-- Partner contributions: capital or loan, with shares that change from the 1st of next month.
--
-- * Capital (رأس مال): changes ownership. The partner's old share stays for the
--   whole month of the contribution; the new share counts from the 1st of the
--   next month (effective_from).
-- * Loan (قرض): shares stay as they are. Open loans are repaid from the
--   available profit of a payout before the partner pool, oldest first. The
--   repaid amount is credited to the lender's balance at payout time.
-- * A payout whose range crosses a share change is split per share period;
--   each period's profit is shared with that period's percentages.
-- * Manual share edits (edit partner, liquidation) are kept as dated snapshots
--   so past periods keep the shares they had.
-- * Super admins get a warning with the old and new percentages.

-- 1. Columns ----------------------------------------------------------------
ALTER TABLE public.partner_capital_contributions
  ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'capital',
  ADD COLUMN IF NOT EXISTS effective_from date,
  ADD COLUMN IF NOT EXISTS repaid_amount numeric NOT NULL DEFAULT 0;

DO $$ BEGIN
  ALTER TABLE public.partner_capital_contributions
    ADD CONSTRAINT partner_capital_contributions_kind_check CHECK (kind IN ('capital', 'loan'));
  ALTER TABLE public.partner_capital_contributions
    ADD CONSTRAINT partner_capital_contributions_repaid_check CHECK (repaid_amount >= 0 AND repaid_amount <= amount);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Existing contributions keep counting from their own date (no change to any share).
SET LOCAL session_replication_role = replica;
UPDATE public.partner_capital_contributions SET effective_from = contribution_date WHERE effective_from IS NULL;
SET LOCAL session_replication_role = origin;
ALTER TABLE public.partner_capital_contributions ALTER COLUMN effective_from SET NOT NULL;

CREATE OR REPLACE FUNCTION public.trg_contribution_effective_from()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.effective_from IS NULL THEN
    NEW.effective_from := CASE WHEN NEW.kind = 'capital'
      THEN (date_trunc('month', NEW.contribution_date) + interval '1 month')::date
      ELSE NEW.contribution_date END;
  END IF;
  RETURN NEW;
END $function$;

CREATE OR REPLACE TRIGGER t_contribution_effective_from BEFORE INSERT ON public.partner_capital_contributions
  FOR EACH ROW EXECUTE FUNCTION public.trg_contribution_effective_from();

ALTER TABLE public.profit_distributions ADD COLUMN IF NOT EXISTS loan_repaid numeric NOT NULL DEFAULT 0;

-- 2. Tables -----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.partner_share_snapshots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  effective_from date NOT NULL,
  shares jsonb NOT NULL,
  source text NOT NULL DEFAULT 'manual',
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS partner_share_snapshots_company_idx
  ON public.partner_share_snapshots (company_id, effective_from DESC, created_at DESC);
ALTER TABLE public.partner_share_snapshots ENABLE ROW LEVEL SECURITY;
CREATE POLICY partner_share_snapshots_read ON public.partner_share_snapshots FOR SELECT TO authenticated
  USING (company_id = public.current_company_id() AND public.is_super_admin());
REVOKE ALL ON public.partner_share_snapshots FROM anon;

CREATE TABLE IF NOT EXISTS public.partner_loan_repayments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  distribution_id uuid NOT NULL REFERENCES public.profit_distributions(id),
  contribution_id uuid NOT NULL REFERENCES public.partner_capital_contributions(id),
  partner_id uuid NOT NULL REFERENCES public.partners(id),
  amount numeric NOT NULL CHECK (amount > 0),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'reversed')),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS partner_loan_repayments_dist_idx ON public.partner_loan_repayments (distribution_id);
CREATE INDEX IF NOT EXISTS partner_loan_repayments_contribution_idx ON public.partner_loan_repayments (contribution_id);
ALTER TABLE public.partner_loan_repayments ENABLE ROW LEVEL SECURITY;
CREATE POLICY partner_loan_repayments_read ON public.partner_loan_repayments FOR SELECT TO authenticated
  USING (company_id = public.current_company_id()
         AND (public.is_super_admin() OR partner_id = public.current_partner_id()));
REVOKE ALL ON public.partner_loan_repayments FROM anon;

-- 3. Share helpers ----------------------------------------------------------
-- Capital ratio on a date (optionally with one extra amount for a preview).
-- Rounded to 4 decimals; the rounding rest goes to the largest holder so the
-- total is exactly 100.
CREATE OR REPLACE FUNCTION public._capital_shares(_company uuid, _d date, _extra_partner uuid DEFAULT NULL, _extra numeric DEFAULT 0)
 RETURNS TABLE(partner_id uuid, pct numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH cap AS (
    SELECT p.id, COALESCE((SELECT SUM(c.amount) FROM public.partner_capital_contributions c
                            WHERE c.partner_id = p.id AND c.status = 'active' AND c.kind = 'capital'
                              AND c.effective_from <= _d), 0)
           + CASE WHEN p.id = _extra_partner THEN COALESCE(_extra, 0) ELSE 0 END AS amt
      FROM public.partners p
     WHERE p.company_id = _company AND p.status = 'active'
  ), r AS (
    SELECT cap.id, round(cap.amt * 100.0 / SUM(cap.amt) OVER (), 4) AS pct,
           row_number() OVER (ORDER BY cap.amt DESC, cap.id) AS rn
      FROM cap WHERE cap.amt > 0
  )
  SELECT r.id, r.pct + CASE WHEN r.rn = 1 THEN 100 - SUM(r.pct) OVER () ELSE 0 END FROM r
$function$;

-- Shares in force on a date: the newest manual snapshot, unless a capital
-- contribution took effect after it (or was recorded after it).
CREATE OR REPLACE FUNCTION public._partner_shares_at(_company uuid, _d date)
 RETURNS TABLE(partner_id uuid, pct numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
DECLARE _m public.partner_share_snapshots;
BEGIN
  SELECT * INTO _m FROM public.partner_share_snapshots s
   WHERE s.company_id = _company AND s.effective_from <= _d
   ORDER BY s.effective_from DESC, s.created_at DESC LIMIT 1;
  IF _m.id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.partner_capital_contributions c
     WHERE c.company_id = _company AND c.kind = 'capital' AND c.status = 'active' AND c.effective_from <= _d
       AND (c.effective_from > _m.effective_from OR c.created_at > _m.created_at)
  ) THEN
    RETURN QUERY SELECT e.key::uuid, e.value::numeric FROM jsonb_each_text(_m.shares) e WHERE e.value::numeric > 0;
  ELSE
    RETURN QUERY SELECT cs.partner_id, cs.pct FROM public._capital_shares(_company, _d) cs;
  END IF;
END $function$;

-- Writes today's shares onto partners (the number every screen shows).
CREATE OR REPLACE FUNCTION public.apply_partner_shares(_company uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _today date := public.business_today(_company);
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public._partner_shares_at(_company, _today)) THEN RETURN; END IF;
  PERFORM set_config('app.share_apply', 'on', true);
  UPDATE public.partners p SET profit_share_percentage = s.pct, updated_at = now()
    FROM (SELECT p2.id, COALESCE(sh.pct, 0) AS pct
            FROM public.partners p2
            LEFT JOIN public._partner_shares_at(_company, _today) sh ON sh.partner_id = p2.id
           WHERE p2.company_id = _company AND p2.status = 'active') s
   WHERE p.id = s.id AND p.profit_share_percentage IS DISTINCT FROM s.pct;
  PERFORM set_config('app.share_apply', 'off', true);
END $function$;

CREATE OR REPLACE FUNCTION public.apply_partner_shares_all()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _c uuid;
BEGIN
  FOR _c IN SELECT id FROM public.companies LOOP
    PERFORM public.apply_partner_shares(_c);
  END LOOP;
END $function$;

-- Kept by name: the contribution trigger and older callers use it.
CREATE OR REPLACE FUNCTION public.recompute_capital_equity(_company_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM public.apply_partner_shares(_company_id);
END $function$;

-- A share change made by hand (edit partner, liquidation) is recorded from
-- today, so earlier days keep the shares they had.
CREATE OR REPLACE FUNCTION public.trg_partner_share_snapshot()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _c uuid; _today date; _now jsonb; _was jsonb;
BEGIN
  IF current_setting('app.share_apply', true) = 'on' THEN RETURN NULL; END IF;
  FOR _c IN SELECT DISTINCT company_id FROM new_rows LOOP
    -- Only a real change of share or status counts (not a rename or a pause).
    IF TG_OP = 'UPDATE' AND NOT EXISTS (
      SELECT 1 FROM new_rows n JOIN old_rows o ON o.id = n.id
       WHERE n.company_id = _c AND (n.profit_share_percentage IS DISTINCT FROM o.profit_share_percentage
                                    OR n.status IS DISTINCT FROM o.status)) THEN
      CONTINUE;
    END IF;
    IF TG_OP = 'INSERT' AND NOT EXISTS (
      SELECT 1 FROM new_rows n WHERE n.company_id = _c AND COALESCE(n.profit_share_percentage, 0) > 0) THEN
      CONTINUE;
    END IF;
    _today := public.business_today(_c);
    SELECT COALESCE(jsonb_object_agg(p.id, round(p.profit_share_percentage, 4)), '{}'::jsonb) INTO _now
      FROM public.partners p
     WHERE p.company_id = _c AND p.status = 'active' AND COALESCE(p.profit_share_percentage, 0) > 0;
    SELECT COALESCE(jsonb_object_agg(sh.partner_id, round(sh.pct, 4)), '{}'::jsonb) INTO _was
      FROM public._partner_shares_at(_c, _today) sh
      JOIN public.partners p ON p.id = sh.partner_id AND p.status = 'active';
    IF _now <> _was AND _now <> '{}'::jsonb THEN
      INSERT INTO public.partner_share_snapshots (company_id, effective_from, shares, source, created_by)
      VALUES (_c, _today, _now, 'manual', public.current_profile_id());
    END IF;
  END LOOP;
  RETURN NULL;
END $function$;

CREATE OR REPLACE TRIGGER t_partner_share_snapshot_upd AFTER UPDATE ON public.partners
  REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.trg_partner_share_snapshot();
CREATE OR REPLACE TRIGGER t_partner_share_snapshot_ins AFTER INSERT ON public.partners
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.trg_partner_share_snapshot();

-- Shares set by hand before this change stay as they are from today.
DO $$
DECLARE _c uuid; _now jsonb; _cap jsonb;
BEGIN
  FOR _c IN SELECT id FROM public.companies LOOP
    SELECT COALESCE(jsonb_object_agg(p.id, round(p.profit_share_percentage, 4)), '{}'::jsonb) INTO _now
      FROM public.partners p
     WHERE p.company_id = _c AND p.status = 'active' AND COALESCE(p.profit_share_percentage, 0) > 0;
    SELECT COALESCE(jsonb_object_agg(sh.partner_id, round(sh.pct, 4)), '{}'::jsonb) INTO _cap
      FROM public._capital_shares(_c, public.business_today(_c)) sh;
    IF _now <> _cap AND _now <> '{}'::jsonb THEN
      INSERT INTO public.partner_share_snapshots (company_id, effective_from, shares, source)
      VALUES (_c, public.business_today(_c), _now, 'manual');
    END IF;
  END LOOP;
END $$;

-- 4. Ledger: a loan is credited to the lender only when it is repaid ----------
CREATE OR REPLACE FUNCTION public.sync_capital_contribution_ledger()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.status = 'active' AND NEW.kind = 'capital' AND NOT EXISTS (
    SELECT 1 FROM public.partner_ledger_transactions t
    WHERE t.reference_type = 'partner_capital_contributions' AND t.reference_id = NEW.id
  ) THEN
    INSERT INTO public.partner_ledger_transactions
      (company_id, partner_id, transaction_type, amount, currency, reference_type, reference_id,
       description, transaction_date, created_by)
    VALUES (NEW.company_id, NEW.partner_id, 'capital_contribution', NEW.amount, NEW.currency,
      'partner_capital_contributions', NEW.id, NEW.notes, NEW.contribution_date, NEW.created_by);
  END IF;
  RETURN NEW;
END $function$;

-- 5. Recording + preview + warning -----------------------------------------
CREATE OR REPLACE FUNCTION public.preview_partner_contribution(_partner_id uuid, _amount numeric, _kind text DEFAULT 'capital', _contribution_date date DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _company uuid := public.current_company_id(); _date date; _eff date; _rows jsonb;
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only the Super Admin can edit partner capital'; END IF;
  IF _kind NOT IN ('capital', 'loan') THEN RAISE EXCEPTION 'Choose capital or loan'; END IF;
  _date := COALESCE(_contribution_date, public.business_today(_company));
  _eff := CASE WHEN _kind = 'capital' THEN (date_trunc('month', _date) + interval '1 month')::date ELSE _date END;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('partner_id', p.id, 'name', p.name,
           'old_pct', COALESCE(o.pct, 0), 'new_pct', COALESCE(n.pct, 0)) ORDER BY COALESCE(n.pct, 0) DESC, p.name), '[]'::jsonb)
    INTO _rows
    FROM public.partners p
    LEFT JOIN public._partner_shares_at(_company, CASE WHEN _kind = 'capital' THEN _eff - 1 ELSE _date END) o ON o.partner_id = p.id
    LEFT JOIN (
      SELECT * FROM public._capital_shares(_company, _eff, _partner_id, COALESCE(_amount, 0)) WHERE _kind = 'capital'
      UNION ALL
      SELECT * FROM public._partner_shares_at(_company, _date) WHERE _kind = 'loan'
    ) n ON n.partner_id = p.id
   WHERE p.company_id = _company AND p.status = 'active';

  RETURN jsonb_build_object('kind', _kind, 'contribution_date', _date, 'effective_from', _eff,
    'old_until', _eff - 1, 'partners', _rows);
END $function$;

CREATE OR REPLACE FUNCTION public.record_partner_contribution(_partner_id uuid, _amount numeric, _kind text, _contribution_date date DEFAULT NULL, _reference text DEFAULT NULL, _payment_method text DEFAULT NULL, _notes text DEFAULT NULL)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _profile uuid := public.current_profile_id();
        _company uuid := public.current_company_id();
        _currency text; _id uuid; _c public.partner_capital_contributions; _name text;
        _old numeric; _new numeric; _shares jsonb; _title text; _body text;
BEGIN
  IF _profile IS NULL OR _company IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only the Super Admin can edit partner capital'; END IF;
  IF _kind IS NULL OR _kind NOT IN ('capital', 'loan') THEN RAISE EXCEPTION 'Choose capital or loan'; END IF;
  IF _amount IS NULL OR _amount <= 0 THEN RAISE EXCEPTION 'Amount must be greater than zero'; END IF;
  SELECT p.name INTO _name FROM public.partners p WHERE p.id = _partner_id AND p.company_id = _company;
  IF _name IS NULL THEN RAISE EXCEPTION 'Partner not found'; END IF;

  SELECT COALESCE(c.currency, 'EGP') INTO _currency FROM public.companies c WHERE c.id = _company;

  -- Triggers set effective_from, post the capital ledger entry and refresh today's shares.
  INSERT INTO public.partner_capital_contributions (company_id, partner_id, amount, currency, kind,
    contribution_date, payment_method, reference, notes, created_by)
  VALUES (_company, _partner_id, round(_amount, 2), COALESCE(_currency, 'EGP'), _kind,
    COALESCE(_contribution_date, public.business_today(_company)), NULLIF(_payment_method, ''),
    NULLIF(_reference, ''), NULLIF(_notes, ''), _profile)
  RETURNING * INTO _c;
  _id := _c.id;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('partner_id', p.id, 'name', p.name,
           'old_pct', COALESCE(o.pct, 0), 'new_pct', COALESCE(n.pct, 0)) ORDER BY p.name), '[]'::jsonb),
         MAX(COALESCE(o.pct, 0)) FILTER (WHERE p.id = _partner_id),
         MAX(COALESCE(n.pct, 0)) FILTER (WHERE p.id = _partner_id)
    INTO _shares, _old, _new
    FROM public.partners p
    LEFT JOIN public._partner_shares_at(_company, CASE WHEN _kind = 'capital' THEN _c.effective_from - 1 ELSE _c.contribution_date END) o
      ON o.partner_id = p.id
    LEFT JOIN public._partner_shares_at(_company, _c.effective_from) n ON n.partner_id = p.id
   WHERE p.company_id = _company AND p.status = 'active';

  IF _kind = 'capital' THEN
    _title := 'خلي بالك: مساهمة في رأس المال';
    _body := _name || ' ساهم بـ ' || to_char(_c.amount, 'FM999999990.00') || ' ج.م يوم ' ||
      to_char(_c.contribution_date, 'DD/MM/YYYY') || '. نسبته كانت ' || to_char(round(COALESCE(_old, 0), 2), 'FM990.00') ||
      '% وهتبقى ' || to_char(round(COALESCE(_new, 0), 2), 'FM990.00') || '% من أول ' || to_char(_c.effective_from, 'DD/MM/YYYY') ||
      '. أرباح الأيام لحد ' || to_char(_c.effective_from - 1, 'DD/MM/YYYY') ||
      ' بتتوزع بالنسب القديمة، ونسب باقي الشركاء هتتغير معاه.';
  ELSE
    _title := 'خلي بالك: قرض من شريك';
    _body := _name || ' سلّف المكان ' || to_char(_c.amount, 'FM999999990.00') || ' ج.م يوم ' ||
      to_char(_c.contribution_date, 'DD/MM/YYYY') || '. نسبته فاضلة ' || to_char(round(COALESCE(_old, 0), 2), 'FM990.00') ||
      '% زي ما هي، والقرض هيترد له من الأرباح قبل ما تتوزع على الشركاء.';
  END IF;

  INSERT INTO public.notifications (company_id, user_id, type, severity, title, body, data)
  SELECT _company, up.id, 'partner.contribution', 'warning', _title, _body,
    jsonb_build_object('contribution_id', _id, 'partner_id', _partner_id, 'kind', _kind, 'amount', _c.amount,
      'contribution_date', _c.contribution_date, 'effective_from', _c.effective_from,
      'old_pct', COALESCE(_old, 0), 'new_pct', COALESCE(_new, 0), 'shares', _shares)
    FROM public.user_profiles up
    JOIN public.user_roles ur ON ur.user_id = up.id JOIN public.roles r ON r.id = ur.role_id
   WHERE up.company_id = _company AND up.is_active AND r.key = 'super_admin';

  PERFORM public.log_audit('partner.capital_contribution', 'partners',
    'partner_capital_contributions', _id, NULL,
    jsonb_build_object('amount', _c.amount, 'currency', _c.currency, 'kind', _kind,
      'effective_from', _c.effective_from, 'old_pct', COALESCE(_old, 0), 'new_pct', COALESCE(_new, 0)), NULL, NULL);
  RETURN _id;
END $function$;

-- Older screens: always capital.
CREATE OR REPLACE FUNCTION public.record_capital_contribution(_partner_id uuid, _amount numeric, _contribution_date date DEFAULT business_today(), _reference text DEFAULT NULL::text, _payment_method text DEFAULT NULL::text, _notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN public.record_partner_contribution(_partner_id, _amount, 'capital', _contribution_date, _reference, _payment_method, _notes);
END $function$;

-- 6. Payout ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._payout_calc(_company uuid, _from date, _to date, _fund numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _pnl jsonb; _net numeric; _mgmt_total numeric; _mgmt_recorded numeric; _mgmt_due numeric;
  _after_mgmt numeric; _cfg jsonb; _rtype text; _rval numeric; _reserve numeric; _available numeric;
  _fund_r numeric := round(GREATEST(COALESCE(_fund, 0), 0), 2); _pool numeric; _share_total numeric := 100;
  _active_total numeric; _lines jsonb := '[]'::jsonb; _allocated numeric := 0; _r record; _amt numeric;
  _tab numeric; _adv numeric; _tab_d numeric; _adv_d numeric; _largest uuid; _overlap jsonb; _open_shifts int; _open_orders int; _sus jsonb; _today date;
  _to_end timestamptz;
  _starts date[]; _i int; _s0 date; _s1 date; _seg_net numeric; _seg_shares jsonb; _seg_total numeric;
  _segments jsonb := '[]'::jsonb; _wsum numeric := 0; _blend jsonb; _shares_ok boolean := true;
  _l record; _left numeric; _take numeric; _loans jsonb := '[]'::jsonb; _loan_repay numeric := 0; _after_loans numeric;
BEGIN
  _today := public.business_today(_company);
  _pnl := public._range_pnl(_company, _from, _to);
  _net := (_pnl->>'net_profit')::numeric;
  _to_end := public.business_day_start(_to + 1, _company);

  SELECT COALESCE(SUM(m.amount), 0) INTO _mgmt_total FROM public._management_salary(_company, _from, _to, _pnl) m;
  _mgmt_recorded := (_pnl->>'management_salary_recorded')::numeric;
  _mgmt_due := GREATEST(round(_mgmt_total - _mgmt_recorded, 2), 0);
  _after_mgmt := round(_net - _mgmt_due, 2);

  _cfg := public.operating_reserve_settings();
  _rtype := COALESCE(_cfg->>'operating_reserve_type', 'percent');
  _rval := GREATEST(COALESCE((_cfg->>'operating_reserve_value')::numeric, 0), 0);
  _reserve := CASE WHEN _after_mgmt <= 0 THEN 0
                   WHEN _rtype = 'amount' THEN LEAST(_rval, _after_mgmt)
                   ELSE round(_after_mgmt * LEAST(_rval, 100) / 100.0, 2) END;
  _available := GREATEST(round(_after_mgmt - _reserve, 2), 0);

  -- Partner loans come back first, oldest first, from the available profit.
  _left := _available;
  FOR _l IN
    SELECT c.id, c.partner_id, p.name, c.contribution_date, round(c.amount - c.repaid_amount, 2) AS open
      FROM public.partner_capital_contributions c JOIN public.partners p ON p.id = c.partner_id
     WHERE c.company_id = _company AND c.kind = 'loan' AND c.status = 'active'
       AND c.contribution_date <= _to AND c.amount > c.repaid_amount
     ORDER BY c.contribution_date, c.created_at, c.id
  LOOP
    _take := LEAST(_l.open, GREATEST(_left, 0));
    _loans := _loans || jsonb_build_array(jsonb_build_object(
      'contribution_id', _l.id, 'partner_id', _l.partner_id, 'name', _l.name, 'date', _l.contribution_date,
      'open', _l.open, 'repay', _take, 'carried', round(_l.open - _take, 2)));
    _left := round(_left - _take, 2);
    _loan_repay := _loan_repay + _take;
  END LOOP;
  _after_loans := round(_available - _loan_repay, 2);
  _pool := round(_after_loans - _fund_r, 2);

  -- Share periods: shares can change inside the range (capital counts from the
  -- 1st of the next month; manual edits from their day). Each period's profit
  -- is shared with that period's shares; partners get the blend.
  _starts := ARRAY(
    SELECT DISTINCT x.d FROM (
      SELECT _from AS d
      UNION SELECT s.effective_from FROM public.partner_share_snapshots s
       WHERE s.company_id = _company AND s.effective_from > _from AND s.effective_from <= _to
      UNION SELECT c.effective_from FROM public.partner_capital_contributions c
       WHERE c.company_id = _company AND c.kind = 'capital' AND c.status = 'active'
         AND c.effective_from > _from AND c.effective_from <= _to
    ) x ORDER BY x.d);

  FOR _i IN 1 .. array_length(_starts, 1) LOOP
    _s0 := _starts[_i];
    _s1 := COALESCE(_starts[_i + 1] - 1, _to);
    _seg_net := CASE WHEN array_length(_starts, 1) = 1 THEN _net
                     ELSE (public._range_pnl(_company, _s0, _s1)->>'net_profit')::numeric END;
    SELECT COALESCE(jsonb_object_agg(sh.partner_id, sh.pct), '{}'::jsonb), COALESCE(SUM(sh.pct), 0)
      INTO _seg_shares, _seg_total
      FROM public._partner_shares_at(_company, _s0) sh
      JOIN public.partners p ON p.id = sh.partner_id AND p.status = 'active'
     WHERE sh.pct > 0;
    IF round(_seg_total, 4) <> 100 THEN _shares_ok := false; _share_total := round(_seg_total, 4); END IF;
    _segments := _segments || jsonb_build_array(jsonb_build_object(
      'from', _s0, 'to', _s1, 'net_profit', round(_seg_net, 2), 'shares', _seg_shares));
    _wsum := _wsum + GREATEST(_seg_net, 0);
  END LOOP;

  -- Weight = each period's positive profit; with no profit anywhere, the last period's shares.
  SELECT COALESCE(jsonb_object_agg(z.pid, round(z.s / z.den, 4)), '{}'::jsonb) INTO _blend
    FROM (
      SELECT e.key AS pid, SUM(q.w * e.value::numeric) AS s, MAX(q.den) AS den
        FROM (SELECT x.shares,
                     CASE WHEN _wsum > 0 THEN GREATEST(x.net_profit, 0) WHEN x."to" = _to THEN 1 ELSE 0 END AS w,
                     CASE WHEN _wsum > 0 THEN _wsum ELSE 1 END AS den
                FROM jsonb_to_recordset(_segments) AS x("from" date, "to" date, net_profit numeric, shares jsonb)) q,
             jsonb_each_text(q.shares) e
       GROUP BY e.key
    ) z
   WHERE z.s > 0;

  SELECT COALESCE(SUM(b.value::numeric) FILTER (WHERE NOT p.dividends_paused), 0) INTO _active_total
    FROM jsonb_each_text(_blend) b JOIN public.partners p ON p.id = b.key::uuid;

  -- Paused partners keep their share in the café (no line, nothing is redistributed).
  IF abs(_active_total - 100) < 0.01 THEN
    SELECT b.key::uuid INTO _largest FROM jsonb_each_text(_blend) b
     ORDER BY b.value::numeric DESC, b.key LIMIT 1;
  END IF;

  FOR _r IN
    SELECT b.key::uuid AS partner_id, p.name, b.value::numeric AS pct, p.dividends_paused AS paused
      FROM jsonb_each_text(_blend) b JOIN public.partners p ON p.id = b.key::uuid
     WHERE p.status = 'active'
     ORDER BY (b.key::uuid = _largest) NULLS FIRST, b.key::uuid
  LOOP
    _amt := CASE WHEN _r.paused OR _pool <= 0 THEN 0
                 WHEN _r.partner_id = _largest THEN round(_pool - _allocated, 2)
                 ELSE round(_pool * _r.pct / 100.0, 2) END;
    _allocated := _allocated + _amt;
    SELECT COALESCE(SUM(t.total_amount - t.settled_amount), 0) INTO _tab
      FROM public.partner_tab_orders t
     WHERE t.partner_id = _r.partner_id AND NOT t.is_settled AND t.created_at < _to_end;
    -- Partner advances (سلف) taken up to the end of the range.
    SELECT COALESCE(SUM(a.amount - a.deducted_amount), 0) INTO _adv
      FROM public.partner_advances a
     WHERE a.partner_id = _r.partner_id AND a.status = 'active' AND a.deducted_amount < a.amount AND a.advance_date <= _to;
    -- Order: tabs first, then advances; each only up to what the dividend covers.
    _tab_d := LEAST(round(_tab, 2), _amt);
    _adv_d := LEAST(round(_adv, 2), _amt - _tab_d);
    _lines := _lines || jsonb_build_array(jsonb_build_object(
      'partner_id', _r.partner_id, 'name', _r.name, 'pct', _r.pct, 'paused', _r.paused,
      'amount', _amt, 'tab_open', round(_tab, 2), 'tab_deduct', _tab_d,
      'advance_open', round(_adv, 2), 'advance_deduct', _adv_d,
      'cash_due', round(_amt - _tab_d - _adv_d, 2),
      'tab_carried', round(_tab - _tab_d, 2),
      'advance_carried', round(_adv - _adv_d, 2)));
  END LOOP;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', d.id, 'from', d.range_from, 'to', d.range_to)), '[]'::jsonb)
    INTO _overlap
    FROM public.profit_distributions d
   WHERE d.company_id = _company AND d.status = 'active' AND d.range_from IS NOT NULL
     AND d.range_from <= _to AND d.range_to >= _from;

  SELECT count(*) INTO _open_shifts FROM public.shifts s
   WHERE s.company_id = _company AND s.status = 'open' AND s.business_date <= _to;
  SELECT count(*) INTO _open_orders FROM public.orders o
   WHERE o.company_id = _company AND o.status = 'open'
     AND o.business_date BETWEEN _from AND _to;

  _sus := public.financial_self_sustainability();

  RETURN jsonb_build_object(
    'from', _from, 'to', _to, 'pnl', _pnl,
    'net_profit', round(_net, 2),
    'management_salary_total', round(_mgmt_total, 2),
    'management_salary_recorded', round(_mgmt_recorded, 2),
    'management_salary_due', _mgmt_due,
    'net_after_management', _after_mgmt,
    'reserve_type', _rtype, 'reserve_value', _rval, 'reserve_amount', round(_reserve, 2),
    'available_before_loans', _available,
    'loan_repayment', round(_loan_repay, 2),
    'loans', _loans,
    'available_before_fund', _after_loans,
    'development_fund', _fund_r,
    'partner_pool', GREATEST(_pool, 0),
    'retained_paused', round(GREATEST(_pool, 0) - _allocated, 2),
    'lines', _lines,
    'segments', _segments,
    'sustainability', _sus,
    'checks', jsonb_build_object(
      'range_valid', _to >= _from AND _to <= _today,
      'no_overlap', jsonb_array_length(_overlap) = 0,
      'no_open_shifts', _open_shifts = 0,
      'no_open_orders', _open_orders = 0,
      'net_positive', _available > 0,
      'fund_within_limit', _fund_r <= _after_loans,
      'partner_pool_positive', _pool > 0 OR (_loan_repay > 0 AND _pool >= 0),
      'shares_total_100', _shares_ok),
    'overlaps', _overlap, 'open_shifts', _open_shifts, 'open_orders', _open_orders,
    'share_total', _share_total);
END $function$;

CREATE OR REPLACE FUNCTION public.execute_payout(_from date, _to date, _development_fund numeric DEFAULT 0, _notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _company uuid := public.current_company_id(); _profile uuid := public.current_profile_id();
  _calc jsonb; _checks jsonb; _k text; _currency text; _dist uuid; _line jsonb; _txn uuid;
  _left numeric; _take numeric; _t record; _tab_total numeric := 0; _partner_tab numeric; _to_end timestamptz;
  _a public.partner_advances; _partner_adv numeric; _loan jsonb; _loan_total numeric := 0;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only a super admin can run a profit payout'; END IF;
  IF _from IS NULL OR _to IS NULL OR _to < _from THEN RAISE EXCEPTION 'Choose a valid date range'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('payout:' || _company::text));

  _calc := public._payout_calc(_company, _from, _to, _development_fund);
  _checks := _calc->'checks';
  FOR _k IN SELECT jsonb_object_keys(_checks) LOOP
    IF NOT (_checks->>_k)::boolean THEN
      RAISE EXCEPTION 'Payout blocked: %', CASE _k
        WHEN 'range_valid' THEN 'the range must end today or earlier'
        WHEN 'no_overlap' THEN 'part of this range was already paid out'
        WHEN 'no_open_shifts' THEN 'close the open shift(s) in this range first'
        WHEN 'no_open_orders' THEN 'settle the unpaid order(s) in this range first'
        WHEN 'net_positive' THEN 'there is no positive distributable profit'
        WHEN 'self_sustaining' THEN 'self-sustainability not reached (3 profitable months in a row)'
        WHEN 'fund_within_limit' THEN 'the development fund is larger than the available profit'
        WHEN 'partner_pool_positive' THEN 'the development fund leaves nothing for partners'
        WHEN 'shares_total_100' THEN 'active partner shares must total 100%'
        ELSE _k END;
    END IF;
  END LOOP;

  SELECT currency INTO _currency FROM public.companies WHERE id = _company;
  _to_end := public.business_day_start(_to + 1, _company);

  INSERT INTO public.profit_distributions (company_id, period_id, range_from, range_to, net_profit,
    development_fund_amount, management_salary, reserve_amount, pnl_snapshot, notes, currency, status,
    distributed_at, created_by)
  VALUES (_company, NULL, _from, _to, (_calc->>'partner_pool')::numeric, (_calc->>'development_fund')::numeric,
    (_calc->>'management_salary_due')::numeric, (_calc->>'reserve_amount')::numeric, _calc - 'sustainability',
    NULLIF(btrim(COALESCE(_notes, '')), ''), COALESCE(_currency, 'EGP'), 'active', now(), _profile)
  RETURNING id INTO _dist;

  -- Partner loans repaid from this profit: credited to the lender's balance.
  FOR _loan IN SELECT * FROM jsonb_array_elements(_calc->'loans') LOOP
    _take := (_loan->>'repay')::numeric;
    CONTINUE WHEN _take <= 0;
    UPDATE public.partner_capital_contributions SET repaid_amount = round(repaid_amount + _take, 2)
     WHERE id = (_loan->>'contribution_id')::uuid;
    INSERT INTO public.partner_loan_repayments (company_id, distribution_id, contribution_id, partner_id, amount)
    VALUES (_company, _dist, (_loan->>'contribution_id')::uuid, (_loan->>'partner_id')::uuid, _take);
    INSERT INTO public.partner_ledger_transactions (company_id, partner_id, transaction_type, amount, currency,
      reference_type, reference_id, description, transaction_date, status, created_by)
    VALUES (_company, (_loan->>'partner_id')::uuid, 'adjustment', _take, COALESCE(_currency, 'EGP'),
      'partner_loan', _dist, 'سداد قرض من أرباح ' || _from || ' إلى ' || _to, _to, 'active', _profile);
    _loan_total := _loan_total + _take;
  END LOOP;

  FOR _line IN SELECT * FROM jsonb_array_elements(_calc->'lines') LOOP
    CONTINUE WHEN (_line->>'amount')::numeric <= 0;
    INSERT INTO public.partner_ledger_transactions (company_id, partner_id, transaction_type, amount, currency,
      reference_type, reference_id, description, transaction_date, status, created_by)
    VALUES (_company, (_line->>'partner_id')::uuid, 'profit_distribution', (_line->>'amount')::numeric, COALESCE(_currency, 'EGP'),
      'profit_distribution', _dist, 'أرباح من ' || _from || ' إلى ' || _to, _to, 'active', _profile)
    RETURNING id INTO _txn;
    INSERT INTO public.profit_distribution_lines (distribution_id, partner_id, ownership_percentage, amount, ledger_transaction_id)
    VALUES (_dist, (_line->>'partner_id')::uuid, (_line->>'pct')::numeric, (_line->>'amount')::numeric, _txn);

    -- Settle partner tabs oldest-first, only up to the dividend. The rest stays owed.
    _left := (_line->>'tab_deduct')::numeric; _partner_tab := 0;
    FOR _t IN SELECT * FROM public.partner_tab_orders
               WHERE partner_id = (_line->>'partner_id')::uuid AND NOT is_settled AND created_at < _to_end
               ORDER BY created_at, id FOR UPDATE LOOP
      EXIT WHEN _left <= 0;
      _take := LEAST(round(_t.total_amount - _t.settled_amount, 2), _left);
      CONTINUE WHEN _take <= 0;
      UPDATE public.partner_tab_orders SET settled_amount = round(settled_amount + _take, 2),
        is_settled = round(settled_amount + _take, 2) >= total_amount,
        settled_at = CASE WHEN round(settled_amount + _take, 2) >= total_amount THEN now() ELSE settled_at END,
        distribution_id = _dist, updated_at = now()
       WHERE id = _t.id;
      INSERT INTO public.partner_tab_settlements (company_id, distribution_id, tab_order_id, partner_id, amount)
      VALUES (_company, _dist, _t.id, _t.partner_id, _take);
      _left := round(_left - _take, 2);
      _partner_tab := _partner_tab + _take;
    END LOOP;
    IF _partner_tab > 0 THEN
      INSERT INTO public.partner_ledger_transactions (company_id, partner_id, transaction_type, amount, currency,
        reference_type, reference_id, description, transaction_date, status, created_by)
      VALUES (_company, (_line->>'partner_id')::uuid, 'adjustment', -_partner_tab, COALESCE(_currency, 'EGP'),
        'partner_tab', _dist, 'خصم فواتير على الحساب', _to, 'active', _profile);
      _tab_total := _tab_total + _partner_tab;
    END IF;

    -- Then recover partner advances (سلف), oldest first, up to what's left of the dividend.
    _left := (_line->>'advance_deduct')::numeric; _partner_adv := 0;
    FOR _a IN SELECT * FROM public.partner_advances
               WHERE partner_id = (_line->>'partner_id')::uuid AND status = 'active'
                 AND deducted_amount < amount AND advance_date <= _to
               ORDER BY advance_date, created_at, id FOR UPDATE LOOP
      EXIT WHEN _left <= 0;
      _take := LEAST(round(_a.amount - _a.deducted_amount, 2), _left);
      CONTINUE WHEN _take <= 0;
      UPDATE public.partner_advances SET deducted_amount = round(deducted_amount + _take, 2) WHERE id = _a.id;
      INSERT INTO public.partner_advance_settlements (company_id, distribution_id, advance_id, partner_id, amount)
      VALUES (_company, _dist, _a.id, _a.partner_id, _take);
      _left := round(_left - _take, 2);
      _partner_adv := _partner_adv + _take;
    END LOOP;
    IF _partner_adv > 0 THEN
      INSERT INTO public.partner_ledger_transactions (company_id, partner_id, transaction_type, amount, currency,
        reference_type, reference_id, description, transaction_date, status, created_by)
      VALUES (_company, (_line->>'partner_id')::uuid, 'adjustment', -_partner_adv, COALESCE(_currency, 'EGP'),
        'partner_advance', _dist, 'خصم سلف الشريك', _to, 'active', _profile);
    END IF;
  END LOOP;

  UPDATE public.profit_distributions SET tab_deducted = round(_tab_total, 2), loan_repaid = round(_loan_total, 2)
   WHERE id = _dist;

  IF (_calc->>'development_fund')::numeric > 0 THEN
    INSERT INTO public.development_fund_ledger (company_id, direction, amount, distribution_id, entry_date, description, created_by)
    VALUES (_company, 'in', (_calc->>'development_fund')::numeric, _dist, public.business_today(_company),
      'حجز صندوق التطوير من أرباح ' || _from || ' إلى ' || _to, _profile);
  END IF;

  PERFORM public.log_audit('finance.payout', 'partners', 'profit_distributions', _dist, NULL,
    _calc - 'pnl' || jsonb_build_object('tab_deducted', _tab_total, 'loan_repaid', _loan_total), _notes, NULL);
  RETURN _dist;
END $function$;

-- 7. Patch readers that summed every contribution as capital ---------------
DO $$
DECLARE _def text; _new text;
BEGIN
  -- reverse_payout: undo loan repayments too.
  _def := pg_get_functiondef('public.reverse_payout(uuid,text)'::regprocedure);
  _new := replace(_def, $a$('profit_distribution', 'partner_tab', 'partner_advance')$a$,
                        $a$('profit_distribution', 'partner_tab', 'partner_advance', 'partner_loan')$a$);
  _new := replace(_new, '  -- Development fund.',
$a$  -- Partner loans: owed again exactly as before the payout.
  UPDATE public.partner_capital_contributions c SET repaid_amount = GREATEST(round(c.repaid_amount - r.amount, 2), 0)
    FROM public.partner_loan_repayments r
   WHERE r.distribution_id = _d.id AND r.status = 'active' AND r.contribution_id = c.id;
  UPDATE public.partner_loan_repayments SET status = 'reversed' WHERE distribution_id = _d.id AND status = 'active';

  -- Development fund.$a$);
  IF _new = _def OR _new !~ 'partner_loan_repayments' OR _new !~ $a$'partner_advance', 'partner_loan'\)$a$ THEN
    RAISE EXCEPTION 'reverse_payout: patch did not apply';
  END IF;
  EXECUTE _new;

  _def := pg_get_functiondef('public.get_my_partner_profit_summary'::regproc);
  _new := replace(_def, $a$cc.status = 'active'$a$, $a$cc.status = 'active' AND cc.kind = 'capital'$a$);
  IF (length(_new) - length(_def)) <> 2 * length($a$ AND cc.kind = 'capital'$a$) THEN
    RAISE EXCEPTION 'get_my_partner_profit_summary: patch did not apply';
  END IF;
  EXECUTE _new;

  _def := pg_get_functiondef('public.my_owner_statement'::regproc);
  _new := replace(_def, $a$WHERE partner_id = v_p.id AND status = 'active';$a$,
                        $a$WHERE partner_id = v_p.id AND status = 'active' AND kind = 'capital';$a$);
  _new := replace(_new, $a$c.status = 'active' AND p.status = 'active'$a$,
                        $a$c.status = 'active' AND c.kind = 'capital' AND p.status = 'active'$a$);
  IF (length(_new) - length(_def)) <> length($a$ AND kind = 'capital'$a$) + length($a$ AND c.kind = 'capital'$a$) THEN
    RAISE EXCEPTION 'my_owner_statement: patch did not apply';
  END IF;
  EXECUTE _new;
END $$;

-- partner_ownership: capital only (same columns), plus open loans at the end.
CREATE OR REPLACE VIEW public.partner_ownership WITH (security_invoker = true) AS
 WITH capital AS (
         SELECT c.partner_id, sum(c.amount) AS total
           FROM public.partner_capital_contributions c
          WHERE c.status = 'active'::record_status AND c.kind = 'capital'
          GROUP BY c.partner_id
        ), loans AS (
         SELECT c.partner_id, sum(c.amount - c.repaid_amount) AS open
           FROM public.partner_capital_contributions c
          WHERE c.status = 'active'::record_status AND c.kind = 'loan'
          GROUP BY c.partner_id
        ), company_capital AS (
         SELECT p_1.company_id, sum(COALESCE(c_1.total, 0::numeric)) AS total
           FROM public.partners p_1
             LEFT JOIN capital c_1 ON c_1.partner_id = p_1.id
          WHERE p_1.status <> 'exited'::partner_status
          GROUP BY p_1.company_id
        )
 SELECT p.id AS partner_id,
    p.company_id,
    p.name,
    COALESCE(c.total, 0::numeric) AS total_contributions,
    COALESCE(p.profit_share_percentage,
        CASE
            WHEN cc.total > 0::numeric THEN round(COALESCE(c.total, 0::numeric) * 100.0 / cc.total, 4)
            ELSE 0::numeric
        END) AS ownership_percentage,
    COALESCE(l.open, 0::numeric) AS open_loans
   FROM public.partners p
     LEFT JOIN capital c ON c.partner_id = p.id
     LEFT JOIN loans l ON l.partner_id = p.id
     LEFT JOIN company_capital cc ON cc.company_id = p.company_id
  WHERE p.status <> 'exited'::partner_status;

-- 8. Grants + hourly refresh (new shares start on the 1st) ------------------
REVOKE ALL ON FUNCTION public._capital_shares(uuid, date, uuid, numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._partner_shares_at(uuid, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.apply_partner_shares(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.apply_partner_shares_all() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.trg_partner_share_snapshot() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.trg_contribution_effective_from() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.preview_partner_contribution(uuid, numeric, text, date) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.record_partner_contribution(uuid, numeric, text, date, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.preview_partner_contribution(uuid, numeric, text, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_partner_contribution(uuid, numeric, text, date, text, text, text) TO authenticated;

SELECT cron.schedule('apply-partner-shares', '7 * * * *', 'SELECT public.apply_partner_shares_all()');
SELECT public.apply_partner_shares_all();
