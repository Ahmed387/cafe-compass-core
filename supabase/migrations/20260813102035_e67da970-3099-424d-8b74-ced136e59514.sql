DROP FUNCTION IF EXISTS public.create_pos_order(uuid, jsonb, jsonb, public.order_type, numeric, text, text, text, text);

CREATE OR REPLACE FUNCTION public.create_pos_order(
  _branch_id uuid,
  _items jsonb,
  _payments jsonb,
  _order_type public.order_type DEFAULT 'takeaway',
  _discount_amount numeric DEFAULT 0,
  _discount_reason text DEFAULT NULL,
  _customer_name text DEFAULT NULL,
  _customer_phone text DEFAULT NULL,
  _notes text DEFAULT NULL
) RETURNS TABLE (out_id uuid, out_number text) LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
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
  _item jsonb; _pay jsonb;
  _item_id uuid; _mod jsonb; _mods_total numeric; _line numeric;
  _taxable_base numeric := 0;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('pos.create_order') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF NOT public.can_access_branch(_branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _items IS NULL OR jsonb_array_length(_items) = 0 THEN RAISE EXCEPTION 'Order has no items'; END IF;
  IF _discount_amount IS NOT NULL AND _discount_amount > 0
     AND NOT (public.has_permission('pos.apply_discount') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized to apply discounts';
  END IF;

  SELECT s.id INTO _shift FROM public.shifts s
  WHERE s.branch_id = _branch_id AND s.user_id = _profile AND s.status = 'open' LIMIT 1;
  IF _shift IS NULL THEN RAISE EXCEPTION 'No open shift'; END IF;

  SELECT c.tax_enabled, c.tax_rate INTO _tax_enabled, _tax_rate FROM public.companies c WHERE c.id = _company;

  SELECT COALESCE(MAX((regexp_replace(o.order_number,'^.*-',''))::int),0) + 1 INTO _seq
  FROM public.orders o
  WHERE o.branch_id = _branch_id AND o.created_at::date = CURRENT_DATE;
  _number := to_char(CURRENT_DATE,'YYMMDD') || '-' || lpad(_seq::text, 4, '0');

  INSERT INTO public.orders (company_id, branch_id, shift_id, order_number, order_type, status,
    discount_amount, discount_reason, customer_name, customer_phone, notes, created_by, completed_at)
  VALUES (_company, _branch_id, _shift, _number, _order_type, 'completed',
    COALESCE(_discount_amount,0), _discount_reason, _customer_name, _customer_phone, _notes, _profile, now())
  RETURNING orders.id INTO _order;

  FOR _item IN SELECT * FROM jsonb_array_elements(_items) LOOP
    _mods_total := 0;
    IF _item ? 'modifiers' THEN
      SELECT COALESCE(SUM((m->>'price_delta')::numeric),0) INTO _mods_total
      FROM jsonb_array_elements(_item->'modifiers') m;
    END IF;
    _line := ((_item->>'unit_price')::numeric + _mods_total) * (_item->>'quantity')::int;
    INSERT INTO public.order_items (order_id, product_id, size_id, product_name, size_name,
      unit_price, modifiers_total, quantity, line_total, unit_cost, notes)
    VALUES (_order, NULLIF(_item->>'product_id','')::uuid, NULLIF(_item->>'size_id','')::uuid,
      _item->>'product_name', NULLIF(_item->>'size_name',''), (_item->>'unit_price')::numeric,
      _mods_total, (_item->>'quantity')::int, _line,
      COALESCE((_item->>'unit_cost')::numeric,0), NULLIF(_item->>'notes',''))
    RETURNING order_items.id INTO _item_id;

    IF _item ? 'modifiers' THEN
      FOR _mod IN SELECT * FROM jsonb_array_elements(_item->'modifiers') LOOP
        INSERT INTO public.order_item_modifiers (order_item_id, option_id, name, price_delta)
        VALUES (_item_id, NULLIF(_mod->>'option_id','')::uuid, _mod->>'name',
                COALESCE((_mod->>'price_delta')::numeric,0));
      END LOOP;
    END IF;

    _subtotal := _subtotal + _line;
    IF COALESCE((_item->>'is_taxable')::boolean, true) THEN _taxable_base := _taxable_base + _line; END IF;
  END LOOP;

  IF COALESCE(_discount_amount,0) > _subtotal THEN RAISE EXCEPTION 'Discount exceeds order subtotal'; END IF;

  IF _tax_enabled AND _subtotal > 0 THEN
    _tax := round(((_taxable_base - (COALESCE(_discount_amount,0) * (_taxable_base / _subtotal))) * _tax_rate / 100)::numeric, 2);
  END IF;
  _total := round((_subtotal - COALESCE(_discount_amount,0) + _tax)::numeric, 2);

  FOR _pay IN SELECT * FROM jsonb_array_elements(COALESCE(_payments,'[]'::jsonb)) LOOP
    INSERT INTO public.order_payments (order_id, payment_method_id, method_key, amount, reference,
      sender_number, receiver_number, created_by)
    VALUES (_order, NULLIF(_pay->>'payment_method_id','')::uuid, _pay->>'method_key',
      (_pay->>'amount')::numeric, NULLIF(_pay->>'reference',''), NULLIF(_pay->>'sender_number',''),
      NULLIF(_pay->>'receiver_number',''), _profile);
    _paid := _paid + (_pay->>'amount')::numeric;
  END LOOP;

  IF round(_paid,2) < _total THEN
    RAISE EXCEPTION 'Payments (%) are less than order total (%)', round(_paid,2), _total;
  END IF;

  UPDATE public.orders SET subtotal = _subtotal, tax_amount = _tax, total = _total WHERE orders.id = _order;
  PERFORM public.log_audit('order.create','pos','orders',_order,NULL,
    jsonb_build_object('order_number',_number,'total',_total),NULL,_branch_id);

  RETURN QUERY SELECT _order, _number;
END $$;