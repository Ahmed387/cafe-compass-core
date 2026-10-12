-- SUPPLIERS
CREATE TABLE public.suppliers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  name text NOT NULL,
  contact_person text,
  phone text,
  email text,
  address text,
  payment_terms text,
  notes text,
  is_active boolean NOT NULL DEFAULT true,
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE ON public.suppliers TO authenticated;
GRANT ALL ON public.suppliers TO service_role;
ALTER TABLE public.suppliers ENABLE ROW LEVEL SECURITY;
CREATE POLICY suppliers_select ON public.suppliers FOR SELECT TO authenticated
  USING (company_id = public.current_company_id()
    AND (public.has_permission('purchases.view') OR public.has_permission('inventory.view') OR public.is_super_admin()));
CREATE POLICY suppliers_insert ON public.suppliers FOR INSERT TO authenticated
  WITH CHECK (company_id = public.current_company_id()
    AND (public.has_permission('suppliers.create') OR public.has_permission('purchases.create') OR public.is_super_admin()));
CREATE POLICY suppliers_update ON public.suppliers FOR UPDATE TO authenticated
  USING (company_id = public.current_company_id()
    AND (public.has_permission('suppliers.update') OR public.has_permission('purchases.create') OR public.is_super_admin()));
CREATE TRIGGER t_suppliers_upd BEFORE UPDATE ON public.suppliers FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE INDEX idx_suppliers_company ON public.suppliers(company_id);

-- PURCHASES
CREATE TYPE public.purchase_status AS ENUM ('draft','received','cancelled');

CREATE TABLE public.purchases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  branch_id uuid NOT NULL REFERENCES public.branches(id),
  supplier_id uuid REFERENCES public.suppliers(id),
  invoice_number text,
  purchase_date date NOT NULL DEFAULT CURRENT_DATE,
  subtotal numeric(14,2) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
  tax_amount numeric(14,2) NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
  discount_amount numeric(14,2) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
  total numeric(14,2) NOT NULL DEFAULT 0 CHECK (total >= 0),
  status public.purchase_status NOT NULL DEFAULT 'draft',
  payment_method text,
  notes text,
  cancel_reason text,
  received_at timestamptz,
  received_by uuid REFERENCES public.user_profiles(id),
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.purchases TO authenticated;
GRANT ALL ON public.purchases TO service_role;
ALTER TABLE public.purchases ENABLE ROW LEVEL SECURITY;
CREATE POLICY purchases_select ON public.purchases FOR SELECT TO authenticated
  USING (company_id = public.current_company_id() AND public.can_access_branch(branch_id)
    AND (public.has_permission('purchases.view') OR public.has_permission('inventory.view') OR public.is_super_admin()));
CREATE TRIGGER t_purchases_upd BEFORE UPDATE ON public.purchases FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER t_purchases_no_delete BEFORE DELETE ON public.purchases FOR EACH ROW EXECUTE FUNCTION public.forbid_hard_delete();
CREATE INDEX idx_purchases_branch_date ON public.purchases(branch_id, purchase_date DESC);

CREATE TABLE public.purchase_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  purchase_id uuid NOT NULL REFERENCES public.purchases(id) ON DELETE CASCADE,
  item_id uuid NOT NULL REFERENCES public.inventory_items(id),
  quantity numeric(14,3) NOT NULL CHECK (quantity > 0),
  unit_cost numeric(14,4) NOT NULL CHECK (unit_cost >= 0),
  line_total numeric(14,2) NOT NULL DEFAULT 0 CHECK (line_total >= 0),
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.purchase_items TO authenticated;
GRANT ALL ON public.purchase_items TO service_role;
ALTER TABLE public.purchase_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY purchase_items_select ON public.purchase_items FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.purchases p WHERE p.id = purchase_id
    AND p.company_id = public.current_company_id() AND public.can_access_branch(p.branch_id)
    AND (public.has_permission('purchases.view') OR public.has_permission('inventory.view') OR public.is_super_admin())));
CREATE TRIGGER t_purchase_items_no_delete BEFORE DELETE ON public.purchase_items FOR EACH ROW EXECUTE FUNCTION public.forbid_hard_delete();
CREATE INDEX idx_purchase_items_purchase ON public.purchase_items(purchase_id);

-- CREATE PURCHASE (draft or immediately received)
CREATE OR REPLACE FUNCTION public.create_purchase(
  _branch_id uuid,
  _supplier_id uuid,
  _items jsonb,
  _invoice_number text DEFAULT NULL,
  _purchase_date date DEFAULT CURRENT_DATE,
  _tax_amount numeric DEFAULT 0,
  _discount_amount numeric DEFAULT 0,
  _payment_method text DEFAULT NULL,
  _notes text DEFAULT NULL,
  _receive boolean DEFAULT true
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  _profile uuid := public.current_profile_id();
  _company uuid := public.current_company_id();
  _purchase uuid; _it jsonb; _sub numeric := 0; _qty numeric; _cost numeric; _item public.inventory_items;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('purchases.create') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF NOT public.can_access_branch(_branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _items IS NULL OR jsonb_array_length(_items) = 0 THEN RAISE EXCEPTION 'Purchase has no items'; END IF;
  IF _supplier_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.suppliers s WHERE s.id = _supplier_id AND s.company_id = _company) THEN
    RAISE EXCEPTION 'Supplier not found';
  END IF;

  INSERT INTO public.purchases (company_id, branch_id, supplier_id, invoice_number, purchase_date,
    tax_amount, discount_amount, payment_method, notes, created_by)
  VALUES (_company, _branch_id, _supplier_id, NULLIF(_invoice_number,''), COALESCE(_purchase_date, CURRENT_DATE),
    COALESCE(_tax_amount,0), COALESCE(_discount_amount,0), NULLIF(_payment_method,''), NULLIF(_notes,''), _profile)
  RETURNING id INTO _purchase;

  FOR _it IN SELECT * FROM jsonb_array_elements(_items) LOOP
    _qty := COALESCE((_it->>'quantity')::numeric, 0);
    _cost := COALESCE((_it->>'unit_cost')::numeric, 0);
    IF _qty <= 0 THEN RAISE EXCEPTION 'Quantity must be greater than zero'; END IF;
    IF _cost < 0 THEN RAISE EXCEPTION 'Unit cost cannot be negative'; END IF;
    SELECT * INTO _item FROM public.inventory_items
    WHERE id = NULLIF(_it->>'item_id','')::uuid AND company_id = _company AND is_active;
    IF _item.id IS NULL THEN RAISE EXCEPTION 'Inventory item not found'; END IF;

    INSERT INTO public.purchase_items (purchase_id, item_id, quantity, unit_cost, line_total)
    VALUES (_purchase, _item.id, _qty, _cost, round(_qty * _cost, 2));
    _sub := _sub + round(_qty * _cost, 2);
  END LOOP;

  IF COALESCE(_discount_amount,0) > _sub THEN RAISE EXCEPTION 'Discount exceeds purchase subtotal'; END IF;

  UPDATE public.purchases
     SET subtotal = round(_sub,2),
         total = round(_sub - COALESCE(_discount_amount,0) + COALESCE(_tax_amount,0), 2)
   WHERE id = _purchase;

  PERFORM public.log_audit('purchase.create','purchases','purchases',_purchase,NULL,
    jsonb_build_object('subtotal',_sub,'supplier_id',_supplier_id),NULL,_branch_id);

  IF COALESCE(_receive, true) THEN PERFORM public.receive_purchase(_purchase); END IF;
  RETURN _purchase;
END $$;

-- RECEIVE PURCHASE: add stock + refresh unit cost
CREATE OR REPLACE FUNCTION public.receive_purchase(_purchase_id uuid)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _p public.purchases; _profile uuid := public.current_profile_id(); _r record;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('purchases.receive') OR public.has_permission('purchases.create') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  SELECT * INTO _p FROM public.purchases WHERE id = _purchase_id AND company_id = public.current_company_id();
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Purchase not found'; END IF;
  IF NOT public.can_access_branch(_p.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _p.status = 'received' THEN RAISE EXCEPTION 'This purchase was already received'; END IF;
  IF _p.status = 'cancelled' THEN RAISE EXCEPTION 'This purchase is cancelled'; END IF;

  FOR _r IN SELECT item_id, quantity, unit_cost FROM public.purchase_items WHERE purchase_id = _purchase_id LOOP
    PERFORM public.apply_stock_movement(_p.branch_id, _r.item_id, 'purchase', _r.quantity, _r.unit_cost,
      'Purchase received', 'purchase', _purchase_id);
    UPDATE public.inventory_items SET cost_per_unit = _r.unit_cost, updated_at = now()
    WHERE id = _r.item_id AND _r.unit_cost > 0;
  END LOOP;

  UPDATE public.purchases SET status = 'received', received_at = now(), received_by = _profile WHERE id = _purchase_id;
  PERFORM public.log_audit('purchase.receive','purchases','purchases',_purchase_id,
    jsonb_build_object('status',_p.status), jsonb_build_object('status','received'), NULL, _p.branch_id);
  RETURN _purchase_id;
END $$;

-- CANCEL PURCHASE: reverse stock if it was received
CREATE OR REPLACE FUNCTION public.cancel_purchase(_purchase_id uuid, _reason text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _p public.purchases; _r record;
BEGIN
  IF public.current_profile_id() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('purchases.cancel') OR public.has_permission('purchases.create') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF _reason IS NULL OR length(btrim(_reason)) < 3 THEN RAISE EXCEPTION 'A reason is required'; END IF;
  SELECT * INTO _p FROM public.purchases WHERE id = _purchase_id AND company_id = public.current_company_id();
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Purchase not found'; END IF;
  IF NOT public.can_access_branch(_p.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _p.status = 'cancelled' THEN RAISE EXCEPTION 'This purchase is already cancelled'; END IF;

  IF _p.status = 'received' THEN
    FOR _r IN SELECT item_id, quantity, unit_cost FROM public.purchase_items WHERE purchase_id = _purchase_id LOOP
      PERFORM public.apply_stock_movement(_p.branch_id, _r.item_id, 'adjustment', -_r.quantity, _r.unit_cost,
        'Purchase cancelled: ' || _reason, 'purchase', _purchase_id);
    END LOOP;
  END IF;

  UPDATE public.purchases SET status = 'cancelled', cancel_reason = _reason WHERE id = _purchase_id;
  PERFORM public.log_audit('purchase.cancel','purchases','purchases',_purchase_id,
    jsonb_build_object('status',_p.status), jsonb_build_object('status','cancelled'), _reason, _p.branch_id);
  RETURN _purchase_id;
END $$;

REVOKE ALL ON FUNCTION public.create_purchase(uuid,uuid,jsonb,text,date,numeric,numeric,text,text,boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.receive_purchase(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cancel_purchase(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_purchase(uuid,uuid,jsonb,text,date,numeric,numeric,text,text,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.receive_purchase(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_purchase(uuid,text) TO authenticated;