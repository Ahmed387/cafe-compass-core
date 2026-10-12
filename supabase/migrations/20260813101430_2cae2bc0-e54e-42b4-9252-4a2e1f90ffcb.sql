-- ENUMS
CREATE TYPE public.shift_status AS ENUM ('open','closed');
CREATE TYPE public.order_type AS ENUM ('dine_in','takeaway','delivery');
CREATE TYPE public.order_status AS ENUM ('open','completed','cancelled','refunded');
CREATE TYPE public.order_item_status AS ENUM ('active','voided');

-- SHIFTS
CREATE TABLE public.shifts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  branch_id uuid NOT NULL REFERENCES public.branches(id),
  user_id uuid NOT NULL REFERENCES public.user_profiles(id),
  status public.shift_status NOT NULL DEFAULT 'open',
  opening_cash numeric(14,2) NOT NULL DEFAULT 0,
  closing_cash numeric(14,2),
  expected_cash numeric(14,2),
  variance numeric(14,2),
  notes text,
  opened_at timestamptz NOT NULL DEFAULT now(),
  closed_at timestamptz,
  closed_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX shifts_one_open_per_user_branch ON public.shifts (branch_id, user_id) WHERE status = 'open';
GRANT SELECT, INSERT, UPDATE ON public.shifts TO authenticated;
GRANT ALL ON public.shifts TO service_role;
ALTER TABLE public.shifts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "shifts_select" ON public.shifts FOR SELECT TO authenticated
  USING (company_id = public.current_company_id() AND public.can_access_branch(branch_id)
         AND (public.has_permission('shifts.view') OR user_id = public.current_profile_id()));
CREATE POLICY "shifts_insert" ON public.shifts FOR INSERT TO authenticated
  WITH CHECK (company_id = public.current_company_id() AND public.can_access_branch(branch_id)
              AND public.has_permission('shifts.open'));
CREATE POLICY "shifts_update" ON public.shifts FOR UPDATE TO authenticated
  USING (company_id = public.current_company_id() AND public.can_access_branch(branch_id)
         AND (public.has_permission('shifts.close') OR public.has_permission('shifts.adjust_cash')));
CREATE TRIGGER t_shifts_upd BEFORE UPDATE ON public.shifts FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ORDERS
CREATE TABLE public.orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  branch_id uuid NOT NULL REFERENCES public.branches(id),
  shift_id uuid REFERENCES public.shifts(id),
  order_number text NOT NULL,
  order_type public.order_type NOT NULL DEFAULT 'takeaway',
  status public.order_status NOT NULL DEFAULT 'completed',
  subtotal numeric(14,2) NOT NULL DEFAULT 0,
  discount_amount numeric(14,2) NOT NULL DEFAULT 0,
  discount_reason text,
  tax_amount numeric(14,2) NOT NULL DEFAULT 0,
  total numeric(14,2) NOT NULL DEFAULT 0,
  customer_name text,
  customer_phone text,
  notes text,
  cancel_reason text,
  created_by uuid REFERENCES public.user_profiles(id),
  completed_at timestamptz,
  cancelled_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX orders_number_per_branch ON public.orders (branch_id, order_number);
CREATE INDEX orders_branch_created_idx ON public.orders (branch_id, created_at DESC);
CREATE INDEX orders_shift_idx ON public.orders (shift_id);
GRANT SELECT, INSERT, UPDATE ON public.orders TO authenticated;
GRANT ALL ON public.orders TO service_role;
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY "orders_select" ON public.orders FOR SELECT TO authenticated
  USING (company_id = public.current_company_id() AND public.can_access_branch(branch_id)
         AND (public.has_permission('pos.view') OR public.has_permission('reports.view_sales')));
CREATE POLICY "orders_insert" ON public.orders FOR INSERT TO authenticated
  WITH CHECK (company_id = public.current_company_id() AND public.can_access_branch(branch_id)
              AND public.has_permission('pos.create_order'));
CREATE POLICY "orders_update" ON public.orders FOR UPDATE TO authenticated
  USING (company_id = public.current_company_id() AND public.can_access_branch(branch_id)
         AND (public.has_permission('pos.cancel_order') OR public.has_permission('pos.process_refund')));
CREATE TRIGGER t_orders_upd BEFORE UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER t_orders_no_delete BEFORE DELETE ON public.orders FOR EACH ROW EXECUTE FUNCTION public.forbid_hard_delete();

-- ORDER ITEMS
CREATE TABLE public.order_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  product_id uuid REFERENCES public.products(id),
  size_id uuid REFERENCES public.product_sizes(id),
  product_name text NOT NULL,
  size_name text,
  unit_price numeric(14,2) NOT NULL DEFAULT 0,
  modifiers_total numeric(14,2) NOT NULL DEFAULT 0,
  quantity integer NOT NULL DEFAULT 1 CHECK (quantity > 0),
  line_total numeric(14,2) NOT NULL DEFAULT 0,
  unit_cost numeric(14,2) NOT NULL DEFAULT 0,
  status public.order_item_status NOT NULL DEFAULT 'active',
  void_reason text,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX order_items_order_idx ON public.order_items (order_id);
GRANT SELECT, INSERT, UPDATE ON public.order_items TO authenticated;
GRANT ALL ON public.order_items TO service_role;
ALTER TABLE public.order_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "order_items_select" ON public.order_items FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.orders o WHERE o.id = order_id));
CREATE POLICY "order_items_insert" ON public.order_items FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.orders o WHERE o.id = order_id) AND public.has_permission('pos.create_order'));
CREATE POLICY "order_items_update" ON public.order_items FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.orders o WHERE o.id = order_id) AND public.has_permission('pos.void_item'));
CREATE TRIGGER t_order_items_no_delete BEFORE DELETE ON public.order_items FOR EACH ROW EXECUTE FUNCTION public.forbid_hard_delete();

-- ORDER ITEM MODIFIERS
CREATE TABLE public.order_item_modifiers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_item_id uuid NOT NULL REFERENCES public.order_items(id) ON DELETE CASCADE,
  option_id uuid REFERENCES public.modifier_options(id),
  name text NOT NULL,
  price_delta numeric(14,2) NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX order_item_modifiers_item_idx ON public.order_item_modifiers (order_item_id);
GRANT SELECT, INSERT ON public.order_item_modifiers TO authenticated;
GRANT ALL ON public.order_item_modifiers TO service_role;
ALTER TABLE public.order_item_modifiers ENABLE ROW LEVEL SECURITY;
CREATE POLICY "oim_select" ON public.order_item_modifiers FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.order_items i WHERE i.id = order_item_id));
CREATE POLICY "oim_insert" ON public.order_item_modifiers FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.order_items i WHERE i.id = order_item_id) AND public.has_permission('pos.create_order'));

-- ORDER PAYMENTS
CREATE TABLE public.order_payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  payment_method_id uuid REFERENCES public.payment_methods(id),
  method_key text NOT NULL,
  amount numeric(14,2) NOT NULL,
  reference text,
  sender_number text,
  receiver_number text,
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX order_payments_order_idx ON public.order_payments (order_id);
GRANT SELECT, INSERT ON public.order_payments TO authenticated;
GRANT ALL ON public.order_payments TO service_role;
ALTER TABLE public.order_payments ENABLE ROW LEVEL SECURITY;
CREATE POLICY "order_payments_select" ON public.order_payments FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.orders o WHERE o.id = order_id));
CREATE POLICY "order_payments_insert" ON public.order_payments FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.orders o WHERE o.id = order_id) AND public.has_permission('pos.create_order'));
CREATE TRIGGER t_order_payments_no_delete BEFORE DELETE ON public.order_payments FOR EACH ROW EXECUTE FUNCTION public.forbid_hard_delete();

-- OPEN SHIFT
CREATE OR REPLACE FUNCTION public.open_shift(_branch_id uuid, _opening_cash numeric DEFAULT 0)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _profile uuid := public.current_profile_id(); _company uuid := public.current_company_id(); _id uuid;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('shifts.open') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF NOT public.can_access_branch(_branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF EXISTS (SELECT 1 FROM public.shifts WHERE branch_id = _branch_id AND user_id = _profile AND status = 'open') THEN
    RAISE EXCEPTION 'You already have an open shift';
  END IF;
  INSERT INTO public.shifts (company_id, branch_id, user_id, opening_cash)
  VALUES (_company, _branch_id, _profile, COALESCE(_opening_cash, 0)) RETURNING id INTO _id;
  PERFORM public.log_audit('shift.open','pos','shifts',_id,NULL,jsonb_build_object('opening_cash',_opening_cash),NULL,_branch_id);
  RETURN _id;
END $$;

-- CLOSE SHIFT
CREATE OR REPLACE FUNCTION public.close_shift(_shift_id uuid, _closing_cash numeric, _notes text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _s public.shifts; _expected numeric; _profile uuid := public.current_profile_id();
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO _s FROM public.shifts WHERE id = _shift_id;
  IF _s.id IS NULL THEN RAISE EXCEPTION 'Shift not found'; END IF;
  IF _s.status = 'closed' THEN RAISE EXCEPTION 'Shift already closed'; END IF;
  IF NOT (public.has_permission('shifts.close') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF NOT public.can_access_branch(_s.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;

  SELECT _s.opening_cash + COALESCE(SUM(p.amount),0) INTO _expected
  FROM public.orders o JOIN public.order_payments p ON p.order_id = o.id
  WHERE o.shift_id = _shift_id AND o.status <> 'cancelled' AND p.method_key = 'cash';

  UPDATE public.shifts SET status = 'closed', closing_cash = _closing_cash, expected_cash = _expected,
    variance = COALESCE(_closing_cash,0) - _expected, notes = _notes, closed_at = now(), closed_by = _profile
  WHERE id = _shift_id;
  PERFORM public.log_audit('shift.close','pos','shifts',_shift_id,NULL,
    jsonb_build_object('closing_cash',_closing_cash,'expected_cash',_expected),_notes,_s.branch_id);
  RETURN _shift_id;
END $$;

-- CREATE ORDER
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
) RETURNS TABLE (id uuid, order_number text) LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
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

  SELECT id INTO _shift FROM public.shifts
  WHERE branch_id = _branch_id AND user_id = _profile AND status = 'open' LIMIT 1;
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

-- CANCEL ORDER
CREATE OR REPLACE FUNCTION public.cancel_pos_order(_order_id uuid, _reason text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _o public.orders;
BEGIN
  SELECT * INTO _o FROM public.orders WHERE id = _order_id;
  IF _o.id IS NULL THEN RAISE EXCEPTION 'Order not found'; END IF;
  IF _o.status = 'cancelled' THEN RAISE EXCEPTION 'Order already cancelled'; END IF;
  IF NOT (public.has_permission('pos.cancel_order') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF NOT public.can_access_branch(_o.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _reason IS NULL OR length(trim(_reason)) < 3 THEN RAISE EXCEPTION 'A cancellation reason is required'; END IF;
  UPDATE public.orders SET status = 'cancelled', cancel_reason = _reason, cancelled_at = now() WHERE id = _order_id;
  UPDATE public.order_items SET status = 'voided', void_reason = _reason WHERE order_id = _order_id;
  PERFORM public.log_audit('order.cancel','pos','orders',_order_id,
    jsonb_build_object('status',_o.status),jsonb_build_object('status','cancelled'),_reason,_o.branch_id);
  RETURN _order_id;
END $$;
