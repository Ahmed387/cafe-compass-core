-- ============ 1. KITCHEN PURGE ============
DROP TRIGGER IF EXISTS t_order_items_station ON public.order_items;
DROP TRIGGER IF EXISTS set_order_item_station ON public.order_items;
DROP FUNCTION IF EXISTS public.set_order_item_station() CASCADE;
DROP FUNCTION IF EXISTS public.set_kitchen_status(uuid, kitchen_status) CASCADE;
ALTER TABLE public.order_items DROP COLUMN IF EXISTS station_id;
ALTER TABLE public.products DROP COLUMN IF EXISTS station_id;
ALTER TABLE public.orders DROP COLUMN IF EXISTS kitchen_status;
ALTER TABLE public.orders DROP COLUMN IF EXISTS kitchen_ready_at;
ALTER TABLE public.orders DROP COLUMN IF EXISTS kitchen_served_at;
DROP TABLE IF EXISTS public.kitchen_stations CASCADE;
DELETE FROM public.role_permissions WHERE permission_id IN (SELECT id FROM public.permissions WHERE key LIKE 'kitchen.%');
DELETE FROM public.permissions WHERE key LIKE 'kitchen.%';
DROP TYPE IF EXISTS public.kitchen_status CASCADE;

-- ============ 2. PARTNER <-> CUSTOMER DUAL IDENTITY ============
ALTER TABLE public.partners
  ADD COLUMN IF NOT EXISTS customer_id uuid REFERENCES public.customers(id) ON DELETE SET NULL;

DO $$
DECLARE _p record; _cid uuid;
BEGIN
  FOR _p IN SELECT * FROM public.partners WHERE customer_id IS NULL LOOP
    SELECT id INTO _cid FROM public.customers
     WHERE company_id = _p.company_id
       AND (phone = COALESCE(NULLIF(btrim(_p.phone),''), '__none__')) LIMIT 1;
    IF _cid IS NULL THEN
      INSERT INTO public.customers (company_id, code, name, phone, barcode, notes)
      VALUES (_p.company_id,
        'C-' || lpad(nextval('public.customer_code_seq')::text, 5, '0'),
        _p.name,
        COALESCE(NULLIF(btrim(_p.phone),''), 'P-' || right(replace(_p.id::text,'-',''), 10)),
        upper(substring(replace(gen_random_uuid()::text,'-','') from 1 for 12)),
        'Partner account')
      RETURNING id INTO _cid;
    END IF;
    UPDATE public.partners SET customer_id = _cid WHERE id = _p.id;
  END LOOP;
END $$;

-- ============ 3. PARTNER TAB ORDERS ============
CREATE TABLE IF NOT EXISTS public.partner_tab_orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  branch_id uuid REFERENCES public.branches(id) ON DELETE SET NULL,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  partner_id uuid NOT NULL REFERENCES public.partners(id) ON DELETE RESTRICT,
  total_amount numeric(14,2) NOT NULL CHECK (total_amount >= 0),
  is_settled boolean NOT NULL DEFAULT false,
  settled_at timestamptz,
  distribution_id uuid REFERENCES public.profit_distributions(id) ON DELETE SET NULL,
  created_by uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (order_id)
);

GRANT SELECT ON public.partner_tab_orders TO authenticated;
GRANT ALL ON public.partner_tab_orders TO service_role;

ALTER TABLE public.partner_tab_orders ENABLE ROW LEVEL SECURITY;

CREATE POLICY "partner_tab_orders_read" ON public.partner_tab_orders
  FOR SELECT TO authenticated
  USING (
    company_id = public.current_company_id()
    AND (
      public.is_super_admin()
      OR public.has_permission('partners.view')
      OR partner_id = public.current_partner_id()
    )
  );

CREATE TRIGGER partner_tab_orders_updated_at
  BEFORE UPDATE ON public.partner_tab_orders
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER partner_tab_orders_no_delete
  BEFORE DELETE ON public.partner_tab_orders
  FOR EACH ROW EXECUTE FUNCTION public.forbid_hard_delete();

CREATE INDEX IF NOT EXISTS idx_partner_tab_orders_partner ON public.partner_tab_orders (partner_id, is_settled);

-- ============ 4. create_pos_order: partner tab support ============
CREATE OR REPLACE FUNCTION public.create_pos_order(
  _branch_id uuid, _items jsonb, _payments jsonb,
  _order_type order_type DEFAULT 'takeaway'::order_type,
  _discount_amount numeric DEFAULT 0, _discount_reason text DEFAULT NULL::text,
  _customer_name text DEFAULT NULL::text, _customer_phone text DEFAULT NULL::text,
  _notes text DEFAULT NULL::text, _customer_id uuid DEFAULT NULL::uuid,
  _voucher_code text DEFAULT NULL::text,
  _partner_id uuid DEFAULT NULL::uuid, _on_partner_tab boolean DEFAULT false)
 RETURNS TABLE(out_id uuid, out_number text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
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
  _override numeric; _unit_price numeric; _unit_cost numeric; _qty int;
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

  -- Partner tab orders are charged at full menu price: no discounts, no vouchers, no points payment.
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

    _unit_price := COALESCE(_override, _product.base_price) + COALESCE(_size.price_delta, 0);
    _unit_cost := COALESCE(_product.cost, 0);

    -- Partner tab orders are always billed at full menu retail price (no promotional offers).
    _offer := NULL;
    IF NOT _tab THEN
      SELECT po.* INTO _offer FROM public.product_offers po
      WHERE po.company_id = _company AND po.product_id = _product.id AND po.is_active
        AND po.starts_at <= CURRENT_DATE
        AND (po.ends_at IS NULL OR po.ends_at >= CURRENT_DATE)
      ORDER BY po.offer_price ASC LIMIT 1;
      IF _offer.id IS NOT NULL AND _offer.offer_price < _unit_price THEN
        _offer_savings := _offer_savings + round((_unit_price - _offer.offer_price) * _qty, 2);
        IF position(_offer.title in _offer_titles) = 0 THEN
          _offer_titles := CASE WHEN _offer_titles = '' THEN _offer.title
                                ELSE _offer_titles || ', ' || _offer.title END;
        END IF;
        _unit_price := _offer.offer_price;
      END IF;
    END IF;

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
    discount_amount = _discount, discount_reason = _reason
  WHERE orders.id = _order;

  _cfg := public.loyalty_config(_company);
  _point_value := GREATEST(COALESCE((_cfg->>'point_value')::numeric, 1), 0.01);

  FOR _pay IN SELECT * FROM jsonb_array_elements(COALESCE(_payments,'[]'::jsonb)) LOOP
    _pay_amount := COALESCE((_pay->>'amount')::numeric, 0);
    _remaining := round(_total - _paid, 2);

    IF _pay->>'method_key' = 'points' THEN
      IF _cust IS NULL THEN RAISE EXCEPTION 'Points payment requires a customer'; END IF;
      _pay_points := COALESCE(NULLIF(_pay->>'points','')::int, floor(_pay_amount / _point_value)::int);
      IF _pay_points <= 0 THEN CONTINUE; END IF;

      SELECT COALESCE(points_balance,0) INTO _avail FROM public.customers
      WHERE id = _cust AND company_id = _company FOR UPDATE;
      IF _avail IS NULL THEN RAISE EXCEPTION 'Customer not found'; END IF;
      IF _redeem_points + _pay_points > _avail THEN
        RAISE EXCEPTION 'Customer does not have enough points (% available)', _avail;
      END IF;

      _pay_amount := round(_pay_points * _point_value, 2);
      IF _pay_amount > _remaining THEN
        _pay_points := floor(_remaining / _point_value)::int;
        _pay_amount := round(_pay_points * _point_value, 2);
      END IF;
      IF _pay_points <= 0 OR _pay_amount <= 0 THEN CONTINUE; END IF;

      INSERT INTO public.order_payments (order_id, payment_method_id, method_key, amount, reference, created_by)
      VALUES (_order, NULL, 'points', _pay_amount, _pay_points::text || ' pts', _profile);
      _redeem_points := _redeem_points + _pay_points;
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

  -- Cash invariance: a partner tab order settles against future dividends, never the drawer.
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
    _rate := GREATEST(COALESCE((_cfg->>'currency_per_point')::numeric, 10), 0.01);
    IF COALESCE((_cfg->>'enabled')::boolean, true) THEN
      _points := floor(_total / _rate)::int;
      IF _double_value > 0 THEN _points := _points + floor(_double_value / _rate)::int; END IF;
    END IF;

    SELECT COALESCE(points_balance,0) INTO _balance_before FROM public.customers WHERE id = _cust FOR UPDATE;

    UPDATE public.customers
    SET points_balance = COALESCE(points_balance,0) + _points - _redeem_points,
        total_spent = COALESCE(total_spent,0) + _total,
        visits = COALESCE(visits,0) + 1,
        last_visit_at = now()
    WHERE id = _cust
    RETURNING points_balance INTO _balance;

    IF _redeem_points > 0 THEN
      INSERT INTO public.customer_points_transactions
        (company_id, customer_id, order_id, kind, points, balance_after, description, created_by)
      VALUES (_company, _cust, _order, 'redeem', -_redeem_points, _balance_before - _redeem_points,
        'سداد بالنقاط على فاتورة #' || _number, _profile);
    END IF;

    IF _points > 0 THEN
      INSERT INTO public.customer_points_transactions
        (company_id, customer_id, order_id, kind, points, balance_after, description, created_by)
      VALUES (_company, _cust, _order, 'earn', _points, _balance,
        'نقاط مكتسبة من فاتورة #' || _number, _profile);
    END IF;
  END IF;

  PERFORM public.log_audit('order.create','pos','orders',_order,NULL,
    jsonb_build_object('order_number',_number,'total',_total,'customer_id',_cust,
      'points',_points,'points_redeemed',_redeem_points,'offer_savings',_offer_savings,
      'offers',_offer_titles,'partner_tab',_tab),NULL,_branch_id);

  RETURN QUERY SELECT _order, _number;
END $function$;

-- ============ 5. distribute_period_profit: net of partner tab ============
CREATE OR REPLACE FUNCTION public.distribute_period_profit(_period_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _p public.accounting_periods; _profile uuid := public.current_profile_id();
  _net numeric; _currency text; _dist uuid; _capital numeric; _r record; _txn uuid;
  _pct numeric; _amount numeric; _tab numeric; _deduct numeric;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('partners.manage_profit_distribution') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  SELECT * INTO _p FROM public.accounting_periods WHERE id = _period_id AND company_id = public.current_company_id();
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Period not found'; END IF;
  IF _p.status <> 'closed' THEN RAISE EXCEPTION 'Close the accounting period before distributing profit'; END IF;
  IF EXISTS (SELECT 1 FROM public.profit_distributions d WHERE d.period_id = _period_id AND d.status = 'active') THEN
    RAISE EXCEPTION 'Profit for this period has already been distributed';
  END IF;

  _net := (public.period_distribution(_period_id)->>'distributable')::numeric;
  IF _net IS NULL OR _net <= 0 THEN RAISE EXCEPTION 'There is no distributable profit for this period'; END IF;

  SELECT currency INTO _currency FROM public.companies WHERE id = _p.company_id;

  SELECT COALESCE(SUM(cc.amount),0) INTO _capital
  FROM public.partner_capital_contributions cc
  JOIN public.partners pa ON pa.id = cc.partner_id
  WHERE cc.company_id = _p.company_id AND cc.status = 'active' AND pa.status = 'active';
  IF _capital <= 0 THEN RAISE EXCEPTION 'Partner capital contributions are required before distributing profit'; END IF;

  INSERT INTO public.profit_distributions (company_id, period_id, net_profit, currency, status, distributed_at, created_by)
  VALUES (_p.company_id, _period_id, _net, _currency, 'active', now(), _profile)
  RETURNING id INTO _dist;

  FOR _r IN
    SELECT pa.id AS partner_id, COALESCE(SUM(cc.amount),0) AS capital
    FROM public.partners pa
    LEFT JOIN public.partner_capital_contributions cc ON cc.partner_id = pa.id AND cc.status = 'active'
    WHERE pa.company_id = _p.company_id AND pa.status = 'active'
    GROUP BY pa.id
    HAVING COALESCE(SUM(cc.amount),0) > 0
  LOOP
    _pct := round((_r.capital / _capital) * 100, 4);
    _amount := round(_net * (_r.capital / _capital), 2);

    INSERT INTO public.partner_ledger_transactions (company_id, partner_id, transaction_type, amount, currency,
      reference_type, reference_id, description, transaction_date, status, created_by)
    VALUES (_p.company_id, _r.partner_id, 'profit_distribution', _amount, _currency,
      'profit_distribution', _dist, 'Profit distribution', _p.end_date, 'active', _profile)
    RETURNING id INTO _txn;

    INSERT INTO public.profit_distribution_lines (distribution_id, partner_id, ownership_percentage, amount, ledger_transaction_id)
    VALUES (_dist, _r.partner_id, _pct, _amount, _txn);

    -- Pending partner tab orders are deducted from the dividend, never from the drawer.
    SELECT COALESCE(SUM(t.total_amount),0) INTO _tab
    FROM public.partner_tab_orders t
    WHERE t.partner_id = _r.partner_id AND NOT t.is_settled
      AND t.created_at::date <= _p.end_date;

    _deduct := LEAST(_tab, _amount);
    IF _deduct > 0 THEN
      INSERT INTO public.partner_ledger_transactions (company_id, partner_id, transaction_type, amount, currency,
        reference_type, reference_id, description, transaction_date, status, created_by)
      VALUES (_p.company_id, _r.partner_id, 'adjustment', -_deduct, _currency,
        'partner_tab', _dist, 'خصم فواتير على الحساب', _p.end_date, 'active', _profile);

      UPDATE public.partner_tab_orders
      SET is_settled = true, settled_at = now(), distribution_id = _dist
      WHERE partner_id = _r.partner_id AND NOT is_settled
        AND created_at::date <= _p.end_date;

      PERFORM public.log_audit('partner_tab.settle','partners','partner_tab_orders',_dist,NULL,
        jsonb_build_object('partner_id',_r.partner_id,'deducted',_deduct,'dividend',_amount),NULL,NULL);
    END IF;
  END LOOP;

  PERFORM public.log_audit('finance.distribute_profit','partners','profit_distributions',_dist,NULL,
    jsonb_build_object('net_profit',_net,'period_id',_period_id),NULL,NULL);
  RETURN _dist;
END $function$;