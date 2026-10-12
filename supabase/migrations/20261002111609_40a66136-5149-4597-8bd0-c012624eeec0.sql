CREATE OR REPLACE FUNCTION public.settle_partner_negative_balance(_partner_id uuid, _mode text, _amount numeric DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _company uuid; _bal numeric; _amt numeric; _acc uuid; _cash uuid; _ledger uuid;
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Super Admin only'; END IF;
  SELECT company_id INTO _company FROM public.partners WHERE id = _partner_id;
  IF _company IS NULL OR _company <> public.current_company_id() THEN RAISE EXCEPTION 'Partner not found'; END IF;
  _bal := public.partner_balance(_partner_id);
  IF _bal >= 0 THEN RAISE EXCEPTION 'رصيد الشريك ليس سالبًا'; END IF;
  IF _mode = 'carry' THEN
    PERFORM public.log_audit('partner.negative_carry','partners','partners',_partner_id,NULL,
      jsonb_build_object('balance',_bal),'ترحيل للخصم من الأرباح القادمة',NULL);
    RETURN jsonb_build_object('mode','carry','balance',_bal);
  ELSIF _mode = 'cash' THEN
    _amt := round(COALESCE(_amount, -_bal), 2);
    IF _amt <= 0 OR _amt > -_bal THEN RAISE EXCEPTION 'مبلغ السداد غير صالح'; END IF;
    _acc := public.default_cash_account(_company, 'cash');
    _cash := public.post_cash_txn(_company, _acc, 'in', _amt, 'partner_repayment', 'cash', CURRENT_DATE,
      'partner_repayment', _partner_id, 'سداد نقدي من الشريك لتسوية رصيد سالب', NULL, false);
    INSERT INTO public.partner_ledger_transactions(company_id, partner_id, transaction_type, amount, reference_type, reference_id, description, created_by)
    VALUES (_company, _partner_id, 'adjustment', _amt, 'cash_transaction', _cash, 'سداد نقدي يدوي لرصيد سالب', public.current_profile_id())
    RETURNING id INTO _ledger;
    PERFORM public.log_audit('partner.negative_repay','partners','partners',_partner_id,NULL,
      jsonb_build_object('balance_before',_bal,'amount',_amt,'cash_txn',_cash),NULL,NULL);
    RETURN jsonb_build_object('mode','cash','amount',_amt,'ledger_id',_ledger);
  END IF;
  RAISE EXCEPTION 'Invalid mode';
END $$;
REVOKE EXECUTE ON FUNCTION public.settle_partner_negative_balance(uuid,text,numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.settle_partner_negative_balance(uuid,text,numeric) TO authenticated;