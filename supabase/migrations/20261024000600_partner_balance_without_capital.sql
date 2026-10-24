-- =====================================================================
-- Partner and treasury cards, audited 2026-10-24.
--
-- 1. A partner's balance is what they can take out: distributed profit
--    + loan repayments − withdrawals − tab deductions − open advances.
--    Capital was being added to it (every partner showed their whole
--    capital, e.g. 200,000, as "owed to the partner", and could request
--    it as a withdrawal). Capital now only comes back on liquidation.
--    The partner dashboard already described the balance this way.
-- 2. The treasury "open drawers" card counted only the opening float of
--    an open shift. It now counts what should be in the drawer now
--    (float + cash sales − cash refunds − drawer expenses), the same
--    figure as the live position panel.
-- No data is changed.
-- =====================================================================

-- Capital booked to the partner's ledger, less any capital returned on liquidation.
CREATE OR REPLACE FUNCTION public._partner_ledger_capital(_partner_id uuid)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT round(COALESCE(SUM(CASE WHEN t.transaction_type = 'withdrawal' THEN -abs(t.amount) ELSE t.amount END), 0), 2)
    FROM public.partner_ledger_transactions t
   WHERE t.partner_id = _partner_id AND t.status = 'active'
     AND t.reference_type IN ('partner_capital_contributions', 'partner_capital_return')
$$;
REVOKE EXECUTE ON FUNCTION public._partner_ledger_capital(uuid) FROM PUBLIC, anon;

CREATE OR REPLACE FUNCTION public.partner_balance(_partner_id uuid)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT round(
    COALESCE((SELECT SUM(CASE WHEN t.transaction_type = 'withdrawal' THEN -abs(t.amount) ELSE t.amount END)
                FROM public.partner_ledger_transactions t
               WHERE t.partner_id = _partner_id AND t.status = 'active'
                 AND COALESCE(t.reference_type, '') NOT IN ('partner_capital_contributions', 'partner_capital_return')), 0)
    - COALESCE((SELECT SUM(a.amount - a.deducted_amount) FROM public.partner_advances a
                 WHERE a.partner_id = _partner_id AND a.status = 'active'), 0), 2)
$function$;

CREATE OR REPLACE VIEW public.partner_balances AS
SELECT p.id AS partner_id,
       p.company_id,
       p.name,
       public.partner_balance(p.id) AS balance,
       public._partner_ledger_capital(p.id) AS capital
  FROM public.partners p;

-- Liquidation settles capital + balance. Two ledger lines so both end at 0:
-- the capital returned, and the balance (paid out, or a negative balance
-- netted from the capital).
CREATE OR REPLACE FUNCTION public.liquidate_partner(_partner_id uuid, _settlement_method text, _cash_account_id uuid DEFAULT NULL::uuid, _notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _partner public.partners;
  _company uuid := public.current_company_id();
  _profile uuid := public.current_profile_id();
  _balance numeric;
  _capital numeric;
  _earned numeric;
  _cash_txn uuid;
  _liquidation uuid := gen_random_uuid();
  _total numeric := 0;
  _running numeric := 0;
  _count int := 0;
  _index int := 0;
  _share numeric;
  _redistribution jsonb := '{}'::jsonb;
  _row record;
  _desc text;
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only the Super Admin can liquidate a partnership'; END IF;
  IF _settlement_method NOT IN ('treasury','bank','ledger') THEN RAISE EXCEPTION 'Invalid settlement method'; END IF;

  SELECT * INTO _partner FROM public.partners
  WHERE id = _partner_id AND company_id = _company FOR UPDATE;
  IF _partner.id IS NULL THEN RAISE EXCEPTION 'Partner not found'; END IF;
  IF _partner.status <> 'active' THEN RAISE EXCEPTION 'Partner is already inactive'; END IF;
  IF EXISTS (
    SELECT 1 FROM public.partner_withdrawal_requests
    WHERE partner_id = _partner_id AND status = 'pending'
  ) THEN RAISE EXCEPTION 'Resolve pending withdrawal requests before liquidation'; END IF;
  IF EXISTS (
    SELECT 1 FROM public.partner_tab_orders
    WHERE partner_id = _partner_id AND NOT is_settled
  ) THEN RAISE EXCEPTION 'Settle partner tabs before liquidation'; END IF;

  SELECT count(*), COALESCE(SUM(COALESCE(po.profit_share_percentage, ow.ownership_percentage,0)),0)
  INTO _count, _total
  FROM public.partners po
  LEFT JOIN public.partner_ownership ow ON ow.partner_id = po.id
  WHERE po.company_id = _company AND po.status = 'active' AND po.id <> _partner_id;
  IF _count = 0 OR _total <= 0 THEN RAISE EXCEPTION 'At least one active partner with equity must remain'; END IF;

  _capital := public._partner_ledger_capital(_partner_id);
  _earned := public.partner_balance(_partner_id);
  _balance := _capital + _earned;
  IF _balance > 0 AND _settlement_method = 'treasury' THEN
    IF _cash_account_id IS NULL THEN RAISE EXCEPTION 'Select a treasury account'; END IF;
    _cash_txn := public.post_cash_txn(
      _company, _cash_account_id, 'out', _balance, 'partner_liquidation', 'cash', public.business_today(),
      'partner_liquidation', _liquidation, 'Partner liquidation: ' || _partner.name, NULL, true
    );
  END IF;

  _desc := COALESCE(NULLIF(_notes,''),'Final partnership settlement (' || _settlement_method || ')');
  IF _capital <> 0 THEN
    INSERT INTO public.partner_ledger_transactions(
      company_id, partner_id, transaction_type, amount, reference_type, reference_id,
      description, transaction_date, created_by
    ) VALUES (
      _company, _partner_id, 'withdrawal', _capital, 'partner_capital_return', _liquidation,
      _desc, public.business_today(), _profile
    );
  END IF;
  IF _earned <> 0 THEN
    INSERT INTO public.partner_ledger_transactions(
      company_id, partner_id, transaction_type, amount, reference_type, reference_id,
      description, transaction_date, created_by
    ) VALUES (
      _company, _partner_id, CASE WHEN _earned > 0 THEN 'withdrawal' ELSE 'adjustment' END, abs(_earned),
      'partner_liquidation', _liquidation, _desc, public.business_today(), _profile
    );
  END IF;

  FOR _row IN
    SELECT po.id, COALESCE(po.profit_share_percentage, ow.ownership_percentage,0) AS current_share
    FROM public.partners po
    LEFT JOIN public.partner_ownership ow ON ow.partner_id = po.id
    WHERE po.company_id = _company AND po.status = 'active' AND po.id <> _partner_id
    ORDER BY po.id
    FOR UPDATE OF po
  LOOP
    _index := _index + 1;
    IF _index = _count THEN
      _share := round(100 - _running, 4);
    ELSE
      _share := round((_row.current_share / _total) * 100, 4);
      _running := _running + _share;
    END IF;
    UPDATE public.partners SET profit_share_percentage = _share, updated_at = now() WHERE id = _row.id;
    _redistribution := _redistribution || jsonb_build_object(_row.id::text, _share);
  END LOOP;

  UPDATE public.partners
  SET status = 'inactive', profit_share_percentage = 0, updated_at = now()
  WHERE id = _partner_id;

  IF round((SELECT COALESCE(SUM(profit_share_percentage),0) FROM public.partners
            WHERE company_id = _company AND status = 'active'),4) <> 100 THEN
    RAISE EXCEPTION 'Active partner equity must total 100%%';
  END IF;

  INSERT INTO public.partner_liquidations(
    id, company_id, partner_id, final_balance, settlement_method, cash_account_id,
    cash_transaction_id, redistribution, notes, performed_by
  ) VALUES (
    _liquidation, _company, _partner_id, _balance, _settlement_method,
    CASE WHEN _settlement_method='treasury' THEN _cash_account_id ELSE NULL END,
    _cash_txn, _redistribution, NULLIF(_notes,''), _profile
  );

  PERFORM public.log_audit(
    'partner.liquidate','partners','partners',_partner_id,to_jsonb(_partner),
    jsonb_build_object('status','inactive','final_balance',_balance,'capital',_capital,'balance',_earned,
      'settlement_method',_settlement_method,'redistribution',_redistribution),
    _notes,NULL
  );
  RETURN _liquidation;
END
$function$;

CREATE OR REPLACE FUNCTION public.treasury_overview()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE _company uuid := public.current_company_id(); _accounts jsonb; _drawers numeric := 0;
BEGIN
  IF NOT (public.has_permission('treasury.view') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', a.id, 'key', a.key, 'name', a.name, 'name_ar', a.name_ar,
    'type', a.account_type, 'is_active', a.is_active, 'balance', public.cash_balance(a.id))
    ORDER BY a.key), '[]'::jsonb) INTO _accounts
  FROM public.cash_accounts a WHERE a.company_id = _company;

  -- What should be in each open drawer now (float + cash sales − cash refunds − drawer expenses).
  SELECT COALESCE(SUM((public._shift_drawer(s)->>'expected')::numeric), 0) INTO _drawers
  FROM public.shifts s
  WHERE s.company_id = _company AND s.status = 'open';

  RETURN jsonb_build_object('accounts', _accounts, 'open_drawers', round(_drawers,2),
    'total', round(COALESCE((SELECT SUM((e->>'balance')::numeric) FROM jsonb_array_elements(_accounts) e),0) + _drawers, 2));
END $function$;
