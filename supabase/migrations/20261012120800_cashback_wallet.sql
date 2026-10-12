-- =====================================================================
-- Target cashback wallet (replaces loyalty points and vouchers)
--   Rule (owner-defined): every time a customer's spend reaches X, Y EGP
--   lands in their wallet. Spending accumulates; the rule repeats.
--   The wallet pays (part of) any later bill as the "cashback" tender.
--   Existing points and active vouchers are converted to wallet balance
--   at their EGP value, so no customer loses anything.
-- =====================================================================

ALTER TABLE public.customers
  ADD COLUMN IF NOT EXISTS wallet_balance numeric(14,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS cashback_progress numeric(14,2) NOT NULL DEFAULT 0;
ALTER TABLE public.customers DROP CONSTRAINT IF EXISTS customers_wallet_balance_check;
ALTER TABLE public.customers ADD CONSTRAINT customers_wallet_balance_check CHECK (wallet_balance >= 0);

CREATE TABLE IF NOT EXISTS public.customer_wallet_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  customer_id uuid NOT NULL REFERENCES public.customers(id),
  order_id uuid REFERENCES public.orders(id),
  kind text NOT NULL CHECK (kind IN ('earn', 'redeem', 'refund', 'adjust', 'migration')),
  amount numeric(14,2) NOT NULL,
  balance_after numeric(14,2) NOT NULL,
  description text,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS customer_wallet_tx_customer_idx ON public.customer_wallet_transactions(customer_id, created_at DESC);
ALTER TABLE public.customer_wallet_transactions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS customer_wallet_tx_select ON public.customer_wallet_transactions;
CREATE POLICY customer_wallet_tx_select ON public.customer_wallet_transactions FOR SELECT TO authenticated
  USING (company_id = public.current_company_id()
         AND (public.has_permission('loyalty.view') OR public.has_permission('pos.create_order') OR public.is_super_admin()));
GRANT SELECT ON public.customer_wallet_transactions TO authenticated;
GRANT ALL ON public.customer_wallet_transactions TO service_role;

-- ---------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cashback_config(_company uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT jsonb_build_object('enabled', false, 'target_amount', 500, 'reward_amount', 25)
      || COALESCE((SELECT value FROM public.app_settings WHERE company_id = _company AND key = 'cashback' LIMIT 1), '{}'::jsonb)
$$;

CREATE OR REPLACE FUNCTION public.cashback_settings()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT public.cashback_config(public.current_company_id())
$$;

CREATE OR REPLACE FUNCTION public.set_cashback_settings(_enabled boolean, _target_amount numeric, _reward_amount numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _company uuid := public.current_company_id(); _value jsonb;
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only the Super Admin can change cashback rules'; END IF;
  IF COALESCE(_target_amount, 0) <= 0 OR COALESCE(_reward_amount, 0) <= 0 THEN
    RAISE EXCEPTION 'Target and reward must be greater than zero';
  END IF;
  IF _reward_amount >= _target_amount THEN RAISE EXCEPTION 'The reward must be smaller than the spend target'; END IF;
  _value := jsonb_build_object('enabled', COALESCE(_enabled, false),
    'target_amount', round(_target_amount, 2), 'reward_amount', round(_reward_amount, 2));
  INSERT INTO public.app_settings (company_id, scope, key, value) VALUES (_company, 'company', 'cashback', _value)
  ON CONFLICT DO NOTHING;
  UPDATE public.app_settings SET value = _value, updated_at = now() WHERE company_id = _company AND key = 'cashback';
  PERFORM public.log_audit('cashback.settings', 'loyalty', 'app_settings', NULL, NULL, _value, NULL, NULL);
  RETURN public.cashback_config(_company);
END $$;

-- ---------------------------------------------------------------------
-- Wallet ledger helpers
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._wallet_post(_company uuid, _customer uuid, _order uuid, _kind text,
  _amount numeric, _description text, _actor uuid)
RETURNS numeric LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _bal numeric;
BEGIN
  IF round(COALESCE(_amount, 0), 2) = 0 THEN RETURN NULL; END IF;
  UPDATE public.customers SET wallet_balance = round(wallet_balance + _amount, 2), updated_at = now()
   WHERE id = _customer AND company_id = _company
  RETURNING wallet_balance INTO _bal;
  IF _bal IS NULL THEN RAISE EXCEPTION 'Customer not found'; END IF;
  IF _bal < 0 THEN RAISE EXCEPTION 'Customer cashback balance is not enough'; END IF;
  INSERT INTO public.customer_wallet_transactions (company_id, customer_id, order_id, kind, amount, balance_after, description, created_by)
  VALUES (_company, _customer, _order, _kind, round(_amount, 2), _bal, _description, _actor);
  RETURN _bal;
END $$;

-- Adds spend toward the target and pays every reward reached. Returns cashback earned.
CREATE OR REPLACE FUNCTION public._cashback_accrue(_company uuid, _customer uuid, _order uuid, _spend numeric,
  _order_number text, _actor uuid)
RETURNS numeric LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _cfg jsonb := public.cashback_config(_company); _target numeric; _reward numeric; _progress numeric; _times int;
BEGIN
  IF NOT COALESCE((_cfg->>'enabled')::boolean, false) OR COALESCE(_spend, 0) <= 0 THEN RETURN 0; END IF;
  _target := (_cfg->>'target_amount')::numeric;
  _reward := (_cfg->>'reward_amount')::numeric;
  IF COALESCE(_target, 0) <= 0 OR COALESCE(_reward, 0) <= 0 THEN RETURN 0; END IF;
  UPDATE public.customers SET cashback_progress = round(cashback_progress + _spend, 2)
   WHERE id = _customer RETURNING cashback_progress INTO _progress;
  _times := floor(_progress / _target)::int;
  IF _times <= 0 THEN RETURN 0; END IF;
  UPDATE public.customers SET cashback_progress = round(cashback_progress - _times * _target, 2) WHERE id = _customer;
  PERFORM public._wallet_post(_company, _customer, _order, 'earn', _times * _reward,
    'كاش باك: وصلت ' || to_char(_target, 'FM999999990') || ' ج.م مشتريات — فاتورة #' || COALESCE(_order_number, ''), _actor);
  RETURN _times * _reward;
END $$;
REVOKE ALL ON FUNCTION public._wallet_post(uuid, uuid, uuid, text, numeric, text, uuid),
  public._cashback_accrue(uuid, uuid, uuid, numeric, text, uuid) FROM PUBLIC, anon, authenticated;

-- Manual wallet correction (Super Admin, audited, reason required).
CREATE OR REPLACE FUNCTION public.adjust_customer_wallet(_customer_id uuid, _amount numeric, _reason text)
RETURNS numeric LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _bal numeric;
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF char_length(btrim(COALESCE(_reason, ''))) < 3 THEN RAISE EXCEPTION 'A reason is required'; END IF;
  _bal := public._wallet_post(public.current_company_id(), _customer_id, NULL, 'adjust', _amount, btrim(_reason), public.current_profile_id());
  PERFORM public.log_audit('cashback.adjust', 'loyalty', 'customers', _customer_id, NULL,
    jsonb_build_object('amount', _amount, 'balance', _bal), btrim(_reason), NULL);
  RETURN _bal;
END $$;

-- What the cashier sees after linking a customer.
CREATE OR REPLACE FUNCTION public.customer_cashback(_customer_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT jsonb_build_object('wallet_balance', c.wallet_balance, 'progress', c.cashback_progress,
    'target_amount', (cfg->>'target_amount')::numeric, 'reward_amount', (cfg->>'reward_amount')::numeric,
    'enabled', (cfg->>'enabled')::boolean,
    'to_next_reward', GREATEST((cfg->>'target_amount')::numeric - c.cashback_progress, 0))
    FROM public.customers c CROSS JOIN LATERAL (SELECT public.cashback_config(c.company_id) AS cfg) x
   WHERE c.id = _customer_id AND c.company_id = public.current_company_id()
     AND (public.has_permission('pos.create_order') OR public.has_permission('loyalty.view') OR public.is_super_admin())
$$;

REVOKE ALL ON FUNCTION public.cashback_settings(), public.set_cashback_settings(boolean, numeric, numeric),
  public.adjust_customer_wallet(uuid, numeric, text), public.customer_cashback(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cashback_settings(), public.set_cashback_settings(boolean, numeric, numeric),
  public.adjust_customer_wallet(uuid, numeric, text), public.customer_cashback(uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- Refunds: wallet money goes back to the wallet; refunded real money is
-- taken off the progress toward the next reward.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_refund_cashback()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _cust uuid; _number text;
BEGIN
  IF NEW.status <> 'active' THEN RETURN NEW; END IF;
  SELECT customer_id, order_number INTO _cust, _number FROM public.orders WHERE id = NEW.order_id;
  IF _cust IS NULL THEN RETURN NEW; END IF;
  IF public.tender_key(NEW.method_key) = 'points' THEN
    PERFORM public._wallet_post(NEW.company_id, _cust, NEW.order_id, 'refund', NEW.amount,
      'رجوع كاش باك من مرتجع — فاتورة #' || COALESCE(_number, ''), NEW.created_by);
  ELSIF public.tender_key(NEW.method_key) <> 'partner_tab' THEN
    UPDATE public.customers SET cashback_progress = round(cashback_progress - NEW.amount, 2) WHERE id = _cust;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS t_refund_cashback ON public.order_refunds;
CREATE TRIGGER t_refund_cashback AFTER INSERT ON public.order_refunds
  FOR EACH ROW EXECUTE FUNCTION public.trg_refund_cashback();
REVOKE ALL ON FUNCTION public.trg_refund_cashback() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- One-time conversion: points and active vouchers -> wallet (EGP value).
-- ---------------------------------------------------------------------
DO $$
DECLARE _c record; _value numeric; _v record;
BEGIN
  FOR _c IN SELECT cu.id, cu.company_id, cu.points_balance,
                   GREATEST(COALESCE((public.loyalty_config(cu.company_id)->>'point_value')::numeric, 1), 0) AS pv
              FROM public.customers cu WHERE COALESCE(cu.points_balance, 0) > 0 LOOP
    _value := round(_c.points_balance * _c.pv, 2);
    IF _value > 0 THEN
      PERFORM public._wallet_post(_c.company_id, _c.id, NULL, 'migration', _value,
        'تحويل ' || _c.points_balance || ' نقطة لرصيد كاش باك', NULL);
    END IF;
  END LOOP;
  UPDATE public.customers SET points_balance = 0 WHERE points_balance <> 0;

  FOR _v IN SELECT * FROM public.customer_vouchers WHERE status = 'active' AND amount > 0
              AND (expires_at IS NULL OR expires_at >= CURRENT_DATE) LOOP
    PERFORM public._wallet_post(_v.company_id, _v.customer_id, NULL, 'migration', _v.amount,
      'تحويل قسيمة ' || _v.code || ' لرصيد كاش باك', NULL);
    UPDATE public.customer_vouchers SET status = 'cancelled', notes = COALESCE(notes || ' | ', '') || 'Converted to cashback wallet', updated_at = now()
     WHERE id = _v.id;
  END LOOP;

  -- Points are off for good.
  UPDATE public.app_settings SET value = COALESCE(value, '{}'::jsonb) || '{"enabled": false}'::jsonb, updated_at = now()
   WHERE key = 'loyalty';
END $$;

-- Retired points / voucher RPCs.
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.proname = ANY (ARRAY['adjust_customer_points', 'reset_all_customer_points',
              'update_customer_with_points', 'issue_customer_voucher', 'cancel_customer_voucher', 'settle_voucher_cash',
              'set_loyalty_settings']) LOOP
    EXECUTE 'DROP FUNCTION ' || r.sig;
  END LOOP;
END $$;

-- Public customer card (QR): wallet instead of points.
CREATE OR REPLACE FUNCTION public.customer_card(_barcode text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _c public.customers; _cfg jsonb;
BEGIN
  SELECT * INTO _c FROM public.customers WHERE barcode = upper(btrim(_barcode)) AND is_active;
  IF _c.id IS NULL THEN RETURN NULL; END IF;
  _cfg := public.cashback_config(_c.company_id);
  RETURN jsonb_build_object(
    'code', _c.code, 'name', _c.name, 'visits', _c.visits, 'barcode', _c.barcode,
    'company', (SELECT name FROM public.companies WHERE id = _c.company_id),
    'wallet_balance', _c.wallet_balance,
    'cashback_enabled', COALESCE((_cfg->>'enabled')::boolean, false),
    'target_amount', (_cfg->>'target_amount')::numeric,
    'reward_amount', (_cfg->>'reward_amount')::numeric,
    'to_next_reward', GREATEST((_cfg->>'target_amount')::numeric - _c.cashback_progress, 0));
END $$;

-- ---------------------------------------------------------------------
-- create_pos_order: latest version with points/vouchers replaced by the wallet.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_pos_order(_branch_id uuid, _items jsonb, _payments jsonb, _order_type order_type DEFAULT 'takeaway'::order_type, _discount_amount numeric DEFAULT 0, _discount_reason text DEFAULT NULL::text, _customer_name text DEFAULT NULL::text, _customer_phone text DEFAULT NULL::text, _notes text DEFAULT NULL::text, _customer_id uuid DEFAULT NULL::uuid, _voucher_code text DEFAULT NULL::text, _partner_id uuid DEFAULT NULL::uuid, _on_partner_tab boolean DEFAULT false)
RETURNS TABLE(out_id uuid, out_number text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  _profile uuid := public.current_profile_id();
  _company uuid := public.current_company_id();
  _shift uuid; _order uuid; _number text; _seq int;
  _subtotal numeric := 0; _tax numeric := 0; _total numeric := 0;
  _tax_rate numeric := 0; _tax_enabled boolean := false; _paid numeric := 0;
  _item jsonb; _pay jsonb; _mod jsonb;
  _item_id uuid; _mods_total numeric; _line numeric;
  _taxable_base numeric := 0;
  _product public.products; _size public.product_sizes;
  _override numeric; _unit_price numeric; _base_price numeric; _unit_cost numeric; _qty int;
  _opt public.modifier_options;
  _pay_amount numeric; _pay_kind text; _remaining numeric;
  _voucher public.customer_vouchers;
  _discount numeric := COALESCE(_discount_amount, 0);
  _reason text := _discount_reason;
  _cfg jsonb; _rate numeric; _points int := 0; _balance int;
  _cust uuid := _customer_id;
  _point_value numeric; _pay_points int; _redeem_points int := 0;
  _avail int; _balance_before int;
  _offer public.product_offers; _offer_savings numeric := 0; _offer_titles text := '';
  _double_value numeric := 0;
  _partner public.partners; _tab boolean := COALESCE(_on_partner_tab, false);
  _offers_on boolean := public.offers_enabled(_company);
  _bkey text; _oid uuid; _share numeric; _grp record; _bundle_offer public.product_offers;
  _wallet numeric; _cashback_used numeric := 0; _cashback_earned numeric := 0;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('pos.create_order') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF NOT public.can_access_branch(_branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _items IS NULL OR jsonb_array_length(_items) = 0 THEN RAISE EXCEPTION 'Order has no items'; END IF;
  IF _discount > 0 AND NOT (public.has_permission('pos.apply_discount') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized to apply discounts';
  END IF;

  IF _partner_id IS NOT NULL THEN
    SELECT * INTO _partner FROM public.partners
     WHERE id = _partner_id AND company_id = _company AND status = 'active';
    IF _partner.id IS NULL THEN RAISE EXCEPTION 'Partner not found or inactive'; END IF;
    IF _cust IS NULL THEN _cust := _partner.customer_id; END IF;
  ELSE
    _tab := false;
  END IF;

  IF _tab THEN
    IF _discount > 0 THEN RAISE EXCEPTION 'Partner tab orders are billed at full menu price'; END IF;
    IF NULLIF(btrim(COALESCE(_voucher_code,'')),'') IS NOT NULL THEN
      RAISE EXCEPTION 'Partner tab orders cannot use vouchers';
    END IF;
    _payments := '[]'::jsonb;
  END IF;

  IF _cust IS NOT NULL THEN
    PERFORM 1 FROM public.customers WHERE id = _cust AND company_id = _company AND is_active;
    IF NOT FOUND THEN RAISE EXCEPTION 'Customer not found'; END IF;
  END IF;

  IF _cust IS NULL
     AND NULLIF(btrim(COALESCE(_customer_name,'')),'') IS NOT NULL
     AND NULLIF(btrim(COALESCE(_customer_phone,'')),'') IS NOT NULL THEN
    SELECT id INTO _cust FROM public.customers
    WHERE company_id = _company AND phone = btrim(_customer_phone) LIMIT 1;
    IF _cust IS NULL THEN
      INSERT INTO public.customers (company_id, code, name, phone, barcode, created_by)
      VALUES (_company, 'C-' || lpad(nextval('public.customer_code_seq')::text, 5, '0'),
        btrim(_customer_name), btrim(_customer_phone),
        upper(substring(replace(gen_random_uuid()::text,'-','') from 1 for 12)), _profile)
      RETURNING id INTO _cust;
      PERFORM public.log_audit('customer.create','loyalty','customers',_cust,NULL,
        jsonb_build_object('name',btrim(_customer_name),'phone',btrim(_customer_phone),'source','pos'),NULL,_branch_id);
    END IF;
  END IF;

  IF NULLIF(btrim(COALESCE(_voucher_code,'')),'') IS NOT NULL THEN
    RAISE EXCEPTION 'Vouchers were replaced by the cashback wallet';
  END IF;

  PERFORM public.check_order_stock(_branch_id, _items);

  SELECT s.id INTO _shift FROM public.shifts s
  WHERE s.branch_id = _branch_id AND s.user_id = _profile AND s.status = 'open' LIMIT 1;
  IF _shift IS NULL THEN RAISE EXCEPTION 'No open shift'; END IF;

  SELECT c.tax_enabled, c.tax_rate INTO _tax_enabled, _tax_rate FROM public.companies c WHERE c.id = _company;

  -- ===== Bundle pre-pass: validate groups and split the bundle price by base value =====
  CREATE TEMP TABLE IF NOT EXISTS _bundle_grp (
    bundle_key text PRIMARY KEY, offer_id uuid, base_total numeric,
    offer_price numeric, lines int, seen int, allocated numeric
  ) ON COMMIT DROP;
  DELETE FROM _bundle_grp;

  FOR _item IN SELECT * FROM jsonb_array_elements(_items) LOOP
    _bkey := NULLIF(_item->>'bundle_key','');
    _oid := NULLIF(_item->>'offer_id','')::uuid;
    IF _bkey IS NULL OR _oid IS NULL THEN CONTINUE; END IF;

    IF _tab THEN RAISE EXCEPTION 'Partner tab orders cannot include promotional bundles'; END IF;
    IF NOT _offers_on THEN RAISE EXCEPTION 'العروض معطّلة حاليًا'; END IF;

    SELECT * INTO _bundle_offer FROM public.product_offers
     WHERE id = _oid AND company_id = _company AND offer_type = 'bundle' AND is_active
       AND starts_at <= CURRENT_DATE AND (ends_at IS NULL OR ends_at >= CURRENT_DATE);
    IF _bundle_offer.id IS NULL THEN RAISE EXCEPTION 'الباقة غير متاحة'; END IF;

    _qty := COALESCE((_item->>'quantity')::int, 0);
    IF _qty <= 0 THEN RAISE EXCEPTION 'Item quantity must be greater than zero'; END IF;

    SELECT * INTO _product FROM public.products
     WHERE id = NULLIF(_item->>'product_id','')::uuid AND company_id = _company AND is_active;
    IF _product.id IS NULL THEN RAISE EXCEPTION 'Product not found or unavailable'; END IF;

    _size := NULL;
    IF NULLIF(_item->>'size_id','') IS NOT NULL THEN
      SELECT * INTO _size FROM public.product_sizes
       WHERE id = (_item->>'size_id')::uuid AND product_id = _product.id AND is_active;
    END IF;

    SELECT pbs.price_override INTO _override FROM public.product_branch_settings pbs
     WHERE pbs.product_id = _product.id AND pbs.branch_id = _branch_id AND pbs.is_available;
    _base_price := COALESCE(_override, _product.base_price) + COALESCE(_size.price_delta, 0);

    INSERT INTO _bundle_grp (bundle_key, offer_id, base_total, offer_price, lines, seen, allocated)
    VALUES (_bkey, _oid, _base_price * _qty, _bundle_offer.offer_price, 1, 0, 0)
    ON CONFLICT (bundle_key) DO UPDATE
      SET base_total = _bundle_grp.base_total + (_base_price * _qty),
          lines = _bundle_grp.lines + 1;
  END LOOP;

  -- Each bundle group must match the offer definition exactly (products and quantities)
  FOR _grp IN SELECT * FROM _bundle_grp LOOP
    IF _grp.base_total <= 0 THEN RAISE EXCEPTION 'قيمة الباقة غير صحيحة'; END IF;
    IF EXISTS (
      SELECT bi.product_id, SUM(bi.quantity) q FROM public.offer_bundle_items bi
      WHERE bi.offer_id = _grp.offer_id GROUP BY bi.product_id
      EXCEPT
      SELECT NULLIF(x->>'product_id','')::uuid, SUM(COALESCE((x->>'quantity')::int,0))
      FROM jsonb_array_elements(_items) x
      WHERE x->>'bundle_key' = _grp.bundle_key
      GROUP BY NULLIF(x->>'product_id','')::uuid
    ) OR EXISTS (
      SELECT NULLIF(x->>'product_id','')::uuid, SUM(COALESCE((x->>'quantity')::int,0))
      FROM jsonb_array_elements(_items) x
      WHERE x->>'bundle_key' = _grp.bundle_key
      GROUP BY NULLIF(x->>'product_id','')::uuid
      EXCEPT
      SELECT bi.product_id, SUM(bi.quantity) FROM public.offer_bundle_items bi
      WHERE bi.offer_id = _grp.offer_id GROUP BY bi.product_id
    ) THEN
      RAISE EXCEPTION 'أصناف الباقة غير مطابقة للعرض المحدد';
    END IF;
  END LOOP;

  INSERT INTO public.order_counters (branch_id, business_date, last_seq)
  VALUES (_branch_id, CURRENT_DATE, 1)
  ON CONFLICT (branch_id, business_date)
  DO UPDATE SET last_seq = public.order_counters.last_seq + 1
  RETURNING last_seq INTO _seq;
  _number := to_char(CURRENT_DATE,'YYMMDD') || '-' || lpad(_seq::text, 4, '0');

  IF _tab THEN
    _reason := COALESCE(NULLIF(_reason,'') || ' | ', '') || 'Partner tab: ' || _partner.name;
  END IF;

  INSERT INTO public.orders (company_id, branch_id, shift_id, order_number, order_type, status,
    discount_amount, discount_reason, customer_id, customer_name, customer_phone, notes, created_by, completed_at)
  VALUES (_company, _branch_id, _shift, _number, _order_type, 'pending',
    0, _reason, _cust,
    COALESCE(NULLIF(btrim(COALESCE(_customer_name,'')),''), _partner.name, (SELECT name FROM public.customers WHERE id = _cust)),
    COALESCE(NULLIF(btrim(COALESCE(_customer_phone,'')),''), (SELECT phone FROM public.customers WHERE id = _cust)),
    _notes, _profile, NULL)
  RETURNING orders.id INTO _order;

  FOR _item IN SELECT * FROM jsonb_array_elements(_items) LOOP
    _qty := COALESCE((_item->>'quantity')::int, 0);
    IF _qty <= 0 THEN RAISE EXCEPTION 'Item quantity must be greater than zero'; END IF;

    SELECT * INTO _product FROM public.products
    WHERE id = NULLIF(_item->>'product_id','')::uuid AND company_id = _company AND is_active;
    IF _product.id IS NULL THEN RAISE EXCEPTION 'Product not found or unavailable'; END IF;
    IF NOT _product.is_available THEN RAISE EXCEPTION 'Product % is not available', _product.name; END IF;

    _size := NULL;
    IF NULLIF(_item->>'size_id','') IS NOT NULL THEN
      SELECT * INTO _size FROM public.product_sizes
      WHERE id = (_item->>'size_id')::uuid AND product_id = _product.id AND is_active;
      IF _size.id IS NULL THEN RAISE EXCEPTION 'Selected size is not available'; END IF;
    END IF;

    SELECT pbs.price_override INTO _override FROM public.product_branch_settings pbs
    WHERE pbs.product_id = _product.id AND pbs.branch_id = _branch_id AND pbs.is_available;

    _base_price := COALESCE(_override, _product.base_price) + COALESCE(_size.price_delta, 0);
    _unit_price := _base_price;
    _unit_cost := COALESCE(_product.cost, 0);
    _bkey := NULLIF(_item->>'bundle_key','');
    _oid := NULL;
    _offer := NULL;

    IF _bkey IS NOT NULL THEN
      -- Bundle line: price is the proportional share of the bundle price (piastre exact)
      SELECT * INTO _grp FROM _bundle_grp WHERE bundle_key = _bkey;
      _oid := _grp.offer_id;
      IF _grp.seen + 1 >= _grp.lines THEN
        _share := round(_grp.offer_price - _grp.allocated, 2);
      ELSE
        _share := round(_grp.offer_price * ((_base_price * _qty) / _grp.base_total), 2);
      END IF;
      UPDATE _bundle_grp SET seen = seen + 1, allocated = allocated + _share WHERE bundle_key = _bkey;
      _unit_price := _share / _qty;
      SELECT * INTO _offer FROM public.product_offers WHERE id = _oid;
    ELSIF NOT _tab AND _offers_on THEN
      -- Single-product offer, resolved server-side from live offer rows
      SELECT po.* INTO _offer FROM public.product_offers po
      WHERE po.company_id = _company AND po.product_id = _product.id
        AND po.offer_type = 'single' AND po.is_active
        AND po.starts_at <= CURRENT_DATE
        AND (po.ends_at IS NULL OR po.ends_at >= CURRENT_DATE)
      ORDER BY po.offer_price ASC LIMIT 1;
      IF _offer.id IS NOT NULL AND _offer.offer_price < _unit_price THEN
        _unit_price := _offer.offer_price;
        _oid := _offer.id;
      ELSE
        _offer := NULL;
      END IF;
    END IF;

    IF _oid IS NOT NULL THEN
      _offer_savings := _offer_savings + round((_base_price - _unit_price) * _qty, 2);
      IF _offer.title IS NOT NULL AND position(_offer.title in _offer_titles) = 0 THEN
        _offer_titles := CASE WHEN _offer_titles = '' THEN _offer.title
                              ELSE _offer_titles || ', ' || _offer.title END;
      END IF;
    END IF;

    _mods_total := 0;
    _line := 0;
    INSERT INTO public.order_items (order_id, product_id, size_id, product_name, size_name,
      unit_price, base_price, offer_id, bundle_key, modifiers_total, quantity, line_total, unit_cost, notes)
    VALUES (_order, _product.id, _size.id, _product.name, _size.name,
      _unit_price, _base_price, _oid, _bkey, 0, _qty, 0, _unit_cost, NULLIF(_item->>'notes',''))
    RETURNING order_items.id INTO _item_id;

    IF _item ? 'modifiers' THEN
      FOR _mod IN SELECT * FROM jsonb_array_elements(_item->'modifiers') LOOP
        SELECT mo.* INTO _opt FROM public.modifier_options mo
        JOIN public.modifier_groups mg ON mg.id = mo.group_id
        WHERE mo.id = NULLIF(_mod->>'option_id','')::uuid AND mo.is_active AND mg.company_id = _company;
        IF _opt.id IS NULL THEN RAISE EXCEPTION 'Selected add-on is not available'; END IF;
        _mods_total := _mods_total + COALESCE(_opt.price_delta, 0);
        INSERT INTO public.order_item_modifiers (order_item_id, option_id, name, price_delta)
        VALUES (_item_id, _opt.id, _opt.name, COALESCE(_opt.price_delta,0));
      END LOOP;
    END IF;

    _line := round((_unit_price + _mods_total) * _qty, 2);
    UPDATE public.order_items SET modifiers_total = _mods_total, line_total = _line
    WHERE order_items.id = _item_id;

    IF _offer.id IS NOT NULL AND _offer.double_points THEN
      _double_value := _double_value + _line;
    END IF;

    _subtotal := _subtotal + _line;
    IF _product.is_taxable THEN _taxable_base := _taxable_base + _line; END IF;
  END LOOP;

  IF _offer_savings > 0 THEN
    _reason := COALESCE(NULLIF(_reason,'') || ' | ', '') || 'Offer: ' || _offer_titles
      || ' (saved ' || to_char(_offer_savings, 'FM999999990.00') || ')';
  END IF;

  IF _discount > _subtotal THEN
    IF _voucher.id IS NOT NULL THEN _discount := _subtotal;
    ELSE RAISE EXCEPTION 'Discount exceeds order subtotal';
    END IF;
  END IF;

  IF _tax_enabled AND _subtotal > 0 THEN
    _tax := round(((_taxable_base - (_discount * (_taxable_base / _subtotal))) * _tax_rate / 100)::numeric, 2);
  END IF;
  _total := round((_subtotal - _discount + _tax)::numeric, 2);

  UPDATE public.orders SET subtotal = _subtotal, tax_amount = _tax, total = _total,
    discount_amount = _discount, discount_reason = _reason,
    promotional_discount = round(_offer_savings, 2)
  WHERE orders.id = _order;

  _cfg := public.loyalty_config(_company);
  _point_value := GREATEST(COALESCE((_cfg->>'point_value')::numeric, 1), 0.01);

  FOR _pay IN SELECT * FROM jsonb_array_elements(COALESCE(_payments,'[]'::jsonb)) LOOP
    _pay_amount := COALESCE((_pay->>'amount')::numeric, 0);
    _remaining := round(_total - _paid, 2);

    -- Pay (part of) the bill from the customer's cashback wallet.
    IF _pay->>'method_key' IN ('cashback', 'points') THEN
      IF _cust IS NULL THEN RAISE EXCEPTION 'Cashback payment requires a customer'; END IF;
      IF _pay_amount <= 0 THEN CONTINUE; END IF;
      SELECT COALESCE(wallet_balance, 0) INTO _wallet FROM public.customers
       WHERE id = _cust AND company_id = _company FOR UPDATE;
      IF _pay_amount > _remaining THEN _pay_amount := GREATEST(_remaining, 0); END IF;
      _pay_amount := round(_pay_amount, 2);
      IF _cashback_used + _pay_amount > COALESCE(_wallet, 0) + 0.001 THEN
        RAISE EXCEPTION 'Customer cashback balance is not enough (% available)', round(COALESCE(_wallet, 0) - _cashback_used, 2);
      END IF;
      IF _pay_amount <= 0 THEN CONTINUE; END IF;
      INSERT INTO public.order_payments (order_id, payment_method_id, method_key, amount, reference, created_by)
      VALUES (_order, NULL, 'cashback', _pay_amount, 'Cashback wallet', _profile);
      _cashback_used := _cashback_used + _pay_amount;
      _paid := _paid + _pay_amount;
      CONTINUE;
    END IF;

    IF _pay_amount <= 0 THEN RAISE EXCEPTION 'Payment amount must be greater than zero'; END IF;

    _pay_kind := NULL;
    SELECT pm.kind INTO _pay_kind FROM public.payment_methods pm
    WHERE pm.company_id = _company
      AND (pm.id = NULLIF(_pay->>'payment_method_id','')::uuid OR pm.key = _pay->>'method_key')
    LIMIT 1;

    IF COALESCE(_pay_kind, _pay->>'method_key') = 'cash' THEN
      IF _pay_amount > _remaining THEN _pay_amount := GREATEST(_remaining, 0); END IF;
    ELSIF _pay_amount > _remaining + 0.001 THEN
      RAISE EXCEPTION 'Payment (%) exceeds the amount still due (%)', round(_pay_amount,2), GREATEST(_remaining,0);
    END IF;
    IF _pay_amount <= 0 THEN CONTINUE; END IF;

    INSERT INTO public.order_payments (order_id, payment_method_id, method_key, amount, reference,
      sender_number, receiver_number, created_by)
    VALUES (_order, NULLIF(_pay->>'payment_method_id','')::uuid, _pay->>'method_key',
      _pay_amount, NULLIF(_pay->>'reference',''), NULLIF(_pay->>'sender_number',''),
      NULLIF(_pay->>'receiver_number',''), _profile);
    _paid := _paid + _pay_amount;
  END LOOP;

  IF _tab THEN
    INSERT INTO public.partner_tab_orders (company_id, branch_id, order_id, partner_id,
      total_amount, is_settled, created_by)
    VALUES (_company, _branch_id, _order, _partner.id, _total, false, _profile);

    IF _partner.user_id IS NOT NULL THEN
      INSERT INTO public.notifications (company_id, branch_id, user_id, type, severity, title, body, data)
      VALUES (_company, _branch_id, _partner.user_id, 'partner_tab.new', 'warning',
        'طلب جديد على الحساب الشخصي',
        'تم تسجيل فاتورة رقم #' || _number || ' بقيمة ' || to_char(_total,'FM999999990.00')
          || ' ج.م (بسعر المنيو) على حسابك الشخصي، وسيتم خصمها من أرباحك الصافية.',
        jsonb_build_object('order_id', _order, 'order_number', _number,
          'partner_id', _partner.id, 'total', _total));
    END IF;

    PERFORM public.log_audit('partner_tab.charge','partners','partner_tab_orders',_order,NULL,
      jsonb_build_object('order_number',_number,'partner_id',_partner.id,'total',_total),NULL,_branch_id);
  ELSIF round(_paid,2) < _total THEN
    RAISE EXCEPTION 'Payments (%) are less than order total (%)', round(_paid,2), _total;
  END IF;

  IF _voucher.id IS NOT NULL THEN
    UPDATE public.customer_vouchers
    SET status = 'used', settlement = 'discount', order_id = _order,
        redeemed_at = now(), redeemed_by = _profile
    WHERE id = _voucher.id;
  END IF;

  IF _cust IS NOT NULL THEN
    UPDATE public.customers
       SET total_spent = COALESCE(total_spent, 0) + _total, visits = COALESCE(visits, 0) + 1,
           last_visit_at = now(), updated_at = now()
     WHERE id = _cust;
    IF _cashback_used > 0 THEN
      PERFORM public._wallet_post(_company, _cust, _order, 'redeem', -_cashback_used,
        'سداد من رصيد الكاش باك — فاتورة #' || _number, _profile);
    END IF;
    -- Money actually paid (not wallet, not partner tab) counts toward the next reward.
    IF NOT _tab THEN
      _cashback_earned := public._cashback_accrue(_company, _cust, _order, _total - _cashback_used, _number, _profile);
    END IF;
  END IF;

  PERFORM public.log_audit('order.create','pos','orders',_order,NULL,
    jsonb_build_object('order_number',_number,'total',_total,'customer_id',_cust,
      'cashback_used',_cashback_used,'cashback_earned',_cashback_earned,'offer_savings',_offer_savings,
      'offers',_offer_titles,'partner_tab',_tab),NULL,_branch_id);

  RETURN QUERY SELECT _order, _number;
END $function$;

-- refund_order / refund_order_items: latest versions without the points reversal.
CREATE OR REPLACE FUNCTION public.refund_order(_order_id uuid, _amount numeric, _reason text, _method_key text DEFAULT 'cash'::text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE _profile uuid := public.current_profile_id(); _o public.orders;
  _paid numeric := 0; _already numeric := 0; _remaining numeric; _tax_share numeric := 0;
  _kind text; _id uuid; _r record;
  _earned int := 0; _reversed int := 0; _take int := 0; _balance int;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('pos.process_refund') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF _reason IS NULL OR length(btrim(_reason)) < 3 THEN RAISE EXCEPTION 'A reason is required'; END IF;

  SELECT * INTO _o FROM public.orders WHERE id = _order_id;
  IF _o.id IS NULL THEN RAISE EXCEPTION 'Order not found'; END IF;
  IF NOT public.can_access_branch(_o.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _o.status <> 'completed' THEN RAISE EXCEPTION 'Only completed orders can be refunded'; END IF;

  SELECT COALESCE(SUM(amount),0) INTO _paid FROM public.order_payments WHERE order_id = _order_id;
  SELECT COALESCE(SUM(amount),0) INTO _already
  FROM public.order_refunds WHERE order_id = _order_id AND status = 'active';

  _remaining := round(_paid - _already, 2);
  IF _remaining <= 0 THEN RAISE EXCEPTION 'This order is fully refunded'; END IF;
  IF _amount IS NULL OR _amount <= 0 THEN RAISE EXCEPTION 'Refund amount must be greater than zero'; END IF;
  IF round(_amount,2) > _remaining THEN
    RAISE EXCEPTION 'Refund (%) is more than the refundable amount (%)', round(_amount,2), _remaining;
  END IF;

  IF _paid > 0 AND _o.tax_amount > 0 THEN
    _tax_share := round(_o.tax_amount * LEAST(round(_amount,2) / _paid, 1), 2);
  END IF;
  _kind := CASE WHEN round(_amount,2) = _remaining THEN 'full' ELSE 'partial' END;

  INSERT INTO public.order_refunds (company_id, branch_id, order_id, shift_id, kind, amount,
    tax_amount, method_key, reason, created_by)
  VALUES (_o.company_id, _o.branch_id, _o.id, public.refund_shift_for(_o, _method_key), _kind, round(_amount,2),
    _tax_share, COALESCE(NULLIF(_method_key,''),'cash'), _reason, _profile)
  RETURNING id INTO _id;

  IF _kind = 'full' THEN
    FOR _r IN SELECT id FROM public.order_items WHERE order_id = _order_id AND status = 'active' LOOP
      PERFORM public.return_line_stock(_r.id);
    END LOOP;
    UPDATE public.orders SET status = 'refunded', updated_at = now() WHERE id = _order_id;
  END IF;

  -- Customer spend follows the refund (cashback side handled by trg_refund_cashback).
  IF _o.customer_id IS NOT NULL THEN
    UPDATE public.customers SET total_spent = GREATEST(COALESCE(total_spent, 0) - round(_amount, 2), 0), updated_at = now()
     WHERE id = _o.customer_id;
  END IF;

  PERFORM public.log_audit('order.refund','pos','orders',_order_id,
    jsonb_build_object('paid',_paid,'refunded_before',_already),
    jsonb_build_object('refund_amount',round(_amount,2),'kind',_kind,'points_reversed',GREATEST(_take,0)),
    _reason, _o.branch_id);
  RETURN _id;
END
$fn$;

-- Who may refund an order: managers (pos.process_refund) anywhere, and the
-- cashier team for orders of their own still-open shift — a standard
-- counter operation that needs no manager.
CREATE OR REPLACE FUNCTION public.can_refund_order(_o public.orders)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT public.is_super_admin() OR public.has_permission('pos.process_refund')
      OR (public.has_permission('pos.create_order') AND EXISTS (
            SELECT 1 FROM public.shifts s
             WHERE s.id = _o.shift_id AND s.status = 'open'
               AND (s.user_id = public.current_profile_id()
                    OR EXISTS (SELECT 1 FROM public.shift_staff ss
                                WHERE ss.shift_id = s.id AND ss.staff_id = public.current_profile_id()))))
$$;
REVOKE ALL ON FUNCTION public.can_refund_order(public.orders) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_refund_order(public.orders) TO authenticated;

CREATE OR REPLACE FUNCTION public.refund_order_items(
  _order_id uuid,
  _items jsonb,
  _method_key text DEFAULT 'cash',
  _reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  _profile uuid := public.current_profile_id();
  _o public.orders;
  _entry jsonb;
  _r record;
  _item_id uuid;
  _qty int;
  _disposition text;
  _oi public.order_items;
  _refunded_qty int;
  _remaining_qty int;
  _line_gross numeric := 0;
  _amount numeric := 0;
  _paid numeric;
  _already numeric;
  _ratio numeric;
  _payload jsonb := '[]'::jsonb;
  _refund_id uuid;
  _tax_share numeric := 0;
  _earned int := 0;
  _reversed int := 0;
  _take int := 0;
  _balance int;
  _all_done boolean := false;
  _new_status text;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF _reason IS NULL OR length(btrim(_reason)) < 3 THEN RAISE EXCEPTION 'A reason is required'; END IF;
  IF _items IS NULL OR jsonb_array_length(_items) = 0 THEN RAISE EXCEPTION 'No refund items provided'; END IF;

  SELECT * INTO _o FROM public.orders WHERE id = _order_id FOR UPDATE;
  IF _o.id IS NULL THEN RAISE EXCEPTION 'Order not found'; END IF;
  IF NOT public.can_refund_order(_o) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF NOT public.can_access_branch(_o.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _o.status NOT IN ('completed','partially_refunded') THEN
    RAISE EXCEPTION 'Only delivered orders can be refunded';
  END IF;

  SELECT COALESCE(SUM(amount),0) INTO _paid FROM public.order_payments WHERE order_id = _order_id;
  SELECT COALESCE(SUM(amount),0) INTO _already FROM public.order_refunds WHERE order_id = _order_id AND status = 'active';
  IF round(_paid - _already, 2) <= 0 THEN RAISE EXCEPTION 'This order is fully refunded'; END IF;

  -- Pass 1: validate every entry and compute the gross refund value.
  FOR _entry IN SELECT * FROM jsonb_array_elements(_items) LOOP
    _item_id := NULLIF(_entry->>'order_item_id','')::uuid;
    _qty := COALESCE((_entry->>'quantity')::int, 0);
    _disposition := COALESCE(NULLIF(_entry->>'disposition',''), 'restock');
    IF _disposition NOT IN ('restock','waste') THEN RAISE EXCEPTION 'Invalid disposition'; END IF;
    IF _qty <= 0 THEN RAISE EXCEPTION 'Refund quantity must be greater than zero'; END IF;

    SELECT * INTO _oi FROM public.order_items
    WHERE id = _item_id AND order_id = _order_id;
    IF _oi.id IS NULL THEN RAISE EXCEPTION 'Order line not found'; END IF;
    IF _oi.status = 'voided' THEN RAISE EXCEPTION 'Line % is already voided', _oi.product_name; END IF;

    SELECT COALESCE(SUM((e->>'quantity')::int),0) INTO _refunded_qty
    FROM public.order_refunds r,
         jsonb_array_elements(COALESCE(r.items_payload,'[]'::jsonb)) e
    WHERE r.order_id = _order_id AND r.status = 'active' AND r.origin = 'manual'
      AND e->>'order_item_id' = _item_id::text;

    _remaining_qty := _oi.quantity - _refunded_qty;
    IF _qty > _remaining_qty THEN
      RAISE EXCEPTION 'Cannot refund more than the remaining % on %', _remaining_qty, _oi.product_name;
    END IF;

    _line_gross := _line_gross + round((COALESCE(_oi.unit_price,0) + COALESCE(_oi.modifiers_total,0)) * _qty, 2);
  END LOOP;

  IF _line_gross <= 0 THEN RAISE EXCEPTION 'Nothing to refund'; END IF;

  -- Proportional share of the invoice total (discount + tax included).
  _ratio := CASE WHEN COALESCE(_o.subtotal,0) > 0 THEN _o.total / _o.subtotal ELSE 1 END;
  _amount := round(LEAST(_line_gross * _ratio, round(_paid - _already, 2)), 2);

  IF _paid > 0 AND COALESCE(_o.tax_amount,0) > 0 THEN
    _tax_share := round(_o.tax_amount * LEAST(_amount / _paid, 1), 2);
  END IF;

  -- Pass 2: stock side-effects + payload.
  FOR _entry IN SELECT * FROM jsonb_array_elements(_items) LOOP
    _item_id := NULLIF(_entry->>'order_item_id','')::uuid;
    _qty := (_entry->>'quantity')::int;
    _disposition := COALESCE(NULLIF(_entry->>'disposition',''), 'restock');
    SELECT * INTO _oi FROM public.order_items WHERE id = _item_id;

    IF _disposition = 'restock' THEN
      IF _qty = _oi.quantity THEN
        PERFORM public.return_line_stock(_item_id);
      ELSE
        FOR _r IN SELECT sm.item_id, sm.quantity, sm.branch_id
                  FROM public.stock_movements sm
                  WHERE sm.reference_type = 'order_item'
                    AND sm.movement_type = 'sale_consumption'
                    AND sm.reference_id = _item_id
        LOOP
          PERFORM public.apply_stock_movement(_r.branch_id, _r.item_id, 'sale_return',
            -round(_r.quantity * _qty / _oi.quantity, 3), NULL,
            'Partial item refund (restock)', 'order_item', _item_id);
        END LOOP;
      END IF;
    END IF;
    -- Waste: ingredients were consumed at sale time; stock stays as-is.
    -- The loss is recorded in items_payload and surfaced on the shift waste card.

    _payload := _payload || jsonb_build_object(
      'order_item_id', _item_id,
      'product_name', _oi.product_name,
      'quantity', _qty,
      'unit_price', COALESCE(_oi.unit_price,0),
      'unit_cost', COALESCE(_oi.unit_cost,0),
      'line_gross', round((COALESCE(_oi.unit_price,0) + COALESCE(_oi.modifiers_total,0)) * _qty, 2),
      'disposition', _disposition);
  END LOOP;

  INSERT INTO public.order_refunds
    (company_id, branch_id, order_id, shift_id, kind, amount, tax_amount, method_key,
     reason, status, origin, items_payload, created_by)
  VALUES
    (_o.company_id, _o.branch_id, _o.id, public.refund_shift_for(_o, _method_key), 'partial', _amount, _tax_share,
     COALESCE(NULLIF(_method_key,''),'cash'), _reason, 'active', 'manual', _payload, _profile)
  RETURNING id INTO _refund_id;

  -- Customer spend follows the refund (cashback side handled by trg_refund_cashback).
  IF _o.customer_id IS NOT NULL THEN
    UPDATE public.customers SET total_spent = GREATEST(COALESCE(total_spent, 0) - round(_amount, 2), 0), updated_at = now()
     WHERE id = _o.customer_id;
  END IF;

  PERFORM public.log_audit('order.refund_items', 'pos', 'orders', _order_id,
    jsonb_build_object('paid', _paid, 'refunded_before', _already),
    jsonb_build_object('refund_id', _refund_id, 'amount', _amount,
      'items', _payload, 'status', _new_status, 'points_reversed', GREATEST(_take,0)),
    _reason, _o.branch_id);

  RETURN jsonb_build_object('refund_id', _refund_id, 'amount', _amount,
    'kind', CASE WHEN _all_done THEN 'full' ELSE 'partial' END,
    'status', _new_status, 'points_reversed', GREATEST(_take,0));
END;
$$;

-- ---------------------------------------------------------------------
-- Operational resets also clear cashback wallets and their history
-- (wallet rows reference orders, so they must go first).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.execute_operational_reset(p_confirm text DEFAULT 'RESET-20S')
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _company uuid;
BEGIN
  -- 1. Guards: authenticated super admin with explicit confirmation
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Unauthorized: Only Super Admin can execute reset.';
  END IF;
  IF p_confirm <> 'RESET-20S' THEN
    RAISE EXCEPTION 'confirmation text does not match';
  END IF;
  _company := public.current_company_id();
  IF _company IS NULL THEN
    RAISE EXCEPTION 'no company context';
  END IF;

  -- 2. Bypass delete-guard triggers and FK constraints for this transaction
  SET LOCAL session_replication_role = 'replica';

  -- 3. Wipe operational transaction tables (no column filters, no row-level guards)
  TRUNCATE TABLE
    public.order_item_modifiers,
    public.order_items,
    public.order_payments,
    public.order_refunds,
    public.orders,
    public.order_counters,
    public.shifts,
    public.purchase_return_items,
    public.purchase_returns,
    public.purchase_payments,
    public.purchase_items,
    public.purchases,
    public.expenses,
    public.stock_movements,
    public.cash_transactions,
    public.customer_points_transactions,
    public.customer_vouchers,
    public.customer_wallet_transactions,
    public.attendance
  RESTART IDENTITY CASCADE;

  -- 4. Zero balances
  UPDATE public.cash_accounts SET current_balance = 0.00, opening_balance = 0.00;
  UPDATE public.branch_stock SET quantity = 0;
  UPDATE public.customers SET points_balance = 0, wallet_balance = 0, cashback_progress = 0;

  -- 5. Restore normal constraint enforcement
  SET LOCAL session_replication_role = 'origin';

  PERFORM public.log_audit(
    'system.reset_operational', 'settings', 'companies', _company,
    NULL, jsonb_build_object('method', 'truncate_cascade'), NULL, NULL);

  RETURN jsonb_build_object('success', true, 'message', 'Operational data reset successfully');
EXCEPTION WHEN OTHERS THEN
  SET LOCAL session_replication_role = 'origin';
  RAISE;
END;
$$;

CREATE OR REPLACE FUNCTION public.execute_operational_reset(
  p_confirm text DEFAULT 'RESET-20S',
  p_targets text[] DEFAULT ARRAY['all']
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_all boolean;
  v_company uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Unauthorized: Only Super Admin can execute reset.';
  END IF;
  IF p_confirm <> 'RESET-20S' THEN
    RAISE EXCEPTION 'Confirmation code mismatch. Type RESET-20S.';
  END IF;

  v_company := public.current_company_id();
  v_all := ('all' = ANY(p_targets));

  SET LOCAL session_replication_role = 'replica';

  -- Target 1: Sales & Orders
  IF v_all OR ('orders' = ANY(p_targets)) THEN
    TRUNCATE TABLE
      public.order_item_modifiers,
      public.order_items,
      public.order_payments,
      public.order_refunds,
      public.orders,
      public.order_counters
    RESTART IDENTITY CASCADE;
  END IF;

  -- Target 2: Shifts
  IF v_all OR ('shifts' = ANY(p_targets)) THEN
    TRUNCATE TABLE public.shifts RESTART IDENTITY CASCADE;
  END IF;

  -- Target 3: Purchases
  IF v_all OR ('purchases' = ANY(p_targets)) THEN
    TRUNCATE TABLE
      public.purchase_payments,
      public.purchase_items,
      public.purchases
    RESTART IDENTITY CASCADE;
  END IF;

  -- Target 4: Purchase Returns
  IF v_all OR ('purchase_returns' = ANY(p_targets)) THEN
    TRUNCATE TABLE
      public.purchase_return_items,
      public.purchase_returns
    RESTART IDENTITY CASCADE;
  END IF;

  -- Target 5: Expenses
  IF v_all OR ('expenses' = ANY(p_targets)) THEN
    TRUNCATE TABLE public.expenses RESTART IDENTITY CASCADE;
  END IF;

  -- Target 6: Stock Movements & Branch Inventory
  IF v_all OR ('stock_movements' = ANY(p_targets)) THEN
    TRUNCATE TABLE public.stock_movements RESTART IDENTITY CASCADE;
    -- Explicit WHERE clause to satisfy safeupdate guards
    UPDATE public.branch_stock SET quantity = 0 WHERE id IS NOT NULL;
  END IF;

  -- Target 7: Treasury & Cash
  IF v_all OR ('cash_transactions' = ANY(p_targets)) THEN
    TRUNCATE TABLE public.cash_transactions RESTART IDENTITY CASCADE;
  END IF;

  -- Target 8: Customer cashback (wallets, history, legacy points & vouchers)
  IF v_all OR ('loyalty' = ANY(p_targets)) THEN
    TRUNCATE TABLE
      public.customer_points_transactions,
      public.customer_vouchers,
      public.customer_wallet_transactions
    RESTART IDENTITY CASCADE;
    -- Explicit WHERE clause to satisfy safeupdate guards
    UPDATE public.customers SET points_balance = 0, wallet_balance = 0, cashback_progress = 0 WHERE id IS NOT NULL;
  END IF;

  -- Target 9: Attendance
  IF v_all OR ('attendance' = ANY(p_targets)) THEN
    TRUNCATE TABLE public.attendance RESTART IDENTITY CASCADE;
  END IF;

  SET LOCAL session_replication_role = 'origin';

  IF v_company IS NOT NULL THEN
    PERFORM public.log_audit(
      'system.modular_reset', 'settings', 'companies', v_company,
      NULL, jsonb_build_object('targets', p_targets, 'method', 'truncate_cascade'), NULL, NULL
    );
  END IF;

  RETURN jsonb_build_object('success', true, 'message', 'Selected modules reset successfully');

EXCEPTION WHEN OTHERS THEN
  SET LOCAL session_replication_role = 'origin';
  RAISE;
END;
$$;

CREATE OR REPLACE FUNCTION public.reset_operational_data(p_confirm text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _company uuid := public.current_company_id(); _profile uuid := public.current_profile_id();
  _tbl text; _counts jsonb := '{}'::jsonb; _n bigint;
  _guarded text[] := ARRAY['orders','order_items','order_payments','order_refunds','purchases','purchase_items',
    'expenses','stock_movements','cash_transactions','customer_vouchers','shifts'];
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_confirm <> 'RESET-20S' THEN RAISE EXCEPTION 'Confirmation text does not match'; END IF;

  FOREACH _tbl IN ARRAY _guarded LOOP
    EXECUTE format('ALTER TABLE public.%I DISABLE TRIGGER USER', _tbl);
  END LOOP;

  DELETE FROM public.order_item_modifiers m USING public.order_items oi, public.orders o
    WHERE m.order_item_id = oi.id AND oi.order_id = o.id AND o.company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('order_item_modifiers', _n);

  DELETE FROM public.order_refunds WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('order_refunds', _n);
  DELETE FROM public.order_payments p USING public.orders o WHERE p.order_id = o.id AND o.company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('order_payments', _n);
  DELETE FROM public.order_items oi USING public.orders o WHERE oi.order_id = o.id AND o.company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('order_items', _n);
  DELETE FROM public.customer_wallet_transactions WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('customer_wallet_transactions', _n);
  DELETE FROM public.customer_points_transactions WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('customer_points_transactions', _n);
  DELETE FROM public.customer_vouchers WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('customer_vouchers', _n);
  DELETE FROM public.orders WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('orders', _n);
  DELETE FROM public.order_counters WHERE branch_id IN (SELECT id FROM public.branches WHERE company_id = _company);
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('order_counters', _n);
  DELETE FROM public.shifts WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('shifts', _n);
  DELETE FROM public.purchase_return_items ri USING public.purchase_returns pr
    WHERE ri.purchase_return_id = pr.id AND pr.company_id = _company;
  DELETE FROM public.purchase_returns WHERE company_id = _company;
  DELETE FROM public.purchase_payments WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('purchase_payments', _n);
  DELETE FROM public.purchase_items pi USING public.purchases pu WHERE pi.purchase_id = pu.id AND pu.company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('purchase_items', _n);
  DELETE FROM public.purchases WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('purchases', _n);
  DELETE FROM public.expenses WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('expenses', _n);
  DELETE FROM public.stock_movements WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('stock_movements', _n);
  DELETE FROM public.cash_transactions WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('cash_transactions', _n);

  UPDATE public.branch_stock SET quantity = 0
   WHERE branch_id IN (SELECT id FROM public.branches WHERE company_id = _company);
  UPDATE public.cash_accounts SET opening_balance = 0 WHERE company_id = _company;
  UPDATE public.customers SET points_balance = 0, wallet_balance = 0, cashback_progress = 0 WHERE company_id = _company;

  FOREACH _tbl IN ARRAY _guarded LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE TRIGGER USER', _tbl);
  END LOOP;

  PERFORM public.log_audit('system.reset_operational','settings','companies',_company,NULL,_counts,NULL,NULL);
  RETURN _counts;
END $$;
