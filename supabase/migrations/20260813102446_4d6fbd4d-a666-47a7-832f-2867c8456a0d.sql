-- ENUMS
CREATE TYPE public.stock_movement_type AS ENUM ('purchase','adjustment','waste','transfer_in','transfer_out','sale_consumption','sale_return','stocktake');

-- ITEMS
CREATE TABLE public.inventory_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  name text NOT NULL,
  name_ar text,
  sku text,
  unit text NOT NULL DEFAULT 'pcs',
  cost_per_unit numeric NOT NULL DEFAULT 0 CHECK (cost_per_unit >= 0),
  min_qty numeric NOT NULL DEFAULT 0 CHECK (min_qty >= 0),
  is_active boolean NOT NULL DEFAULT true,
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE ON public.inventory_items TO authenticated;
GRANT ALL ON public.inventory_items TO service_role;
ALTER TABLE public.inventory_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "inv_items_select" ON public.inventory_items FOR SELECT TO authenticated
  USING (company_id = public.current_company_id() AND (public.has_permission('inventory.view') OR public.is_super_admin()));
CREATE POLICY "inv_items_insert" ON public.inventory_items FOR INSERT TO authenticated
  WITH CHECK (company_id = public.current_company_id() AND (public.has_permission('inventory.adjust') OR public.is_super_admin()));
CREATE POLICY "inv_items_update" ON public.inventory_items FOR UPDATE TO authenticated
  USING (company_id = public.current_company_id() AND (public.has_permission('inventory.adjust') OR public.is_super_admin()));
CREATE TRIGGER t_inv_items_upd BEFORE UPDATE ON public.inventory_items FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- BRANCH STOCK
CREATE TABLE public.branch_stock (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  item_id uuid NOT NULL REFERENCES public.inventory_items(id) ON DELETE CASCADE,
  branch_id uuid NOT NULL REFERENCES public.branches(id),
  quantity numeric NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (item_id, branch_id)
);
GRANT SELECT ON public.branch_stock TO authenticated;
GRANT ALL ON public.branch_stock TO service_role;
ALTER TABLE public.branch_stock ENABLE ROW LEVEL SECURITY;
CREATE POLICY "branch_stock_select" ON public.branch_stock FOR SELECT TO authenticated
  USING (
    (public.has_permission('inventory.view') OR public.is_super_admin())
    AND public.can_access_branch(branch_id)
    AND EXISTS (SELECT 1 FROM public.inventory_items i WHERE i.id = item_id AND i.company_id = public.current_company_id())
  );
CREATE TRIGGER t_branch_stock_upd BEFORE UPDATE ON public.branch_stock FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- MOVEMENTS (append-only)
CREATE TABLE public.stock_movements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  branch_id uuid NOT NULL REFERENCES public.branches(id),
  item_id uuid NOT NULL REFERENCES public.inventory_items(id),
  movement_type public.stock_movement_type NOT NULL,
  quantity numeric NOT NULL,
  unit_cost numeric NOT NULL DEFAULT 0,
  balance_after numeric NOT NULL DEFAULT 0,
  reference_type text,
  reference_id uuid,
  reason text,
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.stock_movements TO authenticated;
GRANT ALL ON public.stock_movements TO service_role;
ALTER TABLE public.stock_movements ENABLE ROW LEVEL SECURITY;
CREATE POLICY "stock_moves_select" ON public.stock_movements FOR SELECT TO authenticated
  USING (company_id = public.current_company_id()
    AND (public.has_permission('inventory.view') OR public.is_super_admin())
    AND public.can_access_branch(branch_id));
CREATE TRIGGER t_stock_moves_no_delete BEFORE DELETE ON public.stock_movements FOR EACH ROW EXECUTE FUNCTION public.forbid_hard_delete();
CREATE INDEX idx_stock_moves_item ON public.stock_movements (item_id, branch_id, created_at DESC);

-- RECIPES
CREATE TABLE public.product_recipes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  size_id uuid REFERENCES public.product_sizes(id) ON DELETE CASCADE,
  item_id uuid NOT NULL REFERENCES public.inventory_items(id) ON DELETE CASCADE,
  quantity numeric NOT NULL CHECK (quantity > 0),
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX idx_recipe_unique ON public.product_recipes (product_id, item_id, COALESCE(size_id, '00000000-0000-0000-0000-000000000000'::uuid));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.product_recipes TO authenticated;
GRANT ALL ON public.product_recipes TO service_role;
ALTER TABLE public.product_recipes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "recipes_select" ON public.product_recipes FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.products p WHERE p.id = product_id AND p.company_id = public.current_company_id())
    AND (public.has_permission('inventory.view') OR public.has_permission('products.view') OR public.is_super_admin()));
CREATE POLICY "recipes_write" ON public.product_recipes FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.products p WHERE p.id = product_id AND p.company_id = public.current_company_id())
    AND (public.has_permission('inventory.adjust') OR public.is_super_admin()));
CREATE POLICY "recipes_update" ON public.product_recipes FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.products p WHERE p.id = product_id AND p.company_id = public.current_company_id())
    AND (public.has_permission('inventory.adjust') OR public.is_super_admin()));
CREATE POLICY "recipes_delete" ON public.product_recipes FOR DELETE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.products p WHERE p.id = product_id AND p.company_id = public.current_company_id())
    AND (public.has_permission('inventory.adjust') OR public.is_super_admin()));
CREATE TRIGGER t_recipes_upd BEFORE UPDATE ON public.product_recipes FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- CORE MOVEMENT ENGINE
CREATE OR REPLACE FUNCTION public.apply_stock_movement(
  _branch_id uuid, _item_id uuid, _type public.stock_movement_type, _qty numeric,
  _unit_cost numeric DEFAULT NULL, _reason text DEFAULT NULL,
  _reference_type text DEFAULT NULL, _reference_id uuid DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _company uuid; _profile uuid := public.current_profile_id(); _bal numeric; _cost numeric; _mv uuid; _min numeric; _name text;
BEGIN
  SELECT i.company_id, COALESCE(_unit_cost, i.cost_per_unit), i.min_qty, i.name
    INTO _company, _cost, _min, _name
  FROM public.inventory_items i WHERE i.id = _item_id;
  IF _company IS NULL THEN RAISE EXCEPTION 'Inventory item not found'; END IF;

  INSERT INTO public.branch_stock (item_id, branch_id, quantity)
  VALUES (_item_id, _branch_id, _qty)
  ON CONFLICT (item_id, branch_id) DO UPDATE SET quantity = public.branch_stock.quantity + _qty, updated_at = now()
  RETURNING quantity INTO _bal;

  INSERT INTO public.stock_movements (company_id, branch_id, item_id, movement_type, quantity, unit_cost,
    balance_after, reference_type, reference_id, reason, created_by)
  VALUES (_company, _branch_id, _item_id, _type, _qty, COALESCE(_cost,0), _bal, _reference_type, _reference_id, _reason, _profile)
  RETURNING id INTO _mv;

  IF _bal <= _min AND _qty < 0 THEN
    INSERT INTO public.notifications (company_id, branch_id, required_permission, type, severity, title, body, data)
    VALUES (_company, _branch_id, 'inventory.view', 'inventory.low_stock', 'warning',
      'Low stock: ' || _name, 'Remaining quantity: ' || _bal::text,
      jsonb_build_object('item_id', _item_id, 'quantity', _bal, 'min_qty', _min));
  END IF;
  RETURN _mv;
END $$;

REVOKE EXECUTE ON FUNCTION public.apply_stock_movement(uuid,uuid,public.stock_movement_type,numeric,numeric,text,text,uuid) FROM PUBLIC, anon, authenticated;

-- MANUAL ENTRY (permission-checked)
CREATE OR REPLACE FUNCTION public.record_stock_movement(
  _branch_id uuid, _item_id uuid, _type public.stock_movement_type, _qty numeric,
  _unit_cost numeric DEFAULT NULL, _reason text DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _needed text; _signed numeric; _current numeric := 0; _mv uuid;
BEGIN
  IF public.current_profile_id() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT public.can_access_branch(_branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _qty IS NULL OR _qty = 0 THEN RAISE EXCEPTION 'Quantity is required'; END IF;

  _needed := CASE _type WHEN 'waste' THEN 'inventory.waste' WHEN 'transfer_in' THEN 'inventory.transfer'
    WHEN 'transfer_out' THEN 'inventory.transfer' WHEN 'purchase' THEN 'purchases.create' ELSE 'inventory.adjust' END;
  IF NOT (public.has_permission(_needed) OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF _type IN ('waste','transfer_out') AND (_reason IS NULL OR btrim(_reason) = '') THEN
    RAISE EXCEPTION 'A reason is required';
  END IF;

  SELECT COALESCE(bs.quantity,0) INTO _current FROM public.branch_stock bs
  WHERE bs.item_id = _item_id AND bs.branch_id = _branch_id;

  IF _type = 'stocktake' THEN
    _signed := _qty - COALESCE(_current,0);
    IF _signed = 0 THEN RETURN NULL; END IF;
  ELSIF _type IN ('waste','transfer_out') THEN
    _signed := -abs(_qty);
  ELSIF _type = 'adjustment' THEN
    _signed := _qty;
  ELSE
    _signed := abs(_qty);
  END IF;

  IF COALESCE(_current,0) + _signed < 0 THEN RAISE EXCEPTION 'Not enough stock available'; END IF;

  _mv := public.apply_stock_movement(_branch_id, _item_id, _type, _signed, _unit_cost, _reason, 'manual', NULL);
  PERFORM public.log_audit('inventory.' || _type::text, 'inventory', 'stock_movements', _mv, NULL,
    jsonb_build_object('item_id', _item_id, 'quantity', _signed, 'reason', _reason), _reason, _branch_id);
  RETURN _mv;
END $$;

-- TRANSFER BETWEEN BRANCHES
CREATE OR REPLACE FUNCTION public.transfer_stock(
  _from_branch uuid, _to_branch uuid, _item_id uuid, _qty numeric, _reason text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _current numeric := 0;
BEGIN
  IF NOT (public.has_permission('inventory.transfer') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF _from_branch = _to_branch THEN RAISE EXCEPTION 'Choose two different branches'; END IF;
  IF NOT (public.can_access_branch(_from_branch) AND public.can_access_branch(_to_branch)) THEN
    RAISE EXCEPTION 'Not authorized for this branch';
  END IF;
  IF _qty IS NULL OR _qty <= 0 THEN RAISE EXCEPTION 'Quantity must be greater than zero'; END IF;
  SELECT COALESCE(bs.quantity,0) INTO _current FROM public.branch_stock bs WHERE bs.item_id = _item_id AND bs.branch_id = _from_branch;
  IF COALESCE(_current,0) < _qty THEN RAISE EXCEPTION 'Not enough stock available'; END IF;

  PERFORM public.apply_stock_movement(_from_branch, _item_id, 'transfer_out', -_qty, NULL, _reason, 'transfer', _to_branch);
  PERFORM public.apply_stock_movement(_to_branch, _item_id, 'transfer_in', _qty, NULL, _reason, 'transfer', _from_branch);
  PERFORM public.log_audit('inventory.transfer','inventory','inventory_items',_item_id,NULL,
    jsonb_build_object('from',_from_branch,'to',_to_branch,'quantity',_qty),_reason,_from_branch);
END $$;

-- AUTO CONSUMPTION ON SALE
CREATE OR REPLACE FUNCTION public.consume_recipe_on_sale() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _branch uuid; _r record;
BEGIN
  SELECT o.branch_id INTO _branch FROM public.orders o WHERE o.id = NEW.order_id;
  IF _branch IS NULL OR NEW.product_id IS NULL THEN RETURN NEW; END IF;
  FOR _r IN
    SELECT pr.item_id, pr.quantity FROM public.product_recipes pr
    WHERE pr.product_id = NEW.product_id
      AND (pr.size_id IS NULL OR pr.size_id = NEW.size_id)
  LOOP
    PERFORM public.apply_stock_movement(_branch, _r.item_id, 'sale_consumption',
      -(_r.quantity * NEW.quantity), NULL, NULL, 'order_item', NEW.id);
  END LOOP;
  RETURN NEW;
END $$;
CREATE TRIGGER t_order_items_consume AFTER INSERT ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public.consume_recipe_on_sale();

-- RETURN STOCK WHEN ORDER CANCELLED
CREATE OR REPLACE FUNCTION public.return_stock_on_cancel() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _r record;
BEGIN
  IF NEW.status = 'cancelled' AND OLD.status <> 'cancelled' THEN
    FOR _r IN
      SELECT sm.item_id, sm.quantity, sm.branch_id FROM public.stock_movements sm
      JOIN public.order_items oi ON oi.id = sm.reference_id
      WHERE sm.reference_type = 'order_item' AND sm.movement_type = 'sale_consumption' AND oi.order_id = NEW.id
    LOOP
      PERFORM public.apply_stock_movement(_r.branch_id, _r.item_id, 'sale_return', -_r.quantity, NULL,
        'Order cancelled', 'order', NEW.id);
    END LOOP;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER t_orders_return_stock AFTER UPDATE ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.return_stock_on_cancel();

-- SEED SAMPLE ITEMS
INSERT INTO public.inventory_items (company_id, name, name_ar, unit, cost_per_unit, min_qty)
SELECT c.id, v.name, v.name_ar, v.unit, v.cost, v.min_qty
FROM public.companies c,
  (VALUES
    ('Coffee Beans','حبوب قهوة','kg',450,2),
    ('Milk','لبن','liter',35,10),
    ('Sugar','سكر','kg',30,5),
    ('Paper Cup 8oz','كوب ورقي 8 أونصة','pcs',1.5,200),
    ('Chocolate Syrup','صوص شوكولاتة','liter',120,2)
  ) AS v(name,name_ar,unit,cost,min_qty)
WHERE c.is_active;