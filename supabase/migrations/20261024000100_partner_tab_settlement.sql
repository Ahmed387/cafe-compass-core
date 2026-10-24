-- =====================================================================
-- Owner rule (2026-10-24): what partners owe for invoices on their account
-- shows in the treasury and finance, and the super admin can settle it at any
-- time, fully or in part, in one of three ways:
--   * payment   - the partner pays cash / InstaPay / wallet / card: the money
--                 goes into that method's treasury account.
--   * deduct    - taken off the partner's balance with the cafe now
--                 (partner ledger 'adjustment', like a payout deduction).
--   * payout    - unchanged: the next profit payout deducts what is still open.
-- The sale itself was already revenue on its day, so settling never touches
-- revenue or net profit; it only changes the treasury (payment), the partner's
-- balance (deduct) and how much the next payout deducts.
-- A settlement can be reversed (status 'reversed' + opposite entries); nothing
-- is ever deleted.
-- =====================================================================

ALTER TABLE public.partner_tab_settlements
  ALTER COLUMN distribution_id DROP NOT NULL,
  ADD COLUMN IF NOT EXISTS mode text NOT NULL DEFAULT 'payout',
  ADD COLUMN IF NOT EXISTS method_key text,
  ADD COLUMN IF NOT EXISTS cash_account_id uuid REFERENCES public.cash_accounts(id),
  ADD COLUMN IF NOT EXISTS cash_txn_id uuid REFERENCES public.cash_transactions(id),
  ADD COLUMN IF NOT EXISTS ledger_txn_id uuid REFERENCES public.partner_ledger_transactions(id),
  ADD COLUMN IF NOT EXISTS batch_id uuid,
  ADD COLUMN IF NOT EXISTS settled_on date,
  ADD COLUMN IF NOT EXISTS notes text,
  ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES public.user_profiles(id);

DO $$ BEGIN
  ALTER TABLE public.partner_tab_settlements
    ADD CONSTRAINT partner_tab_settlements_mode_check CHECK (mode IN ('payout', 'payment', 'deduct')),
    ADD CONSTRAINT partner_tab_settlements_payout_has_distribution CHECK (mode <> 'payout' OR distribution_id IS NOT NULL);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE INDEX IF NOT EXISTS partner_tab_settlements_batch_idx ON public.partner_tab_settlements (batch_id) WHERE batch_id IS NOT NULL;

-- ---------------------------------------------------------------------
-- What each partner owes now, plus the recent manual settlements.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.partner_tabs_due()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _co uuid := public.current_company_id();
BEGIN
  IF public.current_profile_id() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('treasury.view') OR public.has_permission('reports.profit') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  RETURN jsonb_build_object(
    'partners', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'partner_id', p.id, 'name', p.name,
               'open', round(x.open, 2), 'count', x.cnt, 'oldest', x.oldest,
               'balance', public.partner_balance(p.id)) ORDER BY x.open DESC, p.name)
        FROM public.partners p
        JOIN LATERAL (
          SELECT SUM(t.total_amount - t.settled_amount) AS open, count(*) AS cnt, min(t.created_at) AS oldest
            FROM public.partner_tab_orders t
           WHERE t.partner_id = p.id AND NOT t.is_settled AND t.total_amount > t.settled_amount) x ON x.cnt > 0
       WHERE p.company_id = _co), '[]'::jsonb),
    'recent', COALESCE((
      SELECT jsonb_agg(r ORDER BY r->>'created_at' DESC) FROM (
        SELECT jsonb_build_object(
                 'batch_id', s.batch_id, 'partner_id', s.partner_id, 'name', p.name, 'mode', s.mode,
                 'method', s.method_key, 'amount', SUM(s.amount), 'settled_on', s.settled_on,
                 'status', s.status, 'notes', s.notes, 'created_at', min(s.created_at),
                 'by', COALESCE(NULLIF(up.display_name, ''), up.first_name)) AS r
          FROM public.partner_tab_settlements s
          JOIN public.partners p ON p.id = s.partner_id
          LEFT JOIN public.user_profiles up ON up.id = s.created_by
         WHERE s.company_id = _co AND s.batch_id IS NOT NULL
         GROUP BY s.batch_id, s.partner_id, p.name, s.mode, s.method_key, s.settled_on, s.status, s.notes,
                  up.display_name, up.first_name
         ORDER BY min(s.created_at) DESC LIMIT 20) q), '[]'::jsonb));
END $$;

-- ---------------------------------------------------------------------
-- Settle: oldest invoices first, any amount up to what is open.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.settle_partner_tab(_partner_id uuid, _amount numeric, _mode text,
  _method text DEFAULT 'cash', _settled_on date DEFAULT NULL, _notes text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _co uuid := public.current_company_id(); _actor uuid := public.current_profile_id();
  _p public.partners; _open numeric; _bal numeric; _day date; _today date; _batch uuid := gen_random_uuid();
  _left numeric; _take numeric; _t public.partner_tab_orders; _acc uuid; _cash uuid; _ledger uuid;
  _currency text; _alloc jsonb := '[]'::jsonb; _num text;
BEGIN
  IF _actor IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.is_super_admin() OR public.has_permission('treasury.manage')) THEN
    RAISE EXCEPTION 'السوبر أدمن بس هو اللي يسوّي حساب الشريك';
  END IF;
  SELECT * INTO _p FROM public.partners WHERE id = _partner_id AND company_id = _co;
  IF _p.id IS NULL THEN RAISE EXCEPTION 'الشريك مش موجود'; END IF;
  IF _mode NOT IN ('payment', 'deduct') THEN RAISE EXCEPTION 'اختار طريقة التسوية'; END IF;
  _amount := round(COALESCE(_amount, 0), 2);
  IF _amount <= 0 THEN RAISE EXCEPTION 'المبلغ لازم يبقى أكبر من صفر'; END IF;

  _today := public.business_today(_co);
  _day := COALESCE(_settled_on, _today);
  IF _day > _today THEN RAISE EXCEPTION 'تاريخ التسوية مينفعش يكون بعد النهارده'; END IF;
  PERFORM public.assert_period_open(_co, _day);

  PERFORM pg_advisory_xact_lock(hashtext('partner_tab:' || _partner_id::text));
  SELECT COALESCE(SUM(total_amount - settled_amount), 0) INTO _open
    FROM public.partner_tab_orders WHERE partner_id = _partner_id AND NOT is_settled;
  IF _amount > round(_open, 2) THEN
    RAISE EXCEPTION 'المبلغ أكبر من المستحق على الشريك (%)', round(_open, 2);
  END IF;
  _bal := public.partner_balance(_partner_id);

  IF _mode = 'payment' THEN
    _method := COALESCE(NULLIF(_method, ''), 'cash');
    IF public.tender_key(_method) IN ('partner_tab', 'points') THEN RAISE EXCEPTION 'اختار طريقة دفع حقيقية'; END IF;
    _acc := public.default_cash_account(_co, _method);
    IF _acc IS NULL THEN RAISE EXCEPTION 'مفيش خزنة/حساب لطريقة الدفع دي'; END IF;
    _cash := public.post_cash_txn(_co, _acc, 'in', _amount, 'partner_tab_settlement', _method, _day,
      'partner_tab_settlement', _batch, 'سداد حساب الشريك ' || _p.name);
  ELSE
    _method := NULL;
    SELECT currency INTO _currency FROM public.companies WHERE id = _co;
    INSERT INTO public.partner_ledger_transactions (company_id, partner_id, transaction_type, amount, currency,
      reference_type, reference_id, description, transaction_date, status, created_by)
    VALUES (_co, _partner_id, 'adjustment', -_amount, COALESCE(_currency, 'EGP'), 'partner_tab_settlement', _batch,
      'خصم فواتير على الحساب من رصيد الشريك', _day, 'active', _actor)
    RETURNING id INTO _ledger;
  END IF;

  _left := _amount;
  FOR _t IN SELECT * FROM public.partner_tab_orders
             WHERE partner_id = _partner_id AND NOT is_settled AND total_amount > settled_amount
             ORDER BY created_at, id FOR UPDATE LOOP
    EXIT WHEN _left <= 0;
    _take := LEAST(round(_t.total_amount - _t.settled_amount, 2), _left);
    UPDATE public.partner_tab_orders
       SET settled_amount = round(settled_amount + _take, 2),
           is_settled = round(settled_amount + _take, 2) >= total_amount,
           settled_at = CASE WHEN round(settled_amount + _take, 2) >= total_amount THEN now() ELSE settled_at END,
           updated_at = now()
     WHERE id = _t.id;
    INSERT INTO public.partner_tab_settlements (company_id, tab_order_id, partner_id, amount, mode, method_key,
      cash_account_id, cash_txn_id, ledger_txn_id, batch_id, settled_on, notes, created_by)
    VALUES (_co, _t.id, _partner_id, _take, _mode, _method, _acc, _cash, _ledger, _batch, _day,
      NULLIF(btrim(COALESCE(_notes, '')), ''), _actor);
    SELECT order_number INTO _num FROM public.orders WHERE id = _t.order_id;
    _alloc := _alloc || jsonb_build_array(jsonb_build_object('order_number', _num, 'amount', _take));
    _left := round(_left - _take, 2);
  END LOOP;

  PERFORM public.log_audit('partner_tab.settle', 'finance', 'partner_tab_settlements', _batch, NULL,
    jsonb_build_object('partner_id', _partner_id, 'amount', _amount, 'mode', _mode, 'method', _method,
      'open_before', round(_open, 2), 'balance_before', _bal), _notes, NULL);

  RETURN jsonb_build_object('batch_id', _batch, 'amount', _amount, 'mode', _mode, 'method', _method,
    'open_before', round(_open, 2), 'open_after', round(_open - _amount, 2),
    'balance_before', _bal, 'balance_after', public.partner_balance(_partner_id),
    'cash_txn_id', _cash, 'allocations', _alloc);
END $$;

-- ---------------------------------------------------------------------
-- Reverse a manual settlement: the invoices are owed again, the money /
-- balance goes back with opposite entries. Nothing is deleted.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reverse_partner_tab_settlement(_batch_id uuid, _reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _co uuid := public.current_company_id(); _actor uuid := public.current_profile_id();
  _s record; _total numeric := 0; _first public.partner_tab_settlements; _c public.cash_transactions;
  _l public.partner_ledger_transactions;
BEGIN
  IF _actor IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.is_super_admin() OR public.has_permission('treasury.manage')) THEN
    RAISE EXCEPTION 'السوبر أدمن بس هو اللي يسوّي حساب الشريك';
  END IF;
  IF _reason IS NULL OR length(btrim(_reason)) < 3 THEN RAISE EXCEPTION 'اكتب سبب التغيير'; END IF;
  SELECT * INTO _first FROM public.partner_tab_settlements
   WHERE batch_id = _batch_id AND company_id = _co AND status = 'active' ORDER BY created_at LIMIT 1;
  IF _first.id IS NULL THEN RAISE EXCEPTION 'التسوية مش موجودة أو اتلغت قبل كده'; END IF;

  FOR _s IN SELECT * FROM public.partner_tab_settlements
             WHERE batch_id = _batch_id AND company_id = _co AND status = 'active' FOR UPDATE LOOP
    UPDATE public.partner_tab_orders
       SET settled_amount = GREATEST(round(settled_amount - _s.amount, 2), 0),
           is_settled = false, settled_at = NULL, updated_at = now()
     WHERE id = _s.tab_order_id;
    UPDATE public.partner_tab_settlements SET status = 'reversed' WHERE id = _s.id;
    _total := _total + _s.amount;
  END LOOP;

  IF _first.cash_txn_id IS NOT NULL THEN
    SELECT * INTO _c FROM public.cash_transactions WHERE id = _first.cash_txn_id;
    PERFORM public.post_cash_txn(_co, _c.account_id, 'out', _total, 'partner_tab_settlement', _c.method,
      public.business_today(_co), 'partner_tab_settlement', _batch_id, 'إلغاء سداد حساب الشريك: ' || btrim(_reason),
      NULL, false);
  END IF;
  IF _first.ledger_txn_id IS NOT NULL THEN
    SELECT * INTO _l FROM public.partner_ledger_transactions WHERE id = _first.ledger_txn_id;
    INSERT INTO public.partner_ledger_transactions (company_id, partner_id, transaction_type, amount, currency,
      reference_type, reference_id, description, transaction_date, status, created_by, reversal_of)
    VALUES (_co, _l.partner_id, 'adjustment', _total, _l.currency, 'partner_tab_settlement', _batch_id,
      'إلغاء خصم فواتير على الحساب: ' || btrim(_reason), public.business_today(_co), 'active', _actor, _l.id);
  END IF;

  PERFORM public.log_audit('partner_tab.settle_reversed', 'finance', 'partner_tab_settlements', _batch_id, NULL,
    jsonb_build_object('amount', _total, 'mode', _first.mode), btrim(_reason), NULL);
  RETURN jsonb_build_object('batch_id', _batch_id, 'amount', _total, 'reversed', true);
END $$;

REVOKE ALL ON FUNCTION public.partner_tabs_due(), public.settle_partner_tab(uuid, numeric, text, text, date, text),
  public.reverse_partner_tab_settlement(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.partner_tabs_due(), public.settle_partner_tab(uuid, numeric, text, text, date, text),
  public.reverse_partner_tab_settlement(uuid, text) TO authenticated;
