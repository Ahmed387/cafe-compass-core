-- 1) Lock down direct writes: all mutations go through SECURITY DEFINER RPCs
DROP POLICY IF EXISTS orders_insert ON public.orders;
DROP POLICY IF EXISTS orders_update ON public.orders;
DROP POLICY IF EXISTS order_items_insert ON public.order_items;
DROP POLICY IF EXISTS order_items_update ON public.order_items;
DROP POLICY IF EXISTS order_payments_insert ON public.order_payments;
DROP POLICY IF EXISTS oim_insert ON public.order_item_modifiers;
DROP POLICY IF EXISTS shifts_insert ON public.shifts;
DROP POLICY IF EXISTS shifts_update ON public.shifts;
DROP POLICY IF EXISTS audit_insert ON public.audit_logs;
DROP POLICY IF EXISTS notif_insert ON public.notifications;

REVOKE INSERT, UPDATE ON public.orders FROM authenticated;
REVOKE INSERT, UPDATE ON public.order_items FROM authenticated;
REVOKE INSERT, UPDATE ON public.order_payments FROM authenticated;
REVOKE INSERT, UPDATE ON public.order_item_modifiers FROM authenticated;
REVOKE INSERT, UPDATE ON public.shifts FROM authenticated;
REVOKE INSERT, UPDATE ON public.audit_logs FROM authenticated;
REVOKE INSERT ON public.notifications FROM authenticated;

-- 2) profit_distribution_lines UPDATE must stay inside the company
DROP POLICY IF EXISTS pdl_update ON public.profit_distribution_lines;
CREATE POLICY pdl_update ON public.profit_distribution_lines FOR UPDATE TO authenticated
USING (
  public.has_permission('partners.manage_profit_distribution')
  AND EXISTS (SELECT 1 FROM public.profit_distributions d
              WHERE d.id = distribution_id AND d.company_id = public.current_company_id())
)
WITH CHECK (
  EXISTS (SELECT 1 FROM public.profit_distributions d
          WHERE d.id = distribution_id AND d.company_id = public.current_company_id())
);

-- 3) Self profile updates cannot escalate: block sensitive columns
CREATE OR REPLACE FUNCTION public.guard_profile_self_update()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF public.is_super_admin() OR public.has_permission('users.update') THEN
    RETURN NEW;
  END IF;
  IF NEW.company_id IS DISTINCT FROM OLD.company_id
     OR NEW.auth_user_id IS DISTINCT FROM OLD.auth_user_id
     OR NEW.is_active IS DISTINCT FROM OLD.is_active
     OR NEW.email IS DISTINCT FROM OLD.email
     OR NEW.employee_code IS DISTINCT FROM OLD.employee_code THEN
    RAISE EXCEPTION 'You cannot change these profile fields';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS t_profiles_guard_self ON public.user_profiles;
CREATE TRIGGER t_profiles_guard_self BEFORE UPDATE ON public.user_profiles
FOR EACH ROW EXECUTE FUNCTION public.guard_profile_self_update();

-- 4) Closed shifts are immutable
CREATE OR REPLACE FUNCTION public.protect_closed_shift()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF OLD.status = 'closed' AND NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Closed shifts cannot be modified';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS t_shifts_protect_closed ON public.shifts;
CREATE TRIGGER t_shifts_protect_closed BEFORE UPDATE ON public.shifts
FOR EACH ROW EXECUTE FUNCTION public.protect_closed_shift();

-- 5) Race-free per-branch daily order numbering
CREATE TABLE IF NOT EXISTS public.order_counters (
  branch_id uuid NOT NULL REFERENCES public.branches(id),
  business_date date NOT NULL,
  last_seq integer NOT NULL DEFAULT 0,
  PRIMARY KEY (branch_id, business_date)
);
GRANT ALL ON public.order_counters TO service_role;
ALTER TABLE public.order_counters ENABLE ROW LEVEL SECURITY;
-- No policies: internal use by SECURITY DEFINER functions only.

-- 6) Trustworthy pricing: prices, modifier deltas, cost and tax come from the DB
CREATE OR REPLACE FUNCTION public.create_pos_order(
  _branch_id uuid, _items jsonb, _payments jsonb,
  _order_type order_type DEFAULT 'takeaway'::order_type,
  _discount_amount numeric DEFAULT 0, _discount_reason text DEFAULT NULL,
  _customer_name text DEFAULT NULL, _customer_phone text DEFAULT NULL, _notes text DEFAULT NULL)
RETURNS TABLE(out_id uuid, out_number text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $function$
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
    IF COALESCE((_pay->>'amount')::numeric, 0) <= 0 THEN RAISE EXCEPTION 'Payment amount must be greater than zero'; END IF;
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
END $function$;

-- 7) Shift closing limited to the owner or an authorized manager
CREATE OR REPLACE FUNCTION public.close_shift(_shift_id uuid, _closing_cash numeric, _notes text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $function$
DECLARE _s public.shifts; _expected numeric; _profile uuid := public.current_profile_id();
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO _s FROM public.shifts WHERE id = _shift_id;
  IF _s.id IS NULL THEN RAISE EXCEPTION 'Shift not found'; END IF;
  IF _s.status = 'closed' THEN RAISE EXCEPTION 'Shift already closed'; END IF;
  IF NOT (public.has_permission('shifts.close') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF _s.user_id <> _profile
     AND NOT (public.has_permission('shifts.adjust_cash') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'You can only close your own shift';
  END IF;
  IF NOT public.can_access_branch(_s.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _closing_cash IS NULL OR _closing_cash < 0 THEN RAISE EXCEPTION 'Closing cash is required'; END IF;

  SELECT _s.opening_cash + COALESCE(SUM(p.amount),0) INTO _expected
  FROM public.orders o JOIN public.order_payments p ON p.order_id = o.id
  WHERE o.shift_id = _shift_id AND o.status <> 'cancelled' AND p.method_key = 'cash';

  UPDATE public.shifts SET status = 'closed', closing_cash = _closing_cash, expected_cash = _expected,
    variance = COALESCE(_closing_cash,0) - _expected, notes = _notes, closed_at = now(), closed_by = _profile
  WHERE id = _shift_id;
  PERFORM public.log_audit('shift.close','pos','shifts',_shift_id,NULL,
    jsonb_build_object('closing_cash',_closing_cash,'expected_cash',_expected),_notes,_s.branch_id);
  RETURN _shift_id;
END $function$;
