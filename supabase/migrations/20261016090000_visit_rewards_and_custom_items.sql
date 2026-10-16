-- =====================================================================
-- 1) Visit rewards (owner decision 2026-10-16): every 10 visits = 1 free drink.
--    * One stamp per customer per business day (several orders the same day
--      count once). Stamps live in customers.points_balance; every move is in
--      customer_points_transactions (kind earn / redeem).
--    * At the POS the cashier marks one drink line "free_reward": one unit of
--      that line (its price, add-ons not included) is taken off as a discount
--      with a clear reason, and the stamps are spent in the same transaction.
--    * Runs next to the cashback wallet; nothing in cashback changes.
-- 2) Custom (free-typed) POS items work again. create_pos_order lost them in
--    the 2026-10-12 rewrite, so the POS "custom item" button failed with
--    "Product not found". They carry no stock and no recipe cost.
-- Applied to the live create_pos_order text; nothing else in it changes.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.visit_rewards_config(_company uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT jsonb_build_object('enabled', true, 'visits_per_reward', 10)
      || COALESCE((SELECT value FROM public.app_settings WHERE company_id = _company AND key = 'visit_rewards' LIMIT 1), '{}'::jsonb)
$$;
REVOKE ALL ON FUNCTION public.visit_rewards_config(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.visit_rewards_config(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.set_visit_rewards(_enabled boolean, _visits_per_reward int)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _company uuid := public.current_company_id(); _old jsonb; _new jsonb;
BEGIN
  IF NOT (public.has_permission('loyalty.manage') OR public.has_permission('settings.manage') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF _visits_per_reward IS NULL OR _visits_per_reward < 2 OR _visits_per_reward > 100 THEN
    RAISE EXCEPTION 'عدد الزيارات لازم يكون من 2 لـ 100';
  END IF;
  _old := public.visit_rewards_config(_company);
  _new := jsonb_build_object('enabled', COALESCE(_enabled, true), 'visits_per_reward', _visits_per_reward);
  UPDATE public.app_settings SET value = _new, updated_at = now() WHERE company_id = _company AND key = 'visit_rewards';
  IF NOT FOUND THEN
    INSERT INTO public.app_settings (company_id, key, value) VALUES (_company, 'visit_rewards', _new);
  END IF;
  PERFORM public.log_audit('settings.visit_rewards', 'loyalty', 'app_settings', NULL, _old, _new, NULL, NULL);
  RETURN _new;
END $$;
REVOKE ALL ON FUNCTION public.set_visit_rewards(boolean, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_visit_rewards(boolean, int) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION pg_temp.patch_fn(_sig regprocedure, _old text, _new text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE _def text := pg_get_functiondef(_sig);
BEGIN
  IF position(_new IN _def) > 0 THEN RAISE NOTICE '% already patched', _sig; RETURN; END IF;
  IF position(_old IN _def) = 0 THEN RAISE EXCEPTION 'Expected text not found in %: %', _sig, left(_old, 60); END IF;
  IF position(_old IN substr(_def, position(_old IN _def) + 1)) > 0 THEN
    RAISE EXCEPTION 'Anchor appears more than once in %: %', _sig, left(_old, 60);
  END IF;
  EXECUTE replace(_def, _old, _new);
END $$;

-- a) variables
SELECT pg_temp.patch_fn('public.create_pos_order(uuid, jsonb, jsonb, order_type, numeric, text, text, text, text, uuid, text, uuid, boolean)'::regprocedure,
$o$  _wallet numeric; _cashback_used numeric := 0; _cashback_earned numeric := 0;
BEGIN$o$,
$n$  _wallet numeric; _cashback_used numeric := 0; _cashback_earned numeric := 0;
  _vr jsonb; _vr_need int; _stamps int; _reward_value numeric := 0; _reward_name text; _custom_price numeric;
BEGIN$n$);

-- b) custom (free-typed) lines, at the top of the pricing loop
SELECT pg_temp.patch_fn('public.create_pos_order(uuid, jsonb, jsonb, order_type, numeric, text, text, text, text, uuid, text, uuid, boolean)'::regprocedure,
$o$    IF _qty <= 0 THEN RAISE EXCEPTION 'Item quantity must be greater than zero'; END IF;

    SELECT * INTO _product FROM public.products
    WHERE id = NULLIF(_item->>'product_id','')::uuid AND company_id = _company AND is_active;$o$,
$n$    IF _qty <= 0 THEN RAISE EXCEPTION 'Item quantity must be greater than zero'; END IF;

    -- Free-typed item: price as typed, no stock, no recipe cost.
    IF COALESCE((_item->>'custom')::boolean, false) THEN
      IF _tab THEN RAISE EXCEPTION 'الصنف اليدوي مينفعش على حساب شريك'; END IF;
      IF COALESCE((_item->>'free_reward')::boolean, false) THEN RAISE EXCEPTION 'المشروب المجاني لازم يكون من المنيو'; END IF;
      _custom_price := round(COALESCE((_item->>'unit_price')::numeric, 0), 2);
      IF _custom_price <= 0 OR _custom_price > 100000 THEN RAISE EXCEPTION 'سعر الصنف اليدوي غير صحيح'; END IF;
      IF NULLIF(btrim(COALESCE(_item->>'product_name', '')), '') IS NULL THEN RAISE EXCEPTION 'اكتب اسم الصنف اليدوي'; END IF;
      _line := round(_custom_price * _qty, 2);
      INSERT INTO public.order_items (order_id, product_id, size_id, product_name, size_name,
        unit_price, base_price, modifiers_total, quantity, line_total, unit_cost, notes)
      VALUES (_order, NULL, NULL, left(btrim(_item->>'product_name'), 80), NULL,
        _custom_price, _custom_price, 0, _qty, _line, 0, NULLIF(_item->>'notes', ''));
      _subtotal := _subtotal + _line;
      CONTINUE;
    END IF;

    SELECT * INTO _product FROM public.products
    WHERE id = NULLIF(_item->>'product_id','')::uuid AND company_id = _company AND is_active;$n$);

-- c) the line the customer gets free
SELECT pg_temp.patch_fn('public.create_pos_order(uuid, jsonb, jsonb, order_type, numeric, text, text, text, text, uuid, text, uuid, boolean)'::regprocedure,
$o$    _line := round((_unit_price + _mods_total) * _qty, 2);$o$,
$n$    _line := round((_unit_price + _mods_total) * _qty, 2);
    IF COALESCE((_item->>'free_reward')::boolean, false) THEN
      IF _reward_value > 0 THEN RAISE EXCEPTION 'مشروب مجاني واحد بس في الفاتورة'; END IF;
      _reward_value := round(_unit_price, 2);   -- one unit; add-ons stay paid
      _reward_name := COALESCE(_product.name_ar, _product.name);
    END IF;$n$);

-- d) check the stamps and take the drink off as a discount
SELECT pg_temp.patch_fn('public.create_pos_order(uuid, jsonb, jsonb, order_type, numeric, text, text, text, text, uuid, text, uuid, boolean)'::regprocedure,
$o$  IF _discount > _subtotal THEN$o$,
$n$  IF _reward_value > 0 THEN
    IF _cust IS NULL THEN RAISE EXCEPTION 'المشروب المجاني محتاج تختار العميل'; END IF;
    IF _tab THEN RAISE EXCEPTION 'المشروب المجاني مينفعش على حساب شريك'; END IF;
    _vr := public.visit_rewards_config(_company);
    IF NOT COALESCE((_vr->>'enabled')::boolean, false) THEN RAISE EXCEPTION 'مكافأة الزيارات مقفولة من الإعدادات'; END IF;
    _vr_need := GREATEST(COALESCE((_vr->>'visits_per_reward')::int, 10), 1);
    SELECT COALESCE(points_balance, 0) INTO _stamps FROM public.customers WHERE id = _cust FOR UPDATE;
    IF _stamps < _vr_need THEN RAISE EXCEPTION 'العميل معاه % زيارة من %، لسه مستحقش مشروب مجاني', _stamps, _vr_need; END IF;
    _discount := _discount + _reward_value;
    _reason := COALESCE(NULLIF(_reason, '') || ' | ', '') || 'مكافأة زيارات: ' || COALESCE(_reward_name, 'مشروب') || ' مجاني';
  END IF;

  IF _discount > _subtotal THEN$n$);

-- e) spend the stamps, and add today's visit stamp
SELECT pg_temp.patch_fn('public.create_pos_order(uuid, jsonb, jsonb, order_type, numeric, text, text, text, text, uuid, text, uuid, boolean)'::regprocedure,
$o$  -- Paid in full (or charged to a partner tab): the order is done.$o$,
$n$  -- Visit rewards: spend 10 stamps for a free drink; one stamp per visit day.
  IF _cust IS NOT NULL THEN
    _vr := public.visit_rewards_config(_company);
    IF COALESCE((_vr->>'enabled')::boolean, false) THEN
      _vr_need := GREATEST(COALESCE((_vr->>'visits_per_reward')::int, 10), 1);
      IF _reward_value > 0 THEN
        UPDATE public.customers SET points_balance = COALESCE(points_balance, 0) - _vr_need, updated_at = now()
         WHERE id = _cust RETURNING points_balance INTO _stamps;
        INSERT INTO public.customer_points_transactions (company_id, customer_id, order_id, kind, points, balance_after, description, created_by)
        VALUES (_company, _cust, _order, 'redeem', -_vr_need, _stamps, 'مشروب مجاني — فاتورة #' || _number, _profile);
      END IF;
      IF NOT _tab AND NOT EXISTS (
           SELECT 1 FROM public.customer_points_transactions t
            WHERE t.customer_id = _cust AND t.kind = 'earn'
              AND t.created_at >= public.business_day_start(public.business_today(_company), _company)) THEN
        UPDATE public.customers SET points_balance = COALESCE(points_balance, 0) + 1, updated_at = now()
         WHERE id = _cust RETURNING points_balance INTO _stamps;
        INSERT INTO public.customer_points_transactions (company_id, customer_id, order_id, kind, points, balance_after, description, created_by)
        VALUES (_company, _cust, _order, 'earn', 1, _stamps, 'زيارة — فاتورة #' || _number, _profile);
      END IF;
    END IF;
  END IF;

  -- Paid in full (or charged to a partner tab): the order is done.$n$);
