ALTER TABLE public.accounting_periods ADD COLUMN IF NOT EXISTS is_open_ended boolean NOT NULL DEFAULT false;

CREATE UNIQUE INDEX IF NOT EXISTS accounting_periods_one_open_ended
  ON public.accounting_periods(company_id) WHERE is_open_ended AND deleted_at IS NULL;

DROP FUNCTION IF EXISTS public.initialize_accounting_period(date, date, period_type);
CREATE FUNCTION public.initialize_accounting_period(_start_date date DEFAULT NULL, _end_date date DEFAULT NULL, _period_type period_type DEFAULT 'monthly', _open_ended boolean DEFAULT false)
 RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE _profile uuid := public.current_profile_id(); _company uuid := public.current_company_id(); _s date; _e date; _id uuid;
BEGIN
  IF _profile IS NULL OR _company IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('periods.manage') OR public.has_permission('settings.manage') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF _start_date IS NULL THEN
    SELECT (MAX(ap.end_date) + 1) INTO _s FROM public.accounting_periods ap WHERE ap.company_id=_company AND ap.deleted_at IS NULL;
    _s := COALESCE(_s, date_trunc('month', CURRENT_DATE)::date);
  ELSE _s := _start_date; END IF;
  IF COALESCE(_open_ended,false) THEN
    IF EXISTS (SELECT 1 FROM public.accounting_periods ap WHERE ap.company_id=_company AND ap.deleted_at IS NULL AND ap.is_open_ended)
      THEN RAISE EXCEPTION 'An open-ended period is already running. Close it first'; END IF;
    _e := DATE '9999-12-31';
  ELSE
    _e := COALESCE(_end_date, (date_trunc('month', _s::timestamp) + interval '1 month - 1 day')::date);
  END IF;
  IF _e < _s THEN RAISE EXCEPTION 'End date must be on or after the start date'; END IF;
  IF EXISTS (SELECT 1 FROM public.accounting_periods ap WHERE ap.company_id=_company AND ap.deleted_at IS NULL AND ap.start_date <= _e AND ap.end_date >= _s)
    THEN RAISE EXCEPTION 'A period already exists for this date range'; END IF;
  INSERT INTO public.accounting_periods (company_id, period_type, start_date, end_date, status, is_open_ended)
  VALUES (_company, CASE WHEN _open_ended THEN 'custom' ELSE COALESCE(_period_type,'monthly') END, _s, _e, 'open', COALESCE(_open_ended,false)) RETURNING id INTO _id;
  PERFORM public.log_audit('period.create','settings','accounting_periods',_id,NULL,jsonb_build_object('start_date',_s,'end_date',_e,'open_ended',_open_ended),NULL,NULL);
  RETURN _id;
END $function$;

DROP FUNCTION IF EXISTS public.close_accounting_period(uuid);
CREATE FUNCTION public.close_accounting_period(_period_id uuid, _end_date date DEFAULT NULL)
 RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE _profile uuid := public.current_profile_id(); _p public.accounting_periods;
  _open_shifts integer := 0; _open_orders integer := 0; _pending_orders integer := 0; _end date;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('periods.manage') OR public.has_permission('settings.manage') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  SELECT * INTO _p FROM public.accounting_periods WHERE id = _period_id AND company_id = public.current_company_id();
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Period not found'; END IF;
  IF _p.status = 'closed' THEN RAISE EXCEPTION 'Period is already closed'; END IF;

  IF _p.is_open_ended THEN
    IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only a Super Admin can close an open-ended period'; END IF;
    _end := COALESCE(_end_date, CURRENT_DATE);
    IF _end < _p.start_date THEN RAISE EXCEPTION 'End date must be on or after the start date'; END IF;
    IF _end > CURRENT_DATE THEN RAISE EXCEPTION 'End date cannot be in the future'; END IF;
  ELSE
    _end := _p.end_date;
  END IF;

  SELECT count(*) INTO _open_shifts FROM public.shifts s
   WHERE s.company_id = _p.company_id AND s.status = 'open' AND s.opened_at::date <= _end;
  IF _open_shifts > 0 THEN RAISE EXCEPTION 'Close the % open shift(s) in this period first', _open_shifts; END IF;
  SELECT count(*) INTO _open_orders FROM public.orders o
   WHERE o.company_id = _p.company_id AND o.status = 'open' AND o.created_at::date BETWEEN _p.start_date AND _end;
  IF _open_orders > 0 THEN RAISE EXCEPTION 'Settle the % unpaid order(s) in this period first', _open_orders; END IF;
  SELECT count(*) INTO _pending_orders FROM public.orders o
   WHERE o.company_id = _p.company_id AND o.status = 'pending' AND o.created_at::date BETWEEN _p.start_date AND _end;
  IF _pending_orders > 0 THEN RAISE EXCEPTION 'Hand over the % order(s) still awaiting delivery in this period first', _pending_orders; END IF;

  UPDATE public.accounting_periods
     SET status = 'closed', closed_at = now(), closed_by = _profile, end_date = _end, is_open_ended = false
   WHERE id = _period_id;

  PERFORM public.log_audit('period.close','finance','accounting_periods',_period_id,
    jsonb_build_object('status','open','end_date',_p.end_date), jsonb_build_object('status','closed','end_date',_end), NULL, NULL);
  RETURN _period_id;
END;
$function$;

-- Latest purchase price becomes the item cost for any priced stock-in
CREATE OR REPLACE FUNCTION public.sync_latest_item_cost()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.movement_type = 'purchase' AND COALESCE(NEW.unit_cost,0) > 0 THEN
    UPDATE public.inventory_items SET cost_per_unit = NEW.unit_cost, updated_at = now()
     WHERE id = NEW.item_id AND cost_per_unit IS DISTINCT FROM NEW.unit_cost;
  END IF;
  RETURN NEW;
END $function$;
REVOKE EXECUTE ON FUNCTION public.sync_latest_item_cost() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS t_sync_latest_item_cost ON public.stock_movements;
CREATE TRIGGER t_sync_latest_item_cost AFTER INSERT ON public.stock_movements
  FOR EACH ROW EXECUTE FUNCTION public.sync_latest_item_cost();

-- One-time reset: replace legacy periods (no distributions exist) with an open-ended period from 2026-09-18
ALTER TABLE public.accounting_periods DISABLE TRIGGER USER;
DELETE FROM public.period_partner_shares;
DELETE FROM public.accounting_periods;
INSERT INTO public.accounting_periods (company_id, period_type, start_date, end_date, status, is_open_ended)
SELECT id, 'custom', DATE '2026-09-18', DATE '9999-12-31', 'open', true FROM public.companies;
ALTER TABLE public.accounting_periods ENABLE TRIGGER USER;