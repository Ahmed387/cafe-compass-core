-- ===== Loyalty: customers, points, vouchers =====
CREATE SEQUENCE IF NOT EXISTS public.customer_code_seq START 1;

CREATE TABLE public.customers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  code text NOT NULL,
  name text NOT NULL,
  phone text NOT NULL,
  barcode text NOT NULL,
  points_balance integer NOT NULL DEFAULT 0,
  total_spent numeric(14,2) NOT NULL DEFAULT 0,
  visits integer NOT NULL DEFAULT 0,
  last_visit_at timestamptz,
  notes text,
  is_active boolean NOT NULL DEFAULT true,
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX customers_company_phone_key ON public.customers(company_id, phone);
CREATE UNIQUE INDEX customers_company_code_key ON public.customers(company_id, code);
CREATE UNIQUE INDEX customers_barcode_key ON public.customers(barcode);

GRANT SELECT ON public.customers TO authenticated;
GRANT ALL ON public.customers TO service_role;
ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;
CREATE POLICY "customers_select" ON public.customers FOR SELECT TO authenticated
  USING (company_id = public.current_company_id()
    AND (public.has_permission('loyalty.view') OR public.has_permission('pos.view') OR public.is_super_admin()));

CREATE TRIGGER customers_set_updated_at BEFORE UPDATE ON public.customers
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER customers_no_delete BEFORE DELETE ON public.customers
  FOR EACH ROW EXECUTE FUNCTION public.forbid_hard_delete();

CREATE TABLE public.customer_points_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  customer_id uuid NOT NULL REFERENCES public.customers(id),
  order_id uuid REFERENCES public.orders(id),
  voucher_id uuid,
  kind text NOT NULL,
  points integer NOT NULL,
  balance_after integer NOT NULL,
  description text,
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX customer_points_tx_customer_idx ON public.customer_points_transactions(customer_id, created_at DESC);
GRANT SELECT ON public.customer_points_transactions TO authenticated;
GRANT ALL ON public.customer_points_transactions TO service_role;
ALTER TABLE public.customer_points_transactions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "customer_points_tx_select" ON public.customer_points_transactions FOR SELECT TO authenticated
  USING (company_id = public.current_company_id()
    AND (public.has_permission('loyalty.view') OR public.has_permission('pos.view') OR public.is_super_admin()));

CREATE TABLE public.customer_vouchers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  customer_id uuid NOT NULL REFERENCES public.customers(id),
  code text NOT NULL,
  amount numeric(14,2) NOT NULL CHECK (amount > 0),
  points_cost integer NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'active',
  settlement text,
  expires_at date,
  order_id uuid REFERENCES public.orders(id),
  expense_id uuid REFERENCES public.expenses(id),
  redeemed_at timestamptz,
  redeemed_by uuid REFERENCES public.user_profiles(id),
  notes text,
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX customer_vouchers_code_key ON public.customer_vouchers(code);
CREATE INDEX customer_vouchers_customer_idx ON public.customer_vouchers(customer_id, created_at DESC);
GRANT SELECT ON public.customer_vouchers TO authenticated;
GRANT ALL ON public.customer_vouchers TO service_role;
ALTER TABLE public.customer_vouchers ENABLE ROW LEVEL SECURITY;
CREATE POLICY "customer_vouchers_select" ON public.customer_vouchers FOR SELECT TO authenticated
  USING (company_id = public.current_company_id()
    AND (public.has_permission('loyalty.view') OR public.has_permission('pos.view') OR public.is_super_admin()));
CREATE TRIGGER customer_vouchers_set_updated_at BEFORE UPDATE ON public.customer_vouchers
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER customer_vouchers_no_delete BEFORE DELETE ON public.customer_vouchers
  FOR EACH ROW EXECUTE FUNCTION public.forbid_hard_delete();

-- ===== Permissions =====
INSERT INTO public.permissions (key, name, description, module) VALUES
  ('loyalty.view','View loyalty','View customers, points and vouchers','loyalty'),
  ('loyalty.manage','Manage loyalty','Issue and settle vouchers, adjust points','loyalty'),
  ('analytics.view','View analytics','Product demand and marketing analytics','analytics')
ON CONFLICT (key) DO NOTHING;

INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM public.roles r JOIN public.permissions p ON true
WHERE (r.key IN ('super_admin','manager') AND p.key IN ('loyalty.view','loyalty.manage','analytics.view'))
   OR (r.key = 'accountant' AND p.key IN ('loyalty.view','analytics.view'))
   OR (r.key = 'cashier' AND p.key = 'loyalty.view')
ON CONFLICT DO NOTHING;

-- ===== Settings =====
CREATE OR REPLACE FUNCTION public.loyalty_settings()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(
    (SELECT value FROM public.app_settings
      WHERE company_id = public.current_company_id() AND key = 'loyalty' LIMIT 1),
    '{}'::jsonb
  ) || '{}'::jsonb
$$;

CREATE OR REPLACE FUNCTION public.loyalty_config(_company uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT jsonb_build_object('enabled', true, 'currency_per_point', 10, 'point_value', 1)
      || COALESCE((SELECT value FROM public.app_settings
                   WHERE company_id = _company AND key = 'loyalty' LIMIT 1), '{}'::jsonb)
$$;

CREATE OR REPLACE FUNCTION public.set_loyalty_settings(_value jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _company uuid := public.current_company_id();
BEGIN
  IF NOT (public.has_permission('loyalty.manage') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  INSERT INTO public.app_settings (company_id, scope, key, value)
  VALUES (_company, 'company', 'loyalty', _value)
  ON CONFLICT DO NOTHING;
  UPDATE public.app_settings SET value = _value, updated_at = now()
  WHERE company_id = _company AND key = 'loyalty';
  PERFORM public.log_audit('loyalty.settings','loyalty','app_settings',NULL,NULL,_value,NULL,NULL);
  RETURN public.loyalty_config(_company);
END $$;

-- ===== Customer upsert =====
CREATE OR REPLACE FUNCTION public.upsert_customer(_name text, _phone text, _customer_id uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  _company uuid := public.current_company_id();
  _profile uuid := public.current_profile_id();
  _id uuid;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('loyalty.manage') OR public.has_permission('pos.create_order')
          OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF COALESCE(btrim(_name),'') = '' THEN RAISE EXCEPTION 'Customer name is required'; END IF;
  IF COALESCE(btrim(_phone),'') = '' THEN RAISE EXCEPTION 'Customer phone is required'; END IF;

  IF _customer_id IS NOT NULL THEN
    UPDATE public.customers SET name = btrim(_name), phone = btrim(_phone)
    WHERE id = _customer_id AND company_id = _company
    RETURNING id INTO _id;
    IF _id IS NULL THEN RAISE EXCEPTION 'Customer not found'; END IF;
    PERFORM public.log_audit('customer.update','loyalty','customers',_id,NULL,
      jsonb_build_object('name',btrim(_name),'phone',btrim(_phone)),NULL,NULL);
    RETURN _id;
  END IF;

  SELECT id INTO _id FROM public.customers WHERE company_id = _company AND phone = btrim(_phone);
  IF _id IS NOT NULL THEN RETURN _id; END IF;

  INSERT INTO public.customers (company_id, code, name, phone, barcode, created_by)
  VALUES (_company, 'C-' || lpad(nextval('public.customer_code_seq')::text, 5, '0'),
    btrim(_name), btrim(_phone), upper(encode(gen_random_bytes(6), 'hex')), _profile)
  RETURNING id INTO _id;

  PERFORM public.log_audit('customer.create','loyalty','customers',_id,NULL,
    jsonb_build_object('name',btrim(_name),'phone',btrim(_phone)),NULL,NULL);
  RETURN _id;
END $$;

-- ===== Manual points adjustment =====
CREATE OR REPLACE FUNCTION public.adjust_customer_points(_customer_id uuid, _points integer, _reason text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  _company uuid := public.current_company_id();
  _profile uuid := public.current_profile_id();
  _balance integer;
BEGIN
  IF NOT (public.has_permission('loyalty.manage') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF COALESCE(_points,0) = 0 THEN RAISE EXCEPTION 'Points must not be zero'; END IF;
  IF COALESCE(btrim(_reason),'') = '' THEN RAISE EXCEPTION 'Reason is required'; END IF;

  UPDATE public.customers SET points_balance = points_balance + _points
  WHERE id = _customer_id AND company_id = _company
  RETURNING points_balance INTO _balance;
  IF _balance IS NULL THEN RAISE EXCEPTION 'Customer not found'; END IF;
  IF _balance < 0 THEN RAISE EXCEPTION 'Points balance cannot go negative'; END IF;

  INSERT INTO public.customer_points_transactions
    (company_id, customer_id, kind, points, balance_after, description, created_by)
  VALUES (_company, _customer_id, 'adjust', _points, _balance, btrim(_reason), _profile);

  PERFORM public.log_audit('customer.points_adjust','loyalty','customers',_customer_id,NULL,
    jsonb_build_object('points',_points,'reason',_reason),NULL,NULL);
  RETURN _balance;
END $$;

-- ===== Voucher issue / cancel / cash settle =====
CREATE OR REPLACE FUNCTION public.issue_customer_voucher(
  _customer_id uuid, _amount numeric, _points_cost integer DEFAULT 0,
  _expires_at date DEFAULT NULL, _notes text DEFAULT NULL)
RETURNS TABLE(out_id uuid, out_code text) LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  _company uuid := public.current_company_id();
  _profile uuid := public.current_profile_id();
  _balance integer;
  _code text;
  _id uuid;
BEGIN
  IF NOT (public.has_permission('loyalty.manage') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF COALESCE(_amount,0) <= 0 THEN RAISE EXCEPTION 'Voucher amount must be greater than zero'; END IF;
  IF COALESCE(_points_cost,0) < 0 THEN RAISE EXCEPTION 'Points cost cannot be negative'; END IF;

  SELECT points_balance INTO _balance FROM public.customers
  WHERE id = _customer_id AND company_id = _company FOR UPDATE;
  IF _balance IS NULL THEN RAISE EXCEPTION 'Customer not found'; END IF;
  IF COALESCE(_points_cost,0) > _balance THEN
    RAISE EXCEPTION 'Customer does not have enough points (% available)', _balance;
  END IF;

  _code := 'V-' || upper(encode(gen_random_bytes(4), 'hex'));
  INSERT INTO public.customer_vouchers
    (company_id, customer_id, code, amount, points_cost, expires_at, notes, created_by)
  VALUES (_company, _customer_id, _code, round(_amount,2), COALESCE(_points_cost,0), _expires_at,
    NULLIF(btrim(COALESCE(_notes,'')),''), _profile)
  RETURNING id INTO _id;

  IF COALESCE(_points_cost,0) > 0 THEN
    UPDATE public.customers SET points_balance = points_balance - _points_cost
    WHERE id = _customer_id RETURNING points_balance INTO _balance;
    INSERT INTO public.customer_points_transactions
      (company_id, customer_id, voucher_id, kind, points, balance_after, description, created_by)
    VALUES (_company, _customer_id, _id, 'voucher', -_points_cost, _balance, _code, _profile);
  END IF;

  PERFORM public.log_audit('voucher.issue','loyalty','customer_vouchers',_id,NULL,
    jsonb_build_object('code',_code,'amount',_amount,'points_cost',_points_cost),NULL,NULL);
  RETURN QUERY SELECT _id, _code;
END $$;

CREATE OR REPLACE FUNCTION public.cancel_customer_voucher(_voucher_id uuid, _reason text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  _company uuid := public.current_company_id();
  _profile uuid := public.current_profile_id();
  _v public.customer_vouchers;
  _balance integer;
BEGIN
  IF NOT (public.has_permission('loyalty.manage') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  SELECT * INTO _v FROM public.customer_vouchers
  WHERE id = _voucher_id AND company_id = _company FOR UPDATE;
  IF _v.id IS NULL THEN RAISE EXCEPTION 'Voucher not found'; END IF;
  IF _v.status <> 'active' THEN RAISE EXCEPTION 'Only active vouchers can be cancelled'; END IF;

  UPDATE public.customer_vouchers SET status = 'cancelled',
    notes = COALESCE(notes || ' | ', '') || COALESCE(btrim(_reason),'')
  WHERE id = _voucher_id;

  IF _v.points_cost > 0 THEN
    UPDATE public.customers SET points_balance = points_balance + _v.points_cost
    WHERE id = _v.customer_id RETURNING points_balance INTO _balance;
    INSERT INTO public.customer_points_transactions
      (company_id, customer_id, voucher_id, kind, points, balance_after, description, created_by)
    VALUES (_company, _v.customer_id, _v.id, 'voucher_refund', _v.points_cost, _balance,
      'cancelled ' || _v.code, _profile);
  END IF;

  PERFORM public.log_audit('voucher.cancel','loyalty','customer_vouchers',_voucher_id,NULL,
    jsonb_build_object('code',_v.code,'reason',_reason),NULL,NULL);
  RETURN _voucher_id;
END $$;

CREATE OR REPLACE FUNCTION public.settle_voucher_cash(_voucher_id uuid, _branch_id uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  _company uuid := public.current_company_id();
  _profile uuid := public.current_profile_id();
  _v public.customer_vouchers;
  _cat uuid;
  _expense uuid;
  _branch uuid := _branch_id;
BEGIN
  IF NOT (public.has_permission('loyalty.manage') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  SELECT * INTO _v FROM public.customer_vouchers
  WHERE id = _voucher_id AND company_id = _company FOR UPDATE;
  IF _v.id IS NULL THEN RAISE EXCEPTION 'Voucher not found'; END IF;
  IF _v.status <> 'active' THEN RAISE EXCEPTION 'Voucher is not active'; END IF;
  IF _v.expires_at IS NOT NULL AND _v.expires_at < CURRENT_DATE THEN
    RAISE EXCEPTION 'Voucher has expired';
  END IF;

  SELECT id INTO _cat FROM public.expense_categories
  WHERE company_id = _company AND name = 'Customer Rewards' LIMIT 1;
  IF _cat IS NULL THEN
    INSERT INTO public.expense_categories (company_id, name, name_ar)
    VALUES (_company, 'Customer Rewards', 'جوائز العملاء') RETURNING id INTO _cat;
  END IF;

  IF _branch IS NULL THEN
    SELECT id INTO _branch FROM public.branches WHERE company_id = _company AND is_active
    ORDER BY created_at LIMIT 1;
  END IF;

  INSERT INTO public.expenses (company_id, branch_id, category_id, amount, expense_date,
    payment_method, vendor, description, status, approved_by, approved_at, created_by)
  VALUES (_company, _branch, _cat, _v.amount, CURRENT_DATE, 'cash',
    (SELECT name FROM public.customers WHERE id = _v.customer_id),
    'Voucher ' || _v.code, 'active', _profile, now(), _profile)
  RETURNING id INTO _expense;

  UPDATE public.customer_vouchers
  SET status = 'used', settlement = 'cash', expense_id = _expense,
      redeemed_at = now(), redeemed_by = _profile
  WHERE id = _voucher_id;

  PERFORM public.log_audit('voucher.settle_cash','loyalty','customer_vouchers',_voucher_id,NULL,
    jsonb_build_object('code',_v.code,'amount',_v.amount,'expense_id',_expense),NULL,_branch);
  RETURN _expense;
END $$;

-- ===== Public barcode lookup =====
CREATE OR REPLACE FUNCTION public.customer_card(_barcode text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE _c public.customers; _res jsonb;
BEGIN
  SELECT * INTO _c FROM public.customers WHERE barcode = upper(btrim(_barcode)) AND is_active;
  IF _c.id IS NULL THEN RETURN NULL; END IF;
  SELECT jsonb_build_object(
    'code', _c.code,
    'name', _c.name,
    'points', _c.points_balance,
    'visits', _c.visits,
    'barcode', _c.barcode,
    'company', (SELECT name FROM public.companies WHERE id = _c.company_id),
    'point_value', (public.loyalty_config(_c.company_id) ->> 'point_value')::numeric,
    'vouchers', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('code', v.code, 'amount', v.amount,
        'status', v.status, 'expires_at', v.expires_at) ORDER BY v.created_at DESC)
      FROM public.customer_vouchers v WHERE v.customer_id = _c.id AND v.status = 'active'
    ), '[]'::jsonb)
  ) INTO _res;
  RETURN _res;
END $$;
GRANT EXECUTE ON FUNCTION public.customer_card(text) TO anon, authenticated;

-- ===== Product demand analytics =====
CREATE OR REPLACE FUNCTION public.product_demand(_from date, _to date)
RETURNS TABLE(product_id uuid, name text, name_ar text, category text, image_url text,
  base_price numeric, unit_cost numeric, qty numeric, revenue numeric, cost numeric,
  margin numeric, orders_count bigint, last_sold_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p.id, p.name, p.name_ar, c.name, p.image_url, p.base_price, p.cost,
    COALESCE(SUM(oi.quantity), 0),
    COALESCE(SUM(oi.line_total), 0),
    COALESCE(SUM(oi.unit_cost * oi.quantity), 0),
    COALESCE(SUM(oi.line_total), 0) - COALESCE(SUM(oi.unit_cost * oi.quantity), 0),
    COUNT(DISTINCT o.id),
    MAX(o.created_at)
  FROM public.products p
  LEFT JOIN public.categories c ON c.id = p.category_id
  LEFT JOIN public.order_items oi ON oi.product_id = p.id AND oi.status = 'active'
  LEFT JOIN public.orders o ON o.id = oi.order_id
    AND o.status IN ('completed','refunded')
    AND o.created_at::date BETWEEN _from AND _to
  WHERE p.company_id = public.current_company_id() AND p.is_active
    AND (public.has_permission('analytics.view') OR public.has_permission('reports.sales')
         OR public.is_super_admin())
  GROUP BY p.id, p.name, p.name_ar, c.name, p.image_url, p.base_price, p.cost
  ORDER BY 9 DESC
$$;

-- ===== POS order with customer + voucher =====
DROP FUNCTION IF EXISTS public.create_pos_order(uuid, jsonb, jsonb, order_type, numeric, text, text, text, text);

CREATE FUNCTION public.create_pos_order(
  _branch_id uuid, _items jsonb, _payments jsonb, _order_type order_type DEFAULT 'takeaway',
  _discount_amount numeric DEFAULT 0, _discount_reason text DEFAULT NULL,
  _customer_name text DEFAULT NULL, _customer_phone text DEFAULT NULL, _notes text DEFAULT NULL,
  _customer_id uuid DEFAULT NULL, _voucher_code text DEFAULT NULL)
RETURNS TABLE(out_id uuid, out_number text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  _profile uuid := public.current_profile_id();
  _company uuid := public.current_company_id();
  _shift uuid;
  _order uuid;
  _number text;
  _seq int;
  _subtotal numeric := 0;
  _tax numeric := 0;
  _total numeric := 0;
  _tax_rate numeric := 0;
  _tax_enabled boolean := false;
  _paid numeric := 0;
  _item jsonb; _pay jsonb; _mod jsonb;
  _item_id uuid; _mods_total numeric; _line numeric;
  _taxable_base numeric := 0;
  _product public.products;
  _size public.product_sizes;
  _override numeric;
  _unit_price numeric; _unit_cost numeric; _qty int;
  _opt public.modifier_options;
  _pay_amount numeric; _pay_kind text; _remaining numeric;
  _voucher public.customer_vouchers;
  _discount numeric := COALESCE(_discount_amount, 0);
  _reason text := _discount_reason;
  _cfg jsonb;
  _rate numeric;
  _points int := 0;
  _balance int;
  _cust uuid := _customer_id;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('pos.create_order') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF NOT public.can_access_branch(_branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _items IS NULL OR jsonb_array_length(_items) = 0 THEN RAISE EXCEPTION 'Order has no items'; END IF;
  IF _discount > 0 AND NOT (public.has_permission('pos.apply_discount') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized to apply discounts';
  END IF;

  IF _cust IS NOT NULL THEN
    PERFORM 1 FROM public.customers WHERE id = _cust AND company_id = _company AND is_active;
    IF NOT FOUND THEN RAISE EXCEPTION 'Customer not found'; END IF;
  END IF;

  IF NULLIF(btrim(COALESCE(_voucher_code,'')),'') IS NOT NULL THEN
    SELECT * INTO _voucher FROM public.customer_vouchers
    WHERE company_id = _company AND code = upper(btrim(_voucher_code)) FOR UPDATE;
    IF _voucher.id IS NULL THEN RAISE EXCEPTION 'Voucher not found'; END IF;
    IF _voucher.status <> 'active' THEN RAISE EXCEPTION 'Voucher is not active'; END IF;
    IF _voucher.expires_at IS NOT NULL AND _voucher.expires_at < CURRENT_DATE THEN
      RAISE EXCEPTION 'Voucher has expired';
    END IF;
    IF _cust IS NULL THEN _cust := _voucher.customer_id;
    ELSIF _cust <> _voucher.customer_id THEN RAISE EXCEPTION 'Voucher belongs to another customer';
    END IF;
    _discount := _discount + _voucher.amount;
    _reason := COALESCE(NULLIF(_reason,'') || ' | ', '') || 'Voucher ' || _voucher.code;
  END IF;

  PERFORM public.check_order_stock(_branch_id, _items);

  SELECT s.id INTO _shift FROM public.shifts s
  WHERE s.branch_id = _branch_id AND s.user_id = _profile AND s.status = 'open' LIMIT 1;
  IF _shift IS NULL THEN RAISE EXCEPTION 'No open shift'; END IF;

  SELECT c.tax_enabled, c.tax_rate INTO _tax_enabled, _tax_rate FROM public.companies c WHERE c.id = _company;

  INSERT INTO public.order_counters (branch_id, business_date, last_seq)
  VALUES (_branch_id, CURRENT_DATE, 1)
  ON CONFLICT (branch_id, business_date)
  DO UPDATE SET last_seq = public.order_counters.last_seq + 1
  RETURNING last_seq INTO _seq;
  _number := to_char(CURRENT_DATE,'YYMMDD') || '-' || lpad(_seq::text, 4, '0');

  INSERT INTO public.orders (company_id, branch_id, shift_id, order_number, order_type, status,
    discount_amount, discount_reason, customer_name, customer_phone, notes, created_by, completed_at)
  VALUES (_company, _branch_id, _shift, _number, _order_type, 'completed',
    _discount, _reason,
    COALESCE(_customer_name, (SELECT name FROM public.customers WHERE id = _cust)),
    COALESCE(_customer_phone, (SELECT phone FROM public.customers WHERE id = _cust)),
    _notes, _profile, now())
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

    _unit_price := COALESCE(_override, _product.base_price) + COALESCE(_size.price_delta, 0);
    _unit_cost := COALESCE(_product.cost, 0);

    _mods_total := 0;
    _line := 0;
    INSERT INTO public.order_items (order_id, product_id, size_id, product_name, size_name,
      unit_price, modifiers_total, quantity, line_total, unit_cost, notes)
    VALUES (_order, _product.id, _size.id, _product.name, _size.name,
      _unit_price, 0, _qty, 0, _unit_cost, NULLIF(_item->>'notes',''))
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

    _line := (_unit_price + _mods_total) * _qty;
    UPDATE public.order_items SET modifiers_total = _mods_total, line_total = _line
    WHERE order_items.id = _item_id;

    _subtotal := _subtotal + _line;
    IF _product.is_taxable THEN _taxable_base := _taxable_base + _line; END IF;
  END LOOP;

  IF _discount > _subtotal THEN
    IF _voucher.id IS NOT NULL THEN
      _discount := _subtotal;
    ELSE
      RAISE EXCEPTION 'Discount exceeds order subtotal';
    END IF;
  END IF;

  IF _tax_enabled AND _subtotal > 0 THEN
    _tax := round(((_taxable_base - (_discount * (_taxable_base / _subtotal))) * _tax_rate / 100)::numeric, 2);
  END IF;
  _total := round((_subtotal - _discount + _tax)::numeric, 2);

  FOR _pay IN SELECT * FROM jsonb_array_elements(COALESCE(_payments,'[]'::jsonb)) LOOP
    _pay_amount := COALESCE((_pay->>'amount')::numeric, 0);
    IF _pay_amount <= 0 THEN RAISE EXCEPTION 'Payment amount must be greater than zero'; END IF;

    _pay_kind := NULL;
    SELECT pm.kind INTO _pay_kind FROM public.payment_methods pm
    WHERE pm.company_id = _company
      AND (pm.id = NULLIF(_pay->>'payment_method_id','')::uuid OR pm.key = _pay->>'method_key')
    LIMIT 1;

    _remaining := round(_total - _paid, 2);
    IF COALESCE(_pay_kind, _pay->>'method_key') = 'cash' AND _pay_amount > _remaining THEN
      _pay_amount := GREATEST(_remaining, 0);
    END IF;
    IF _pay_amount <= 0 THEN CONTINUE; END IF;

    INSERT INTO public.order_payments (order_id, payment_method_id, method_key, amount, reference,
      sender_number, receiver_number, created_by)
    VALUES (_order, NULLIF(_pay->>'payment_method_id','')::uuid, _pay->>'method_key',
      _pay_amount, NULLIF(_pay->>'reference',''), NULLIF(_pay->>'sender_number',''),
      NULLIF(_pay->>'receiver_number',''), _profile);
    _paid := _paid + _pay_amount;
  END LOOP;

  IF round(_paid,2) < _total THEN
    RAISE EXCEPTION 'Payments (%) are less than order total (%)', round(_paid,2), _total;
  END IF;

  UPDATE public.orders SET subtotal = _subtotal, tax_amount = _tax, total = _total,
    discount_amount = _discount, discount_reason = _reason
  WHERE orders.id = _order;

  IF _voucher.id IS NOT NULL THEN
    UPDATE public.customer_vouchers
    SET status = 'used', settlement = 'discount', order_id = _order,
        redeemed_at = now(), redeemed_by = _profile
    WHERE id = _voucher.id;
  END IF;

  IF _cust IS NOT NULL THEN
    _cfg := public.loyalty_config(_company);
    _rate := GREATEST(COALESCE((_cfg->>'currency_per_point')::numeric, 10), 0.01);
    IF COALESCE((_cfg->>'enabled')::boolean, true) THEN
      _points := floor(_total / _rate)::int;
    END IF;
    UPDATE public.customers
    SET points_balance = points_balance + _points,
        total_spent = total_spent + _total,
        visits = visits + 1,
        last_visit_at = now()
    WHERE id = _cust
    RETURNING points_balance INTO _balance;
    IF _points > 0 THEN
      INSERT INTO public.customer_points_transactions
        (company_id, customer_id, order_id, kind, points, balance_after, description, created_by)
      VALUES (_company, _cust, _order, 'earn', _points, _balance, _number, _profile);
    END IF;
  END IF;

  PERFORM public.log_audit('order.create','pos','orders',_order,NULL,
    jsonb_build_object('order_number',_number,'total',_total,'customer_id',_cust,'points',_points),NULL,_branch_id);

  RETURN QUERY SELECT _order, _number;
END $$;