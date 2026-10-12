CREATE OR REPLACE FUNCTION public.reverse_period_dividend_payouts(_period_id uuid, _profile uuid)
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE _pp public.partner_dividend_payouts; _c public.cash_transactions; _l public.partner_ledger_transactions; _n int := 0;
BEGIN
  FOR _pp IN SELECT * FROM public.partner_dividend_payouts WHERE period_id=_period_id AND status='active' FOR UPDATE LOOP
    SELECT * INTO _c FROM public.cash_transactions WHERE id=_pp.cash_transaction_id AND status='active';
    IF _c.id IS NOT NULL THEN
      INSERT INTO public.cash_transactions(company_id,account_id,direction,amount,method,category,txn_date,reference_type,reference_id,description,status,reversal_of,created_by)
      VALUES(_c.company_id,_c.account_id,CASE WHEN _c.direction='out' THEN 'in' ELSE 'out' END,_c.amount,_c.method,_c.category,CURRENT_DATE,'partner_dividend_reversal',_pp.id,'عكس صرف أرباح بسبب حذف الفترة','active',_c.id,_profile);
      UPDATE public.cash_transactions SET status='reversed' WHERE id=_c.id;
    END IF;
    SELECT * INTO _l FROM public.partner_ledger_transactions WHERE id=_pp.ledger_transaction_id AND status='active';
    IF _l.id IS NOT NULL THEN
      INSERT INTO public.partner_ledger_transactions(company_id,partner_id,transaction_type,amount,currency,reference_type,reference_id,description,transaction_date,status,reversal_of,created_by)
      VALUES(_l.company_id,_l.partner_id,'adjustment',_l.amount,_l.currency,'partner_dividend_reversal',_pp.id,'عكس صرف أرباح بسبب حذف الفترة',CURRENT_DATE,'active',_l.id,_profile);
    END IF;
    UPDATE public.partner_dividend_payouts SET status='reversed' WHERE id=_pp.id;
    _n := _n + 1;
  END LOOP;
  RETURN _n;
END $$;
REVOKE EXECUTE ON FUNCTION public.reverse_period_dividend_payouts(uuid,uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.delete_accounting_period(_period_id uuid, _reason text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE _profile uuid := public.current_profile_id(); _p public.accounting_periods; _d public.profit_distributions;
        _reversed int := 0; _payouts int := 0; _has_history boolean;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only a super admin can delete a period'; END IF;
  IF _reason IS NULL OR length(btrim(_reason)) < 5 THEN RAISE EXCEPTION 'A clear reason is required'; END IF;
  SELECT * INTO _p FROM public.accounting_periods WHERE id=_period_id AND company_id=public.current_company_id() AND deleted_at IS NULL FOR UPDATE;
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Period not found'; END IF;

  _payouts := public.reverse_period_dividend_payouts(_period_id, _profile);

  FOR _d IN SELECT * FROM public.profit_distributions WHERE period_id=_period_id AND status='active' LOOP
    INSERT INTO public.partner_ledger_transactions(company_id,partner_id,transaction_type,amount,currency,reference_type,reference_id,description,transaction_date,status,reversal_of,created_by)
    SELECT company_id,partner_id,'adjustment',-amount,currency,'profit_distribution_reversal',_d.id,'عكس توزيع أرباح بسبب حذف الفترة',transaction_date,'active',id,_profile
      FROM public.partner_ledger_transactions
     WHERE reference_id=_d.id AND status='active' AND reference_type IN ('profit_distribution','partner_tab');
    UPDATE public.partner_tab_orders SET is_settled=false, settled_at=NULL, distribution_id=NULL WHERE distribution_id=_d.id;
    UPDATE public.profit_distributions SET status='reversed' WHERE id=_d.id;
    _reversed := _reversed + 1;
  END LOOP;

  DELETE FROM public.partner_period_freezes WHERE period_id=_period_id;

  _has_history := EXISTS (SELECT 1 FROM public.profit_distributions WHERE period_id=_period_id)
               OR EXISTS (SELECT 1 FROM public.partner_dividend_payouts WHERE period_id=_period_id);

  PERFORM public.log_audit('period.delete','finance','accounting_periods',_period_id,
    to_jsonb(_p), jsonb_build_object('reversed_distributions',_reversed,'reversed_payouts',_payouts,'retired',_has_history), _reason, NULL);

  IF _has_history THEN
    UPDATE public.accounting_periods SET status='open', closed_at=NULL, closed_by=NULL, override_until=NULL,
      deleted_at=now(), deleted_by=_profile, delete_reason=btrim(_reason) WHERE id=_period_id;
  ELSE
    UPDATE public.salary_payments SET accounting_period_id=NULL WHERE accounting_period_id=_period_id;
    UPDATE public.accounting_periods SET status='open' WHERE id=_period_id;
    DELETE FROM public.accounting_periods WHERE id=_period_id;
  END IF;
  RETURN jsonb_build_object('reversed_distributions',_reversed,'reversed_payouts',_payouts,'retired',_has_history);
END $$;
REVOKE EXECUTE ON FUNCTION public.delete_accounting_period(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_accounting_period(uuid,text) TO authenticated;