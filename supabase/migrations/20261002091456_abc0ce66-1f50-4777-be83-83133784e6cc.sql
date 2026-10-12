CREATE OR REPLACE FUNCTION public.override_locked_period(_period_id uuid, _reason text, _minutes integer DEFAULT NULL)
RETURNS timestamptz LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF COALESCE(length(trim(_reason)),0) < 5 THEN RAISE EXCEPTION 'A reason is required'; END IF;
  UPDATE public.accounting_periods SET override_until='infinity'
   WHERE id=_period_id AND company_id=public.current_company_id() AND status='closed';
  IF NOT FOUND THEN RAISE EXCEPTION 'Closed period not found'; END IF;
  PERFORM public.log_audit('period.override_unlock','finance','accounting_periods',_period_id,NULL,
    jsonb_build_object('unlocked_at',now(),'super_admin_profile',public.current_profile_id()),_reason,NULL);
  RETURN 'infinity'::timestamptz;
END $$;

CREATE OR REPLACE FUNCTION public.relock_period(_period_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE _p public.accounting_periods; _old public.profit_distributions; _new uuid; _profile uuid := public.current_profile_id();
  _net numeric; _redistributed boolean := false;
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  SELECT * INTO _p FROM public.accounting_periods WHERE id=_period_id AND company_id=public.current_company_id() FOR UPDATE;
  IF _p.id IS NULL OR _p.status<>'closed' THEN RAISE EXCEPTION 'Closed period not found'; END IF;
  IF _p.override_until IS NULL OR _p.override_until <= now() THEN RAISE EXCEPTION 'Period is not unlocked'; END IF;

  -- Refresh equity snapshot from capital-based percentages
  PERFORM public.recompute_capital_equity(_p.company_id);
  UPDATE public.period_partner_shares s SET ownership_percentage = CASE WHEN p.status='active' THEN COALESCE(p.profit_share_percentage,0) ELSE 0 END
    FROM public.partners p WHERE p.id=s.partner_id AND s.period_id=_period_id;
  INSERT INTO public.period_partner_shares(company_id,period_id,partner_id,ownership_percentage,created_by)
  SELECT _p.company_id,_period_id,p.id,p.profit_share_percentage,_profile FROM public.partners p
   WHERE p.company_id=_p.company_id AND p.status='active' AND COALESCE(p.profit_share_percentage,0)>0
     AND NOT EXISTS (SELECT 1 FROM public.period_partner_shares s WHERE s.period_id=_period_id AND s.partner_id=p.id);
  -- Respect current Pause Dividends toggles
  INSERT INTO public.partner_period_freezes(period_id,partner_id,company_id)
  SELECT _period_id,p.id,_p.company_id FROM public.partners p
   WHERE p.company_id=_p.company_id AND p.dividends_paused AND p.status='active'
     AND NOT EXISTS (SELECT 1 FROM public.partner_period_freezes f WHERE f.period_id=_period_id AND f.partner_id=p.id);

  -- Reverse previous distribution append-only, then redistribute on updated net profit
  SELECT * INTO _old FROM public.profit_distributions WHERE period_id=_period_id AND status='active' LIMIT 1;
  IF _old.id IS NOT NULL THEN
    INSERT INTO public.partner_ledger_transactions(company_id,partner_id,transaction_type,amount,currency,reference_type,reference_id,description,transaction_date,status,reversal_of,created_by)
    SELECT company_id,partner_id,'adjustment',-amount,currency,'profit_distribution_reversal',_old.id,'عكس توزيع أرباح لإعادة الاحتساب',transaction_date,'active',id,_profile
      FROM public.partner_ledger_transactions WHERE reference_id=_old.id AND status='active'
       AND reference_type IN ('profit_distribution','partner_tab');
    UPDATE public.partner_tab_orders SET is_settled=false, settled_at=NULL, distribution_id=NULL WHERE distribution_id=_old.id;
    UPDATE public.profit_distributions SET status='reversed' WHERE id=_old.id;
    _redistributed := true;
  END IF;

  _net := (public.period_distribution(_period_id)->>'distributable')::numeric;
  IF _p.distribution_frozen AND (_redistributed OR COALESCE(_net,0) > 0) AND COALESCE(_net,0) > 0 THEN
    _new := public.distribute_period_profit(_period_id);
  END IF;

  UPDATE public.accounting_periods SET override_until=NULL WHERE id=_period_id;
  PERFORM public.log_audit('period.relock','finance','accounting_periods',_period_id,
    jsonb_build_object('previous_distribution',_old.id,'previous_net',_old.net_profit),
    jsonb_build_object('relocked_at',now(),'net_profit',_net,'new_distribution',_new,'super_admin_profile',_profile),NULL,NULL);
  RETURN jsonb_build_object('net_profit',_net,'distribution_id',_new,'reversed',_old.id);
END $$;
REVOKE ALL ON FUNCTION public.relock_period(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.relock_period(uuid) TO authenticated, service_role;