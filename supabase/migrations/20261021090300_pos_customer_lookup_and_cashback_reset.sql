-- =====================================================================
-- 1) pos_customer_lookup: as the cashier types a phone number (3+ digits) the
--    till shows matching saved customers. Works for anyone who can sell
--    (pos.create_order), with no loyalty permission, and returns only what the
--    till needs: name, phone, code and wallet balance.
-- 2) reset_cashback_progress: the super admin restarts the cashback target
--    for one customer or for every customer. Only the progress toward the
--    next reward is zeroed; wallet money already earned stays.
-- 3) set_cashback_settings accepts turning cashback off without re-typing
--    the target and reward.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.pos_customer_lookup(_term text)
RETURNS TABLE (id uuid, code text, name text, phone text, wallet_balance numeric, cashback_progress numeric, points_balance integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _t text := regexp_replace(COALESCE(_term, ''), '[%,()_\\]', '', 'g');
  _digits text := regexp_replace(COALESCE(_term, ''), '\D', '', 'g');
BEGIN
  IF public.current_profile_id() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('pos.create_order') OR public.has_permission('loyalty.view') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF length(btrim(_t)) < 3 THEN RETURN; END IF;
  RETURN QUERY
  SELECT c.id, c.code, c.name, c.phone, c.wallet_balance, c.cashback_progress, c.points_balance
    FROM public.customers c
   WHERE c.company_id = public.current_company_id() AND c.is_active
     AND ((length(_digits) >= 3 AND regexp_replace(COALESCE(c.phone, ''), '\D', '', 'g') LIKE '%' || _digits || '%')
          OR c.code ILIKE '%' || btrim(_t) || '%'
          OR c.name ILIKE '%' || btrim(_t) || '%')
   ORDER BY c.last_visit_at DESC NULLS LAST
   LIMIT 8;
END $$;
REVOKE EXECUTE ON FUNCTION public.pos_customer_lookup(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pos_customer_lookup(text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.reset_cashback_progress(_customer_id uuid DEFAULT NULL, _reason text DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _company uuid := public.current_company_id(); _n int;
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only the Super Admin can restart cashback targets'; END IF;
  WITH changed AS (
    UPDATE public.customers SET cashback_progress = 0, updated_at = now()
     WHERE company_id = _company AND cashback_progress <> 0
       AND (_customer_id IS NULL OR id = _customer_id)
    RETURNING id, cashback_progress)
  SELECT count(*) INTO _n FROM changed;
  PERFORM public.log_audit('cashback.reset', 'loyalty', 'customers', _customer_id, NULL,
    jsonb_build_object('scope', CASE WHEN _customer_id IS NULL THEN 'all' ELSE 'one' END, 'customers', _n),
    NULLIF(btrim(COALESCE(_reason, '')), ''), NULL);
  RETURN _n;
END $$;
REVOKE EXECUTE ON FUNCTION public.reset_cashback_progress(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reset_cashback_progress(uuid, text) TO authenticated, service_role;

-- Turning cashback off keeps the last target and reward.
CREATE OR REPLACE FUNCTION public.set_cashback_settings(_enabled boolean, _target_amount numeric, _reward_amount numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _company uuid := public.current_company_id(); _value jsonb; _old jsonb := public.cashback_config(public.current_company_id());
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only the Super Admin can change cashback rules'; END IF;
  IF NOT COALESCE(_enabled, false) THEN
    _target_amount := COALESCE(NULLIF(_target_amount, 0), (_old->>'target_amount')::numeric, 0);
    _reward_amount := COALESCE(NULLIF(_reward_amount, 0), (_old->>'reward_amount')::numeric, 0);
  ELSE
    IF COALESCE(_target_amount, 0) <= 0 OR COALESCE(_reward_amount, 0) <= 0 THEN
      RAISE EXCEPTION 'Target and reward must be greater than zero';
    END IF;
    IF _reward_amount >= _target_amount THEN RAISE EXCEPTION 'The reward must be smaller than the spend target'; END IF;
  END IF;
  _value := jsonb_build_object('enabled', COALESCE(_enabled, false),
    'target_amount', round(COALESCE(_target_amount, 0), 2), 'reward_amount', round(COALESCE(_reward_amount, 0), 2));
  INSERT INTO public.app_settings (company_id, scope, key, value) VALUES (_company, 'company', 'cashback', _value)
  ON CONFLICT DO NOTHING;
  UPDATE public.app_settings SET value = _value, updated_at = now() WHERE company_id = _company AND key = 'cashback';
  PERFORM public.log_audit('cashback.settings', 'loyalty', 'app_settings', NULL, _old, _value, NULL, NULL);
  RETURN public.cashback_config(_company);
END $$;
