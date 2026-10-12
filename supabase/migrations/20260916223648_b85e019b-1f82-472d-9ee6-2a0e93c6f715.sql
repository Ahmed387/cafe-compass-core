ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS customer_id uuid REFERENCES public.customers(id);
CREATE INDEX IF NOT EXISTS orders_customer_idx ON public.orders(customer_id, created_at DESC);

INSERT INTO public.app_settings (company_id, scope, key, value)
SELECT c.id, 'company', 'loyalty',
  jsonb_build_object('enabled', true, 'currency_per_point', 10, 'point_value', 1)
FROM public.companies c
WHERE NOT EXISTS (
  SELECT 1 FROM public.app_settings s WHERE s.company_id = c.id AND s.key = 'loyalty'
);

CREATE OR REPLACE FUNCTION public.create_pos_order(_branch_id uuid, _items jsonb, _payments jsonb, _order_type order_type DEFAULT 'takeaway'::order_type, _discount_amount numeric DEFAULT 0, _discount_reason text DEFAULT NULL::text, _customer_name text DEFAULT NULL::text, _customer_phone text DEFAULT NULL::text, _notes text DEFAULT NULL::text, _customer_id uuid DEFAULT NULL::uuid, _voucher_code text DEFAULT NULL::text)
 RETURNS TABLE(out_id uuid, out_number text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  -- Auto-create / attach the walk-in customer when a name + phone were typed at the POS.
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

  INSERT INTO public.orders (company_id, branch_id, shift_id, order_number, order_type, status,
    discount_amount, discount_reason, customer_id, customer_name, customer_phone, notes, created_by, completed_at)
  VALUES (_company, _branch_id, _shift, _number, _order_type, 'completed',
    0, _reason, _cust,
    COALESCE(NULLIF(btrim(COALESCE(_customer_name,'')),''), (SELECT name FROM public.customers WHERE id = _cust)),
    COALESCE(NULLIF(btrim(COALESCE(_customer_phone,'')),''), (SELECT phone FROM public.customers WHERE id = _cust)),
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

  UPDATE public.orders SET subtotal = _subtotal, tax_amount = _tax, total = _total,
    discount_amount = _discount, discount_reason = _reason
  WHERE orders.id = _order;

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
    SET points_balance = COALESCE(points_balance,0) + _points,
        total_spent = COALESCE(total_spent,0) + _total,
        visits = COALESCE(visits,0) + 1,
        last_visit_at = now()
    WHERE id = _cust
    RETURNING points_balance INTO _balance;
    IF _points > 0 THEN
      INSERT INTO public.customer_points_transactions
        (company_id, customer_id, order_id, kind, points, balance_after, description, created_by)
      VALUES (_company, _cust, _order, 'earn', _points, _balance,
        'نقاط مكتسبة من فاتورة #' || _number, _profile);
    END IF;
  END IF;

  PERFORM public.log_audit('order.create','pos','orders',_order,NULL,
    jsonb_build_object('order_number',_number,'total',_total,'customer_id',_cust,'points',_points),NULL,_branch_id);

  RETURN QUERY SELECT _order, _number;
END $function$;