-- 1) Cash payments: never record more than the amount due (change goes back to customer)
CREATE OR REPLACE FUNCTION public.create_pos_order(_branch_id uuid, _items jsonb, _payments jsonb, _order_type order_type DEFAULT 'takeaway'::order_type, _discount_amount numeric DEFAULT 0, _discount_reason text DEFAULT NULL::text, _customer_name text DEFAULT NULL::text, _customer_phone text DEFAULT NULL::text, _notes text DEFAULT NULL::text)
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
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('pos.create_order') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF NOT public.can_access_branch(_branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _items IS NULL OR jsonb_array_length(_items) = 0 THEN RAISE EXCEPTION 'Order has no items'; END IF;
  IF _discount_amount IS NOT NULL AND _discount_amount > 0
     AND NOT (public.has_permission('pos.apply_discount') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized to apply discounts';
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
    COALESCE(_discount_amount,0), _discount_reason, _customer_name, _customer_phone, _notes, _profile, now())
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

  IF COALESCE(_discount_amount,0) > _subtotal THEN RAISE EXCEPTION 'Discount exceeds order subtotal'; END IF;

  IF _tax_enabled AND _subtotal > 0 THEN
    _tax := round(((_taxable_base - (COALESCE(_discount_amount,0) * (_taxable_base / _subtotal))) * _tax_rate / 100)::numeric, 2);
  END IF;
  _total := round((_subtotal - COALESCE(_discount_amount,0) + _tax)::numeric, 2);

  FOR _pay IN SELECT * FROM jsonb_array_elements(COALESCE(_payments,'[]'::jsonb)) LOOP
    _pay_amount := COALESCE((_pay->>'amount')::numeric, 0);
    IF _pay_amount <= 0 THEN RAISE EXCEPTION 'Payment amount must be greater than zero'; END IF;

    _pay_kind := NULL;
    SELECT pm.kind INTO _pay_kind FROM public.payment_methods pm
    WHERE pm.company_id = _company
      AND (pm.id = NULLIF(_pay->>'payment_method_id','')::uuid OR pm.key = _pay->>'method_key')
    LIMIT 1;

    _remaining := round(_total - _paid, 2);
    -- Cash tendered above the amount due is change handed back, not revenue.
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

  UPDATE public.orders SET subtotal = _subtotal, tax_amount = _tax, total = _total WHERE orders.id = _order;
  PERFORM public.log_audit('order.create','pos','orders',_order,NULL,
    jsonb_build_object('order_number',_number,'total',_total),NULL,_branch_id);

  RETURN QUERY SELECT _order, _number;
END $function$;

-- 2) Only one open shift per branch (drawer accountability)
CREATE OR REPLACE FUNCTION public.open_shift(_branch_id uuid, _opening_cash numeric DEFAULT 0)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _profile uuid := public.current_profile_id(); _company uuid := public.current_company_id(); _id uuid; _other uuid;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('shifts.open') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF NOT public.can_access_branch(_branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF EXISTS (SELECT 1 FROM public.shifts WHERE branch_id = _branch_id AND user_id = _profile AND status = 'open') THEN
    RAISE EXCEPTION 'You already have an open shift';
  END IF;
  SELECT s.user_id INTO _other FROM public.shifts s
  WHERE s.branch_id = _branch_id AND s.status = 'open' LIMIT 1;
  IF _other IS NOT NULL THEN
    RAISE EXCEPTION 'Another shift is already open on this branch and must be closed first';
  END IF;
  INSERT INTO public.shifts (company_id, branch_id, user_id, opening_cash)
  VALUES (_company, _branch_id, _profile, COALESCE(_opening_cash, 0)) RETURNING id INTO _id;
  PERFORM public.log_audit('shift.open','pos','shifts',_id,NULL,jsonb_build_object('opening_cash',_opening_cash),NULL,_branch_id);
  RETURN _id;
END $function$;

CREATE UNIQUE INDEX IF NOT EXISTS shifts_one_open_per_branch
  ON public.shifts (branch_id) WHERE status = 'open';

-- 3) Capital contributions always post to the partner ledger
CREATE OR REPLACE FUNCTION public.sync_capital_contribution_ledger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.status = 'active' AND NOT EXISTS (
    SELECT 1 FROM public.partner_ledger_transactions t
    WHERE t.reference_type = 'partner_capital_contributions' AND t.reference_id = NEW.id
  ) THEN
    INSERT INTO public.partner_ledger_transactions
      (company_id, partner_id, transaction_type, amount, currency, reference_type, reference_id,
       description, transaction_date, created_by)
    VALUES (NEW.company_id, NEW.partner_id, 'capital_contribution', NEW.amount, NEW.currency,
      'partner_capital_contributions', NEW.id, NEW.notes, NEW.contribution_date, NEW.created_by);
  END IF;
  RETURN NEW;
END $function$;

DROP TRIGGER IF EXISTS t_capital_contribution_ledger ON public.partner_capital_contributions;
CREATE TRIGGER t_capital_contribution_ledger
AFTER INSERT ON public.partner_capital_contributions
FOR EACH ROW EXECUTE FUNCTION public.sync_capital_contribution_ledger();

-- Backfill missing ledger rows for existing contributions
INSERT INTO public.partner_ledger_transactions
  (company_id, partner_id, transaction_type, amount, currency, reference_type, reference_id,
   description, transaction_date, created_by)
SELECT c.company_id, c.partner_id, 'capital_contribution', c.amount, c.currency,
  'partner_capital_contributions', c.id, c.notes, c.contribution_date, c.created_by
FROM public.partner_capital_contributions c
WHERE c.status = 'active'
  AND NOT EXISTS (
    SELECT 1 FROM public.partner_ledger_transactions t
    WHERE t.reference_type = 'partner_capital_contributions' AND t.reference_id = c.id
  );

-- 4) Cost visibility permission
INSERT INTO public.permissions (key, name, description, module)
VALUES ('products.view_cost', 'View product cost', 'See product cost and margin figures', 'products')
ON CONFLICT (key) DO NOTHING;

INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM public.roles r
JOIN public.permissions p ON p.key = 'products.view_cost'
WHERE r.key IN ('super_admin','owner','manager','accountant')
ON CONFLICT DO NOTHING;
