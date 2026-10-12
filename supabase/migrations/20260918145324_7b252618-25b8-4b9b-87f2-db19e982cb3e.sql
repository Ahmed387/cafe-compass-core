REVOKE EXECUTE ON FUNCTION public.offers_enabled(uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.set_offers_enabled(boolean) FROM anon;
REVOKE EXECUTE ON FUNCTION public.offer_price_preview(jsonb) FROM anon;
REVOKE EXECUTE ON FUNCTION public.save_product_offer(jsonb) FROM anon;
REVOKE EXECUTE ON FUNCTION public.set_offer_active(uuid, boolean, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.offers_performance(date, date) FROM anon;

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

-- Public menu: offers-aware
CREATE OR REPLACE FUNCTION public.public_menu(_branch_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  _company_id uuid;
  _result jsonb;
  _on boolean;
BEGIN
  SELECT b.company_id INTO _company_id
  FROM public.branches b
  JOIN public.companies c ON c.id = b.company_id
  WHERE b.id = _branch_id AND b.is_active AND c.is_active;

  IF _company_id IS NULL THEN
    RETURN NULL;
  END IF;

  _on := public.offers_enabled(_company_id);

  SELECT jsonb_build_object(
    'company', (
      SELECT jsonb_build_object('name', c.name, 'logo_url', c.logo_url, 'currency', c.currency, 'default_language', c.default_language)
      FROM public.companies c WHERE c.id = _company_id
    ),
    'branch', (
      SELECT jsonb_build_object('id', b.id, 'name', b.name, 'address', b.address, 'phone', b.phone)
      FROM public.branches b WHERE b.id = _branch_id
    ),
    'offers_enabled', _on,
    'offers', CASE WHEN NOT _on THEN '[]'::jsonb ELSE COALESCE((
      SELECT jsonb_agg(off ORDER BY off->>'title')
      FROM (
        SELECT jsonb_build_object(
          'id', po.id,
          'title', po.title,
          'offer_type', po.offer_type,
          'offer_price', po.offer_price,
          'base_price', po.base_price_snapshot,
          'image_path', po.image_path,
          'double_points', po.double_points,
          'ends_at', po.ends_at,
          'product', CASE WHEN po.offer_type = 'single' THEN (
            SELECT jsonb_build_object('id', p.id, 'name', p.name, 'name_ar', p.name_ar, 'image_url', p.image_url)
            FROM public.products p WHERE p.id = po.product_id
          ) ELSE NULL END,
          'items', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                     'product_id', p2.id, 'name', p2.name, 'name_ar', p2.name_ar,
                     'image_url', p2.image_url, 'quantity', bi.quantity,
                     'base_price', p2.base_price)
                   ORDER BY p2.name)
            FROM public.offer_bundle_items bi
            JOIN public.products p2 ON p2.id = bi.product_id
            WHERE bi.offer_id = po.id
          ), '[]'::jsonb)
        ) AS off
        FROM public.product_offers po
        WHERE po.company_id = _company_id AND po.is_active
          AND po.starts_at <= CURRENT_DATE
          AND (po.ends_at IS NULL OR po.ends_at >= CURRENT_DATE)
          AND (
            po.offer_type = 'bundle'
            OR EXISTS (SELECT 1 FROM public.products p
                       WHERE p.id = po.product_id AND p.is_active AND p.is_available AND p.show_on_public_menu)
          )
      ) offs
    ), '[]'::jsonb) END,
    'categories', COALESCE((
      SELECT jsonb_agg(cat ORDER BY cat->>'display_order', cat->>'name')
      FROM (
        SELECT jsonb_build_object(
          'id', cg.id,
          'name', cg.name,
          'name_ar', cg.name_ar,
          'display_order', cg.display_order,
          'products', COALESCE((
            SELECT jsonb_agg(prod ORDER BY prod->>'display_order', prod->>'name')
            FROM (
              SELECT jsonb_build_object(
                'id', p.id,
                'name', p.name,
                'name_ar', p.name_ar,
                'description', p.description,
                'image_url', p.image_url,
                'display_order', p.display_order,
                'price', COALESCE(pbs.price_override, p.base_price),
                'offer_price', CASE WHEN _on THEN (
                  SELECT po.offer_price FROM public.product_offers po
                  WHERE po.company_id = _company_id AND po.product_id = p.id
                    AND po.offer_type = 'single' AND po.is_active
                    AND po.starts_at <= CURRENT_DATE
                    AND (po.ends_at IS NULL OR po.ends_at >= CURRENT_DATE)
                  ORDER BY po.offer_price ASC LIMIT 1
                ) ELSE NULL END,
                'sizes', COALESCE((
                  SELECT jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'name_ar', s.name_ar, 'price_delta', s.price_delta)
                                   ORDER BY s.display_order, s.name)
                  FROM public.product_sizes s
                  WHERE s.product_id = p.id AND s.is_active
                ), '[]'::jsonb)
              ) AS prod
              FROM public.products p
              LEFT JOIN public.product_branch_settings pbs
                ON pbs.product_id = p.id AND pbs.branch_id = _branch_id
              WHERE p.category_id = cg.id
                AND p.is_active AND p.is_available
                AND p.show_on_public_menu
                AND COALESCE(pbs.is_available, true)
                AND EXISTS (SELECT 1 FROM public.product_recipes pr WHERE pr.product_id = p.id)
            ) prods
          ), '[]'::jsonb)
        ) AS cat
        FROM public.categories cg
        WHERE cg.company_id = _company_id AND cg.is_active
      ) cats
      WHERE jsonb_array_length(cat->'products') > 0
    ), '[]'::jsonb)
  ) INTO _result;

  RETURN _result;
END;
$function$;