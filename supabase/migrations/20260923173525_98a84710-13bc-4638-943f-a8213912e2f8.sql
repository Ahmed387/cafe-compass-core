DO $$ DECLARE d text; BEGIN
 d := pg_get_functiondef('public.update_partner_details(uuid,text,numeric)'::regprocedure);
 d := replace(d, $x$IF NOT (public.has_permission('partners.manage') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;$x$, $x$IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only the Super Admin can edit partners'; END IF;$x$);
 EXECUTE d;
 d := pg_get_functiondef('public.record_capital_contribution(uuid,numeric,date,text,text,text)'::regprocedure);
 d := replace(d, $x$IF NOT (public.has_permission('partners.manage') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;$x$, $x$IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only the Super Admin can edit partner capital'; END IF;$x$);
 EXECUTE d;
END $$;

DROP FUNCTION public.payout_partner_dividend(uuid,uuid,uuid);
CREATE FUNCTION public.payout_partner_dividend(_period_id uuid, _partner_id uuid, _method text DEFAULT 'cash', _account_id uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE _company uuid := public.current_company_id(); _profile uuid := public.current_profile_id();
  _dist uuid; _line numeric; _ded numeric; _net numeric; _acc uuid; _cash uuid; _txn uuid; _id uuid; _currency text;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only the Super Admin can pay out dividends'; END IF;
  IF _method NOT IN ('cash','bank') THEN RAISE EXCEPTION 'Invalid payout method'; END IF;
  SELECT id INTO _dist FROM public.profit_distributions WHERE period_id=_period_id AND company_id=_company AND status='active';
  IF _dist IS NULL THEN RAISE EXCEPTION 'Profit for this period has not been distributed yet'; END IF;
  IF EXISTS (SELECT 1 FROM public.partner_dividend_payouts WHERE period_id=_period_id AND partner_id=_partner_id AND status='active') THEN RAISE EXCEPTION 'This dividend was already paid out'; END IF;
  SELECT amount INTO _line FROM public.profit_distribution_lines WHERE distribution_id=_dist AND partner_id=_partner_id;
  IF _line IS NULL THEN RAISE EXCEPTION 'This partner has no dividend for this period (frozen or no share)'; END IF;
  SELECT COALESCE(-SUM(amount),0) INTO _ded FROM public.partner_ledger_transactions
   WHERE partner_id=_partner_id AND reference_type='partner_tab' AND reference_id=_dist AND status='active';
  _net := round(_line - _ded, 2);
  SELECT currency INTO _currency FROM public.companies WHERE id=_company;
  IF _net > 0 THEN
    _acc := COALESCE(_account_id, public.default_cash_account(_company, _method));
    IF _method = 'cash' THEN
      IF _acc IS NULL THEN RAISE EXCEPTION 'No cash account available'; END IF;
      _cash := public.post_cash_txn(_company, _acc, 'out', _net, 'partner_dividend', 'cash', CURRENT_DATE, 'partner_dividend', _period_id, 'Partner dividend payout (cash)');
    ELSIF _acc IS NOT NULL THEN
      _cash := public.post_cash_txn(_company, _acc, 'out', _net, 'partner_dividend', 'bank', CURRENT_DATE, 'partner_dividend', _period_id, 'Partner dividend payout (bank / InstaPay)', NULL, false);
    END IF;
    INSERT INTO public.partner_ledger_transactions(company_id,partner_id,transaction_type,amount,currency,reference_type,reference_id,description,transaction_date,status,created_by)
    VALUES(_company,_partner_id,'withdrawal',_net,COALESCE(_currency,'EGP'),'partner_dividend',_dist,
      CASE WHEN _method='cash' THEN 'صرف الأرباح نقداً' ELSE 'صرف الأرباح تحويل بنكي' END,CURRENT_DATE,'active',_profile) RETURNING id INTO _txn;
  END IF;
  INSERT INTO public.partner_dividend_payouts(company_id,period_id,partner_id,distribution_id,amount,cash_transaction_id,ledger_transaction_id,created_by)
  VALUES(_company,_period_id,_partner_id,_dist,_net,_cash,_txn,_profile) RETURNING id INTO _id;
  PERFORM public.log_audit('partner.dividend_payout','partners','partner_dividend_payouts',_id,NULL,
    jsonb_build_object('period_id',_period_id,'dividend',_line,'tab_deducted',_ded,'paid',_net,'method',_method),NULL,NULL);
  RETURN _id;
END $function$;
REVOKE EXECUTE ON FUNCTION public.payout_partner_dividend(uuid,uuid,text,uuid) FROM anon;