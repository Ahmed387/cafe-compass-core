-- Phase 2: auditable electronic settlements, frozen profit shares, and editable partner details.

ALTER TABLE public.partners
  ADD COLUMN IF NOT EXISTS profit_share_percentage numeric(7,4)
  CHECK (profit_share_percentage IS NULL OR (profit_share_percentage >= 0 AND profit_share_percentage <= 100));

ALTER TABLE public.accounting_periods
  ADD COLUMN IF NOT EXISTS distribution_frozen boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS distribution_frozen_at timestamptz,
  ADD COLUMN IF NOT EXISTS distribution_frozen_by uuid REFERENCES public.user_profiles(id);

CREATE TABLE public.period_partner_shares (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  period_id uuid NOT NULL REFERENCES public.accounting_periods(id) ON DELETE CASCADE,
  partner_id uuid NOT NULL REFERENCES public.partners(id) ON DELETE RESTRICT,
  ownership_percentage numeric(7,4) NOT NULL CHECK (ownership_percentage >= 0 AND ownership_percentage <= 100),
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (period_id, partner_id)
);
GRANT SELECT ON public.period_partner_shares TO authenticated;
GRANT ALL ON public.period_partner_shares TO service_role;
ALTER TABLE public.period_partner_shares ENABLE ROW LEVEL SECURITY;
CREATE POLICY "period_partner_shares_read" ON public.period_partner_shares FOR SELECT TO authenticated
USING (
  company_id = public.current_company_id()
  AND (
    public.has_permission('partners.view_profit') OR public.has_permission('reports.profit')
    OR public.has_permission('partners.manage_profit_distribution') OR public.is_super_admin()
    OR partner_id = public.current_partner_id()
  )
);

CREATE TABLE public.electronic_payment_settlements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  payment_id uuid NOT NULL REFERENCES public.order_payments(id) ON DELETE RESTRICT,
  account_id uuid NOT NULL REFERENCES public.cash_accounts(id) ON DELETE RESTRICT,
  amount numeric(14,2) NOT NULL CHECK (amount > 0),
  settlement_date date NOT NULL DEFAULT CURRENT_DATE,
  batch_reference text NOT NULL,
  cash_transaction_id uuid NOT NULL REFERENCES public.cash_transactions(id) ON DELETE RESTRICT,
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (payment_id)
);
GRANT SELECT ON public.electronic_payment_settlements TO authenticated;
GRANT ALL ON public.electronic_payment_settlements TO service_role;
ALTER TABLE public.electronic_payment_settlements ENABLE ROW LEVEL SECURITY;
CREATE POLICY "electronic_payment_settlements_read" ON public.electronic_payment_settlements FOR SELECT TO authenticated
USING (company_id = public.current_company_id() AND (public.has_permission('treasury.view') OR public.is_super_admin()));

CREATE OR REPLACE VIEW public.partner_ownership WITH (security_invoker = true) AS
WITH capital AS (
  SELECT partner_id, SUM(amount) AS total
  FROM public.partner_capital_contributions WHERE status = 'active' GROUP BY partner_id
), company_capital AS (
  SELECT p.company_id, SUM(COALESCE(c.total,0)) AS total
  FROM public.partners p LEFT JOIN capital c ON c.partner_id = p.id
  WHERE p.status <> 'exited' GROUP BY p.company_id
)
SELECT p.id AS partner_id, p.company_id, p.name,
  COALESCE(c.total,0) AS total_contributions,
  COALESCE(p.profit_share_percentage,
    CASE WHEN cc.total > 0 THEN ROUND(COALESCE(c.total,0) * 100.0 / cc.total,4) ELSE 0 END
  ) AS ownership_percentage
FROM public.partners p
LEFT JOIN capital c ON c.partner_id = p.id
LEFT JOIN company_capital cc ON cc.company_id = p.company_id
WHERE p.status <> 'exited';

CREATE OR REPLACE FUNCTION public.update_partner_details(
  _partner_id uuid, _name text, _profit_share_percentage numeric DEFAULT NULL
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _old public.partners; _profile uuid := public.current_profile_id();
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('partners.manage') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  SELECT * INTO _old FROM public.partners
  WHERE id=_partner_id AND company_id=public.current_company_id() FOR UPDATE;
  IF _old.id IS NULL THEN RAISE EXCEPTION 'Partner not found'; END IF;
  IF NULLIF(btrim(COALESCE(_name,'')),'') IS NULL THEN RAISE EXCEPTION 'Partner name is required'; END IF;
  IF _profit_share_percentage IS NOT NULL AND (_profit_share_percentage < 0 OR _profit_share_percentage > 100) THEN
    RAISE EXCEPTION 'Profit share must be between 0 and 100';
  END IF;
  UPDATE public.partners SET name=btrim(_name), profit_share_percentage=_profit_share_percentage, updated_at=now()
  WHERE id=_partner_id;
  PERFORM public.log_audit('partner.update','partners','partners',_partner_id,to_jsonb(_old),
    jsonb_build_object('name',btrim(_name),'profit_share_percentage',_profit_share_percentage),NULL,NULL);
END $$;
REVOKE ALL ON FUNCTION public.update_partner_details(uuid,text,numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_partner_details(uuid,text,numeric) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.freeze_profit_distribution(_period_id uuid, _freeze boolean DEFAULT true)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _p public.accounting_periods; _profile uuid := public.current_profile_id(); _sum numeric;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('partners.manage_profit_distribution') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  SELECT * INTO _p FROM public.accounting_periods
  WHERE id=_period_id AND company_id=public.current_company_id() FOR UPDATE;
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Period not found'; END IF;
  IF _p.status <> 'closed' THEN RAISE EXCEPTION 'Close the accounting period first'; END IF;
  IF EXISTS (SELECT 1 FROM public.profit_distributions WHERE period_id=_period_id AND status='active') THEN
    RAISE EXCEPTION 'Distributed periods cannot be changed';
  END IF;
  IF NOT _freeze THEN
    DELETE FROM public.period_partner_shares WHERE period_id=_period_id;
    UPDATE public.accounting_periods SET distribution_frozen=false, distribution_frozen_at=NULL, distribution_frozen_by=NULL WHERE id=_period_id;
  ELSE
    SELECT round(COALESCE(SUM(ownership_percentage),0),4) INTO _sum
    FROM public.partner_ownership po JOIN public.partners p ON p.id=po.partner_id
    WHERE po.company_id=_p.company_id AND p.status='active';
    IF _sum <> 100 THEN RAISE EXCEPTION 'Active partner profit shares must total 100%% (current total: %)', _sum; END IF;
    DELETE FROM public.period_partner_shares WHERE period_id=_period_id;
    INSERT INTO public.period_partner_shares(company_id,period_id,partner_id,ownership_percentage,created_by)
    SELECT _p.company_id,_period_id,po.partner_id,po.ownership_percentage,_profile
    FROM public.partner_ownership po JOIN public.partners p ON p.id=po.partner_id
    WHERE po.company_id=_p.company_id AND p.status='active' AND po.ownership_percentage > 0;
    UPDATE public.accounting_periods SET distribution_frozen=true, distribution_frozen_at=now(), distribution_frozen_by=_profile WHERE id=_period_id;
  END IF;
  PERFORM public.log_audit(CASE WHEN _freeze THEN 'finance.freeze_distribution' ELSE 'finance.unfreeze_distribution' END,
    'partners','accounting_periods',_period_id,NULL,jsonb_build_object('frozen',_freeze,'share_total',COALESCE(_sum,0)),NULL,NULL);
END $$;
REVOKE ALL ON FUNCTION public.freeze_profit_distribution(uuid,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.freeze_profit_distribution(uuid,boolean) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.pending_electronic_payments(_from date, _to date)
RETURNS TABLE(payment_id uuid, order_id uuid, order_number text, branch_id uuid, paid_at timestamptz,
  method_key text, amount numeric, reference text, settled boolean, settlement_date date, batch_reference text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT op.id, o.id, o.order_number, o.branch_id, op.created_at, op.method_key, op.amount, op.reference,
    (s.id IS NOT NULL), s.settlement_date, s.batch_reference
  FROM public.order_payments op
  JOIN public.orders o ON o.id=op.order_id
  LEFT JOIN public.electronic_payment_settlements s ON s.payment_id=op.id
  LEFT JOIN public.payment_methods pm ON pm.id=op.payment_method_id
  WHERE o.company_id=public.current_company_id()
    AND public.can_access_branch(o.branch_id)
    AND (public.has_permission('treasury.view') OR public.is_super_admin())
    AND o.status <> 'cancelled'
    AND op.created_at::date BETWEEN _from AND _to
    AND lower(COALESCE(pm.kind,op.method_key)) IN ('card','visa','bank','transfer','bank_transfer','wallet','instapay','vodafone_cash','e_wallet')
  ORDER BY op.created_at DESC
$$;
REVOKE ALL ON FUNCTION public.pending_electronic_payments(date,date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pending_electronic_payments(date,date) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.settle_electronic_payments(
  _payment_ids uuid[], _settlement_date date, _batch_reference text
) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _profile uuid := public.current_profile_id(); _company uuid := public.current_company_id(); _r record;
  _account uuid; _cash_txn uuid; _count integer := 0; _batch text := NULLIF(btrim(COALESCE(_batch_reference,'')),'');
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('treasury.manage') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF COALESCE(array_length(_payment_ids,1),0)=0 THEN RAISE EXCEPTION 'Select at least one payment'; END IF;
  IF _batch IS NULL THEN RAISE EXCEPTION 'Settlement reference is required'; END IF;
  FOR _r IN
    SELECT op.id, op.amount, op.method_key, o.id order_id, o.branch_id, COALESCE(pm.kind,op.method_key) kind
    FROM public.order_payments op JOIN public.orders o ON o.id=op.order_id
    LEFT JOIN public.payment_methods pm ON pm.id=op.payment_method_id
    WHERE op.id=ANY(_payment_ids) AND o.company_id=_company AND o.status <> 'cancelled'
      AND public.can_access_branch(o.branch_id)
      AND lower(COALESCE(pm.kind,op.method_key)) IN ('card','visa','bank','transfer','bank_transfer','wallet','instapay','vodafone_cash','e_wallet')
      AND NOT EXISTS (SELECT 1 FROM public.electronic_payment_settlements s WHERE s.payment_id=op.id)
    FOR UPDATE OF op
  LOOP
    _account := public.default_cash_account(_company,_r.kind);
    IF _account IS NULL THEN RAISE EXCEPTION 'No active settlement account for %', _r.kind; END IF;
    _cash_txn := public.post_cash_txn(_company,_account,'in',_r.amount,'electronic_settlement',_r.method_key,
      COALESCE(_settlement_date,CURRENT_DATE),'order_payment',_r.id,'Electronic settlement '||_batch,NULL,false);
    INSERT INTO public.electronic_payment_settlements(company_id,payment_id,account_id,amount,settlement_date,batch_reference,cash_transaction_id,created_by)
    VALUES(_company,_r.id,_account,_r.amount,COALESCE(_settlement_date,CURRENT_DATE),_batch,_cash_txn,_profile);
    _count := _count+1;
  END LOOP;
  IF _count=0 THEN RAISE EXCEPTION 'No unsettled electronic payments selected'; END IF;
  PERFORM public.log_audit('treasury.settle_electronic','treasury','electronic_payment_settlements',NULL,NULL,
    jsonb_build_object('count',_count,'settlement_date',COALESCE(_settlement_date,CURRENT_DATE),'batch_reference',_batch),NULL,NULL);
  RETURN _count;
END $$;
REVOKE ALL ON FUNCTION public.settle_electronic_payments(uuid[],date,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.settle_electronic_payments(uuid[],date,text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.distribute_period_profit(_period_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _p public.accounting_periods; _profile uuid := public.current_profile_id(); _net numeric; _currency text;
  _dist uuid; _r record; _txn uuid; _amount numeric; _tab numeric; _deduct numeric; _allocated numeric := 0; _last uuid;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('partners.manage_profit_distribution') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  SELECT * INTO _p FROM public.accounting_periods WHERE id=_period_id AND company_id=public.current_company_id() FOR UPDATE;
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Period not found'; END IF;
  IF _p.status <> 'closed' THEN RAISE EXCEPTION 'Close the accounting period before distributing profit'; END IF;
  IF NOT _p.distribution_frozen THEN RAISE EXCEPTION 'Freeze partner shares before distributing profit'; END IF;
  IF EXISTS (SELECT 1 FROM public.profit_distributions WHERE period_id=_period_id AND status='active') THEN RAISE EXCEPTION 'Profit for this period has already been distributed'; END IF;
  _net := (public.period_distribution(_period_id)->>'distributable')::numeric;
  IF COALESCE(_net,0) <= 0 THEN RAISE EXCEPTION 'There is no distributable profit for this period'; END IF;
  SELECT currency INTO _currency FROM public.companies WHERE id=_p.company_id;
  INSERT INTO public.profit_distributions(company_id,period_id,net_profit,currency,status,distributed_at,created_by)
  VALUES(_p.company_id,_period_id,_net,_currency,'active',now(),_profile) RETURNING id INTO _dist;
  SELECT partner_id INTO _last FROM public.period_partner_shares WHERE period_id=_period_id ORDER BY ownership_percentage DESC,partner_id LIMIT 1;
  FOR _r IN SELECT partner_id,ownership_percentage FROM public.period_partner_shares WHERE period_id=_period_id ORDER BY partner_id LOOP
    _amount := CASE WHEN _r.partner_id=_last THEN round(_net-_allocated,2) ELSE round(_net*_r.ownership_percentage/100.0,2) END;
    _allocated := _allocated+_amount;
    INSERT INTO public.partner_ledger_transactions(company_id,partner_id,transaction_type,amount,currency,reference_type,reference_id,description,transaction_date,status,created_by)
    VALUES(_p.company_id,_r.partner_id,'profit_distribution',_amount,_currency,'profit_distribution',_dist,'Profit distribution',_p.end_date,'active',_profile) RETURNING id INTO _txn;
    INSERT INTO public.profit_distribution_lines(distribution_id,partner_id,ownership_percentage,amount,ledger_transaction_id)
    VALUES(_dist,_r.partner_id,_r.ownership_percentage,_amount,_txn);
    SELECT COALESCE(SUM(t.total_amount),0) INTO _tab FROM public.partner_tab_orders t
    WHERE t.partner_id=_r.partner_id AND NOT t.is_settled AND t.created_at::date<=_p.end_date;
    _deduct := LEAST(_tab,_amount);
    IF _deduct>0 THEN
      INSERT INTO public.partner_ledger_transactions(company_id,partner_id,transaction_type,amount,currency,reference_type,reference_id,description,transaction_date,status,created_by)
      VALUES(_p.company_id,_r.partner_id,'adjustment',-_deduct,_currency,'partner_tab',_dist,'خصم فواتير على الحساب',_p.end_date,'active',_profile);
      UPDATE public.partner_tab_orders SET is_settled=true,settled_at=now(),distribution_id=_dist
      WHERE partner_id=_r.partner_id AND NOT is_settled AND created_at::date<=_p.end_date;
      PERFORM public.log_audit('partner_tab.settle','partners','partner_tab_orders',_dist,NULL,
        jsonb_build_object('partner_id',_r.partner_id,'deducted',_deduct,'dividend',_amount),NULL,NULL);
    END IF;
  END LOOP;
  PERFORM public.log_audit('finance.distribute_profit','partners','profit_distributions',_dist,NULL,
    jsonb_build_object('net_profit',_net,'period_id',_period_id,'shares_frozen',true),NULL,NULL);
  RETURN _dist;
END $$;
REVOKE ALL ON FUNCTION public.distribute_period_profit(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.distribute_period_profit(uuid) TO authenticated, service_role;
