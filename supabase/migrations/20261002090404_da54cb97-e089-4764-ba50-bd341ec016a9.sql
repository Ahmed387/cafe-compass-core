ALTER TABLE public.partners ADD COLUMN IF NOT EXISTS dividends_paused boolean NOT NULL DEFAULT false;
ALTER TABLE public.accounting_periods ADD COLUMN IF NOT EXISTS is_adjustment boolean NOT NULL DEFAULT false;
ALTER TABLE public.accounting_periods ADD COLUMN IF NOT EXISTS override_until timestamptz;

-- Capital-based equity: share = partner capital / total active capital
CREATE OR REPLACE FUNCTION public.recompute_capital_equity(_company_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE _total numeric;
BEGIN
  SELECT COALESCE(SUM(c.amount),0) INTO _total FROM public.partner_capital_contributions c
   JOIN public.partners p ON p.id=c.partner_id
   WHERE c.company_id=_company_id AND c.status='active' AND p.status='active';
  IF _total <= 0 THEN RETURN; END IF;
  UPDATE public.partners p SET profit_share_percentage = round(COALESCE((
      SELECT SUM(c.amount) FROM public.partner_capital_contributions c
       WHERE c.partner_id=p.id AND c.status='active'),0) * 100.0 / _total, 4)
   WHERE p.company_id=_company_id AND p.status='active';
END $$;
REVOKE ALL ON FUNCTION public.recompute_capital_equity(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.trg_capital_equity()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  IF pg_trigger_depth() > 1 THEN RETURN NULL; END IF;
  PERFORM public.recompute_capital_equity(COALESCE(NEW.company_id, OLD.company_id));
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.trg_capital_equity() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS capital_equity_on_contribution ON public.partner_capital_contributions;
CREATE TRIGGER capital_equity_on_contribution AFTER INSERT OR UPDATE ON public.partner_capital_contributions
FOR EACH ROW EXECUTE FUNCTION public.trg_capital_equity();
DROP TRIGGER IF EXISTS capital_equity_on_status ON public.partners;
CREATE TRIGGER capital_equity_on_status AFTER UPDATE OF status ON public.partners
FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status) EXECUTE FUNCTION public.trg_capital_equity();

SELECT public.recompute_capital_equity(id) FROM public.companies;

-- Pause dividends toggle (Super Admin only)
CREATE OR REPLACE FUNCTION public.set_partner_dividends_paused(_partner_id uuid, _paused boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  UPDATE public.partners SET dividends_paused=_paused, updated_at=now()
   WHERE id=_partner_id AND company_id=public.current_company_id();
  IF NOT FOUND THEN RAISE EXCEPTION 'Partner not found'; END IF;
  PERFORM public.log_audit('partner.dividends_paused','partners','partners',_partner_id,NULL,jsonb_build_object('paused',_paused),NULL,NULL);
END $$;
REVOKE ALL ON FUNCTION public.set_partner_dividends_paused(uuid,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_partner_dividends_paused(uuid,boolean) TO authenticated, service_role;

-- Paused partners are treated like frozen for every profit run: their share stays retained.
CREATE OR REPLACE FUNCTION public.trg_pause_on_freeze()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  IF NEW.distribution_frozen AND NOT COALESCE(OLD.distribution_frozen,false) THEN
    INSERT INTO public.partner_period_freezes(period_id, partner_id, company_id)
    SELECT NEW.id, p.id, NEW.company_id FROM public.partners p
     WHERE p.company_id=NEW.company_id AND p.dividends_paused AND p.status='active'
       AND NOT EXISTS (SELECT 1 FROM public.partner_period_freezes f WHERE f.period_id=NEW.id AND f.partner_id=p.id);
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.trg_pause_on_freeze() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS pause_on_freeze ON public.accounting_periods;
CREATE TRIGGER pause_on_freeze AFTER UPDATE OF distribution_frozen ON public.accounting_periods
FOR EACH ROW EXECUTE FUNCTION public.trg_pause_on_freeze();

-- Period lock: Super Admin may only write into a closed period during an explicit, audited override window.
CREATE OR REPLACE FUNCTION public.assert_period_open(_company_id uuid, _date date)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF _company_id IS NULL OR _date IS NULL THEN RETURN; END IF;
  IF EXISTS (
    SELECT 1 FROM public.accounting_periods ap
    WHERE ap.company_id = _company_id AND ap.status = 'closed'
      AND _date BETWEEN ap.start_date AND ap.end_date
      AND NOT (public.is_super_admin() AND ap.override_until IS NOT NULL AND ap.override_until > now())
  ) THEN
    RAISE EXCEPTION 'The accounting period covering % is closed and locked', _date;
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.override_locked_period(_period_id uuid, _reason text, _minutes integer DEFAULT 15)
RETURNS timestamptz LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE _until timestamptz;
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF COALESCE(length(trim(_reason)),0) < 5 THEN RAISE EXCEPTION 'A reason is required'; END IF;
  _until := now() + make_interval(mins => LEAST(GREATEST(_minutes,1),60));
  UPDATE public.accounting_periods SET override_until=_until
   WHERE id=_period_id AND company_id=public.current_company_id() AND status='closed';
  IF NOT FOUND THEN RAISE EXCEPTION 'Closed period not found'; END IF;
  PERFORM public.log_audit('period.override_unlock','finance','accounting_periods',_period_id,NULL,
    jsonb_build_object('override_until',_until),_reason,NULL);
  RETURN _until;
END $$;
REVOKE ALL ON FUNCTION public.override_locked_period(uuid,text,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.override_locked_period(uuid,text,integer) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.create_adjustment_period(_period_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE _p public.accounting_periods; _id uuid;
BEGIN
  IF NOT (public.has_permission('periods.manage') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  SELECT * INTO _p FROM public.accounting_periods WHERE id=_period_id AND company_id=public.current_company_id();
  IF _p.id IS NULL OR _p.status<>'closed' THEN RAISE EXCEPTION 'Closed period not found'; END IF;
  INSERT INTO public.accounting_periods(company_id, period_type, start_date, end_date, status, is_adjustment)
  VALUES(_p.company_id,'custom',current_date,current_date,'open',true) RETURNING id INTO _id;
  PERFORM public.log_audit('period.adjustment_created','finance','accounting_periods',_id,NULL,jsonb_build_object('source_period',_period_id),NULL,NULL);
  RETURN _id;
END $$;
REVOKE ALL ON FUNCTION public.create_adjustment_period(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_adjustment_period(uuid) TO authenticated, service_role;