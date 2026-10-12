ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS is_soft_opening boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.create_soft_opening_order(
  _branch_id uuid,
  _items jsonb,
  _method_key text DEFAULT 'cash',
  _tendered numeric DEFAULT NULL,
  _notes text DEFAULT NULL
) RETURNS TABLE(out_id uuid, out_number text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  _profile uuid := public.current_profile_id();
  _company uuid := public.current_company_id();
  _shift uuid; _order uuid; _number text; _seq int;
  _item jsonb; _qty int; _price numeric; _name text; _line numeric;
  _total numeric := 0;
  _key text := COALESCE(NULLIF(btrim(_method_key), ''), 'cash');
  _pm uuid;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('pos.create_order') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF NOT public.can_access_branch(_branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _items IS NULL OR jsonb_array_length(_items) = 0 THEN RAISE EXCEPTION 'Order has no items'; END IF;

  SELECT s.id INTO _shift FROM public.shifts s
  WHERE s.branch_id = _branch_id AND s.user_id = _profile AND s.status = 'open' LIMIT 1;
  IF _shift IS NULL THEN RAISE EXCEPTION 'No open shift'; END IF;

  INSERT INTO public.order_counters (branch_id, business_date, last_seq)
  VALUES (_branch_id, CURRENT_DATE, 1)
  ON CONFLICT (branch_id, business_date)
  DO UPDATE SET last_seq = public.order_counters.last_seq + 1
  RETURNING last_seq INTO _seq;
  _number := 'SO-' || to_char(CURRENT_DATE,'YYMMDD') || '-' || lpad(_seq::text, 4, '0');

  INSERT INTO public.orders (company_id, branch_id, shift_id, order_number, order_type, status,
    subtotal, discount_amount, tax_amount, total, notes, created_by, completed_at, is_soft_opening)
  VALUES (_company, _branch_id, _shift, _number, 'takeaway', 'completed',
    0, 0, 0, 0, _notes, _profile, now(), true)
  RETURNING orders.id INTO _order;

  FOR _item IN SELECT * FROM jsonb_array_elements(_items) LOOP
    _name := NULLIF(btrim(COALESCE(_item->>'name','')), '');
    _qty := COALESCE((_item->>'quantity')::int, 0);
    _price := round(COALESCE((_item->>'unit_price')::numeric, 0), 2);
    IF _name IS NULL THEN RAISE EXCEPTION 'اسم الصنف مطلوب'; END IF;
    IF _qty <= 0 THEN RAISE EXCEPTION 'الكمية يجب أن تكون أكبر من صفر'; END IF;
    IF _price < 0 THEN RAISE EXCEPTION 'سعر الوحدة غير صحيح'; END IF;
    _line := round(_price * _qty, 2);
    _total := _total + _line;

    INSERT INTO public.order_items (order_id, product_id, size_id, product_name, size_name,
      unit_price, base_price, modifiers_total, quantity, line_total, unit_cost, status)
    VALUES (_order, NULL, NULL, _name, NULL, _price, _price, 0, _qty, _line, 0, 'active');
  END LOOP;

  IF _total <= 0 THEN RAISE EXCEPTION 'إجمالي الفاتورة يجب أن يكون أكبر من صفر'; END IF;

  UPDATE public.orders SET subtotal = _total, total = _total WHERE orders.id = _order;

  SELECT pm.id INTO _pm FROM public.payment_methods pm
  WHERE pm.company_id = _company AND pm.key = _key LIMIT 1;

  INSERT INTO public.order_payments (order_id, payment_method_id, method_key, amount, created_by)
  VALUES (_order, _pm, _key, _total, _profile);

  PERFORM public.log_audit('SOFT_OPENING_SALE','pos','orders',_order,NULL,
    jsonb_build_object('order_id', _order, 'order_number', _number, 'total_amount', _total,
      'cashier_id', _profile, 'method_key', _key,
      'tendered', _tendered, 'items', jsonb_array_length(_items)),
    NULL, _branch_id);

  RETURN QUERY SELECT _order, _number;
END $function$;

REVOKE ALL ON FUNCTION public.create_soft_opening_order(uuid, jsonb, text, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_soft_opening_order(uuid, jsonb, text, numeric, text) TO authenticated, service_role;