-- =====================================================================
-- 2026-10-22 (owner's rules)
-- 1) Cashback levels: the Super Admin sets a list of spend targets, each
--    with its own reward (e.g. 500 -> 25, 1000 -> 60, 2000 -> 150). Spend
--    builds up; every level reached pays its reward into the wallet. After
--    the last level the customer starts again from the first one.
--    A single level behaves exactly like the old "every X -> Y" rule.
-- 2) reset_all_wallets: the Super Admin zeroes every customer wallet. Each
--    balance is taken off with an 'adjust' ledger line, so nothing is deleted
--    and the history shows who did it and why.
-- 3) Offer suggestions can be hidden (and shown again) by the managers.
-- =====================================================================

ALTER TABLE public.customers
  ADD COLUMN IF NOT EXISTS cashback_level integer NOT NULL DEFAULT 0;

-- Config always carries `tiers`; target_amount / reward_amount mirror level 1
-- for older screens.
CREATE OR REPLACE FUNCTION public.cashback_config(_company uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  WITH base AS (
    SELECT jsonb_build_object('enabled', false, 'target_amount', 500, 'reward_amount', 25)
        || COALESCE((SELECT value FROM public.app_settings WHERE company_id = _company AND key = 'cashback' LIMIT 1), '{}'::jsonb) AS v)
  SELECT v || jsonb_build_object('tiers',
    CASE WHEN jsonb_typeof(v->'tiers') = 'array' AND jsonb_array_length(v->'tiers') > 0 THEN v->'tiers'
         ELSE jsonb_build_array(jsonb_build_object('target', (v->>'target_amount')::numeric, 'reward', (v->>'reward_amount')::numeric)) END)
    FROM base
$$;

CREATE OR REPLACE FUNCTION public.set_cashback_tiers(_enabled boolean, _tiers jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _company uuid := public.current_company_id(); _old jsonb := public.cashback_config(public.current_company_id());
  _clean jsonb := '[]'::jsonb; _t jsonb; _target numeric; _reward numeric; _prev numeric := 0; _value jsonb;
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only the Super Admin can change cashback rules'; END IF;
  IF jsonb_typeof(_tiers) IS DISTINCT FROM 'array' OR jsonb_array_length(_tiers) = 0 THEN
    IF COALESCE(_enabled, false) THEN RAISE EXCEPTION 'Add at least one level'; END IF;
    _clean := _old->'tiers';
  ELSE
    IF jsonb_array_length(_tiers) > 10 THEN RAISE EXCEPTION 'At most 10 levels'; END IF;
    FOR _t IN SELECT value FROM jsonb_array_elements(_tiers) LOOP
      _target := round(NULLIF(_t->>'target', '')::numeric, 2);
      _reward := round(NULLIF(_t->>'reward', '')::numeric, 2);
      IF COALESCE(_target, 0) <= 0 OR COALESCE(_reward, 0) <= 0 THEN
        RAISE EXCEPTION 'Target and reward must be greater than zero';
      END IF;
      IF _target <= _prev THEN RAISE EXCEPTION 'Each level target must be bigger than the one before'; END IF;
      IF _reward >= _target THEN RAISE EXCEPTION 'The reward must be smaller than the spend target'; END IF;
      _clean := _clean || jsonb_build_array(jsonb_build_object('target', _target, 'reward', _reward));
      _prev := _target;
    END LOOP;
  END IF;
  _value := jsonb_build_object('enabled', COALESCE(_enabled, false), 'tiers', _clean,
    'target_amount', (_clean->0->>'target')::numeric, 'reward_amount', (_clean->0->>'reward')::numeric);
  INSERT INTO public.app_settings (company_id, scope, key, value) VALUES (_company, 'company', 'cashback', _value)
  ON CONFLICT DO NOTHING;
  UPDATE public.app_settings SET value = _value, updated_at = now() WHERE company_id = _company AND key = 'cashback';
  PERFORM public.log_audit('cashback.settings', 'loyalty', 'app_settings', NULL, _old, _value, NULL, NULL);
  RETURN public.cashback_config(_company);
END $$;

-- The old one-level setter now writes a one-level list.
CREATE OR REPLACE FUNCTION public.set_cashback_settings(_enabled boolean, _target_amount numeric, _reward_amount numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NOT COALESCE(_enabled, false) AND (COALESCE(_target_amount, 0) <= 0 OR COALESCE(_reward_amount, 0) <= 0) THEN
    RETURN public.set_cashback_tiers(false, NULL);
  END IF;
  RETURN public.set_cashback_tiers(_enabled,
    jsonb_build_array(jsonb_build_object('target', _target_amount, 'reward', _reward_amount)));
END $$;

-- Adds spend and pays every level reached. Returns the cashback earned.
CREATE OR REPLACE FUNCTION public._cashback_accrue(_company uuid, _customer uuid, _order uuid, _spend numeric,
  _order_number text, _actor uuid)
RETURNS numeric LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _cfg jsonb := public.cashback_config(_company); _tiers jsonb; _n int;
  _progress numeric; _level int; _earned numeric := 0; _target numeric; _reward numeric; _guard int := 0;
BEGIN
  IF NOT COALESCE((_cfg->>'enabled')::boolean, false) OR COALESCE(_spend, 0) <= 0 THEN RETURN 0; END IF;
  _tiers := _cfg->'tiers';
  _n := jsonb_array_length(_tiers);
  IF _n = 0 OR COALESCE((_tiers->0->>'target')::numeric, 0) <= 0 THEN RETURN 0; END IF;

  SELECT round(cashback_progress + _spend, 2), LEAST(GREATEST(cashback_level, 0), _n - 1)
    INTO _progress, _level FROM public.customers WHERE id = _customer FOR UPDATE;
  IF _progress IS NULL THEN RETURN 0; END IF;

  LOOP
    _guard := _guard + 1;
    EXIT WHEN _guard > 1000;
    _target := (_tiers->_level->>'target')::numeric;
    _reward := (_tiers->_level->>'reward')::numeric;
    EXIT WHEN _progress < _target;
    _earned := _earned + _reward;
    _level := _level + 1;
    IF _level >= _n THEN
      _progress := round(_progress - _target, 2);
      _level := 0;
    END IF;
  END LOOP;

  UPDATE public.customers SET cashback_progress = _progress, cashback_level = _level WHERE id = _customer;
  IF _earned > 0 THEN
    PERFORM public._wallet_post(_company, _customer, _order, 'earn', _earned,
      'كاش باك: وصلت للمستوى — فاتورة #' || COALESCE(_order_number, ''), _actor);
  END IF;
  RETURN _earned;
END $$;
REVOKE ALL ON FUNCTION public._cashback_accrue(uuid, uuid, uuid, numeric, text, uuid) FROM PUBLIC, anon, authenticated;

-- Next level for one customer: what the cashier and the customer page show.
CREATE OR REPLACE FUNCTION public._cashback_next(_cfg jsonb, _progress numeric, _level integer)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path TO 'public' AS $$
  SELECT jsonb_build_object(
    'level', LEAST(GREATEST(COALESCE(_level, 0), 0), GREATEST(jsonb_array_length(_cfg->'tiers') - 1, 0)) + 1,
    'levels', jsonb_array_length(_cfg->'tiers'),
    'next_target', (_cfg->'tiers'->LEAST(GREATEST(COALESCE(_level, 0), 0), GREATEST(jsonb_array_length(_cfg->'tiers') - 1, 0))->>'target')::numeric,
    'next_reward', (_cfg->'tiers'->LEAST(GREATEST(COALESCE(_level, 0), 0), GREATEST(jsonb_array_length(_cfg->'tiers') - 1, 0))->>'reward')::numeric,
    'to_next_reward', GREATEST((_cfg->'tiers'->LEAST(GREATEST(COALESCE(_level, 0), 0), GREATEST(jsonb_array_length(_cfg->'tiers') - 1, 0))->>'target')::numeric - COALESCE(_progress, 0), 0))
$$;
REVOKE ALL ON FUNCTION public._cashback_next(jsonb, numeric, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._cashback_next(jsonb, numeric, integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.customer_cashback(_customer_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT jsonb_build_object('wallet_balance', c.wallet_balance, 'progress', c.cashback_progress,
    'target_amount', (cfg->>'target_amount')::numeric, 'reward_amount', (cfg->>'reward_amount')::numeric,
    'enabled', (cfg->>'enabled')::boolean, 'tiers', cfg->'tiers')
    || public._cashback_next(cfg, c.cashback_progress, c.cashback_level)
    FROM public.customers c CROSS JOIN LATERAL (SELECT public.cashback_config(c.company_id) AS cfg) x
   WHERE c.id = _customer_id AND c.company_id = public.current_company_id()
     AND (public.has_permission('pos.create_order') OR public.has_permission('loyalty.view') OR public.is_super_admin())
$$;

CREATE OR REPLACE FUNCTION public.customer_card(_barcode text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _c public.customers; _cfg jsonb; _next jsonb;
BEGIN
  SELECT * INTO _c FROM public.customers WHERE barcode = upper(btrim(_barcode)) AND is_active;
  IF _c.id IS NULL THEN RETURN NULL; END IF;
  _cfg := public.cashback_config(_c.company_id);
  _next := public._cashback_next(_cfg, _c.cashback_progress, _c.cashback_level);
  RETURN jsonb_build_object(
    'code', _c.code, 'name', _c.name, 'visits', _c.visits, 'barcode', _c.barcode,
    'company', (SELECT name FROM public.companies WHERE id = _c.company_id),
    'wallet_balance', _c.wallet_balance,
    'cashback_enabled', COALESCE((_cfg->>'enabled')::boolean, false),
    'target_amount', (_next->>'next_target')::numeric,
    'reward_amount', (_next->>'next_reward')::numeric,
    'to_next_reward', (_next->>'to_next_reward')::numeric);
END $$;

-- Restarting the target also restarts the level.
CREATE OR REPLACE FUNCTION public.reset_cashback_progress(_customer_id uuid DEFAULT NULL, _reason text DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _company uuid := public.current_company_id(); _n int;
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only the Super Admin can restart cashback targets'; END IF;
  WITH changed AS (
    UPDATE public.customers SET cashback_progress = 0, cashback_level = 0, updated_at = now()
     WHERE company_id = _company AND (cashback_progress <> 0 OR cashback_level <> 0)
       AND (_customer_id IS NULL OR id = _customer_id)
    RETURNING id)
  SELECT count(*) INTO _n FROM changed;
  PERFORM public.log_audit('cashback.reset', 'loyalty', 'customers', _customer_id, NULL,
    jsonb_build_object('scope', CASE WHEN _customer_id IS NULL THEN 'all' ELSE 'one' END, 'customers', _n),
    NULLIF(btrim(COALESCE(_reason, '')), ''), NULL);
  RETURN _n;
END $$;

CREATE OR REPLACE FUNCTION public.reset_all_wallets(_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _company uuid := public.current_company_id(); _actor uuid := public.current_profile_id();
  _r record; _n int := 0; _total numeric := 0;
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only the Super Admin can zero the wallets'; END IF;
  IF char_length(btrim(COALESCE(_reason, ''))) < 3 THEN RAISE EXCEPTION 'A reason is required'; END IF;
  FOR _r IN SELECT id, wallet_balance FROM public.customers
             WHERE company_id = _company AND wallet_balance > 0 FOR UPDATE LOOP
    PERFORM public._wallet_post(_company, _r.id, NULL, 'adjust', -_r.wallet_balance,
      'تصفير كل المحافظ: ' || btrim(_reason), _actor);
    _n := _n + 1;
    _total := _total + _r.wallet_balance;
  END LOOP;
  PERFORM public.log_audit('cashback.wallets_zeroed', 'loyalty', 'customers', NULL, NULL,
    jsonb_build_object('customers', _n, 'total', _total), btrim(_reason), NULL);
  RETURN jsonb_build_object('customers', _n, 'total', _total);
END $$;

REVOKE ALL ON FUNCTION public.set_cashback_tiers(boolean, jsonb), public.reset_all_wallets(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_cashback_tiers(boolean, jsonb), public.reset_all_wallets(text) TO authenticated;

-- ---------------------------------------------------------------------
-- Hidden offer suggestions (product ids), shared by every manager.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.offer_hidden_suggestions()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT COALESCE((SELECT value->'products' FROM public.app_settings
                    WHERE company_id = public.current_company_id() AND key = 'offer_hidden_suggestions' LIMIT 1), '[]'::jsonb)
$$;

CREATE OR REPLACE FUNCTION public.set_offer_suggestion_hidden(_product_id uuid, _hidden boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _company uuid := public.current_company_id(); _list jsonb := public.offer_hidden_suggestions();
BEGIN
  IF NOT (public.has_permission('products.update') OR public.has_permission('products.create') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  _list := COALESCE((SELECT jsonb_agg(e) FROM jsonb_array_elements_text(_list) e WHERE e <> _product_id::text), '[]'::jsonb);
  IF COALESCE(_hidden, true) THEN _list := _list || to_jsonb(_product_id::text); END IF;
  INSERT INTO public.app_settings (company_id, scope, key, value)
  VALUES (_company, 'company', 'offer_hidden_suggestions', jsonb_build_object('products', _list))
  ON CONFLICT DO NOTHING;
  UPDATE public.app_settings SET value = jsonb_build_object('products', _list), updated_at = now()
   WHERE company_id = _company AND key = 'offer_hidden_suggestions';
  PERFORM public.log_audit(CASE WHEN COALESCE(_hidden, true) THEN 'offers.suggestion_hidden' ELSE 'offers.suggestion_shown' END,
    'offers', 'products', _product_id, NULL, NULL, NULL, NULL);
  RETURN _list;
END $$;

REVOKE ALL ON FUNCTION public.offer_hidden_suggestions(), public.set_offer_suggestion_hidden(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.offer_hidden_suggestions(), public.set_offer_suggestion_hidden(uuid, boolean) TO authenticated;
