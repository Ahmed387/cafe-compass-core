-- 1) Add-on (modifier option) recipes
CREATE TABLE public.modifier_option_recipes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  option_id uuid NOT NULL REFERENCES public.modifier_options(id) ON DELETE CASCADE,
  item_id uuid NOT NULL REFERENCES public.inventory_items(id) ON DELETE CASCADE,
  quantity numeric NOT NULL CHECK (quantity > 0),
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (option_id, item_id)
);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.modifier_option_recipes TO authenticated;
GRANT ALL ON public.modifier_option_recipes TO service_role;

ALTER TABLE public.modifier_option_recipes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "mor_select" ON public.modifier_option_recipes FOR SELECT TO authenticated
USING (
  public.is_super_admin() OR (
    (public.has_permission('inventory.view') OR public.has_permission('products.view'))
    AND EXISTS (
      SELECT 1 FROM public.modifier_options mo
      JOIN public.modifier_groups mg ON mg.id = mo.group_id
      WHERE mo.id = modifier_option_recipes.option_id AND mg.company_id = public.current_company_id()
    )
  )
);

CREATE POLICY "mor_insert" ON public.modifier_option_recipes FOR INSERT TO authenticated
WITH CHECK (
  (public.is_super_admin() OR public.has_permission('products.update'))
  AND EXISTS (
    SELECT 1 FROM public.modifier_options mo
    JOIN public.modifier_groups mg ON mg.id = mo.group_id
    WHERE mo.id = modifier_option_recipes.option_id AND mg.company_id = public.current_company_id()
  )
);

CREATE POLICY "mor_update" ON public.modifier_option_recipes FOR UPDATE TO authenticated
USING (
  (public.is_super_admin() OR public.has_permission('products.update'))
  AND EXISTS (
    SELECT 1 FROM public.modifier_options mo
    JOIN public.modifier_groups mg ON mg.id = mo.group_id
    WHERE mo.id = modifier_option_recipes.option_id AND mg.company_id = public.current_company_id()
  )
);

CREATE POLICY "mor_delete" ON public.modifier_option_recipes FOR DELETE TO authenticated
USING (
  (public.is_super_admin() OR public.has_permission('products.update'))
  AND EXISTS (
    SELECT 1 FROM public.modifier_options mo
    JOIN public.modifier_groups mg ON mg.id = mo.group_id
    WHERE mo.id = modifier_option_recipes.option_id AND mg.company_id = public.current_company_id()
  )
);

CREATE TRIGGER t_mor_upd BEFORE UPDATE ON public.modifier_option_recipes
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE INDEX idx_mor_option ON public.modifier_option_recipes(option_id);

-- 2) Never allow negative stock balances
CREATE OR REPLACE FUNCTION public.apply_stock_movement(_branch_id uuid, _item_id uuid, _type stock_movement_type, _qty numeric, _unit_cost numeric DEFAULT NULL::numeric, _reason text DEFAULT NULL::text, _reference_type text DEFAULT NULL::text, _reference_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  IF _bal < 0 THEN
    RAISE EXCEPTION 'Not enough stock available for %', _name;
  END IF;

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
END $function$;

-- 3) Consume add-on ingredients when an add-on is sold
CREATE OR REPLACE FUNCTION public.consume_modifier_recipe_on_sale()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _branch uuid; _qty int; _r record;
BEGIN
  IF NEW.option_id IS NULL THEN RETURN NEW; END IF;
  SELECT o.branch_id, oi.quantity INTO _branch, _qty
  FROM public.order_items oi JOIN public.orders o ON o.id = oi.order_id
  WHERE oi.id = NEW.order_item_id;
  IF _branch IS NULL THEN RETURN NEW; END IF;
  FOR _r IN SELECT mr.item_id, mr.quantity FROM public.modifier_option_recipes mr WHERE mr.option_id = NEW.option_id LOOP
    PERFORM public.apply_stock_movement(_branch, _r.item_id, 'sale_consumption',
      -(_r.quantity * COALESCE(_qty,1)), NULL, NULL, 'order_item', NEW.order_item_id);
  END LOOP;
  RETURN NEW;
END $function$;

DROP TRIGGER IF EXISTS t_order_item_mods_consume ON public.order_item_modifiers;
CREATE TRIGGER t_order_item_mods_consume AFTER INSERT ON public.order_item_modifiers
FOR EACH ROW EXECUTE FUNCTION public.consume_modifier_recipe_on_sale();

-- 4) Pre-flight stock check helper for POS
CREATE OR REPLACE FUNCTION public.check_order_stock(_branch_id uuid, _items jsonb)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _item jsonb; _mod jsonb; _r record; _needed jsonb := '{}'::jsonb; _key text; _qty numeric;
BEGIN
  FOR _item IN SELECT * FROM jsonb_array_elements(COALESCE(_items,'[]'::jsonb)) LOOP
    FOR _r IN
      SELECT pr.item_id, pr.quantity * COALESCE((_item->>'quantity')::numeric,0) AS need
      FROM public.product_recipes pr
      WHERE pr.product_id = NULLIF(_item->>'product_id','')::uuid
        AND (pr.size_id IS NULL OR pr.size_id = NULLIF(_item->>'size_id','')::uuid)
    LOOP
      _key := _r.item_id::text;
      _needed := jsonb_set(_needed, ARRAY[_key],
        to_jsonb(COALESCE((_needed->>_key)::numeric,0) + _r.need), true);
    END LOOP;

    IF _item ? 'modifiers' THEN
      FOR _mod IN SELECT * FROM jsonb_array_elements(_item->'modifiers') LOOP
        FOR _r IN
          SELECT mr.item_id, mr.quantity * COALESCE((_item->>'quantity')::numeric,0) AS need
          FROM public.modifier_option_recipes mr
          WHERE mr.option_id = NULLIF(_mod->>'option_id','')::uuid
        LOOP
          _key := _r.item_id::text;
          _needed := jsonb_set(_needed, ARRAY[_key],
            to_jsonb(COALESCE((_needed->>_key)::numeric,0) + _r.need), true);
        END LOOP;
      END LOOP;
    END IF;
  END LOOP;

  FOR _r IN SELECT key::uuid AS item_id, value::numeric AS need FROM jsonb_each_text(_needed) LOOP
    SELECT COALESCE(bs.quantity,0) INTO _qty FROM public.branch_stock bs
    WHERE bs.item_id = _r.item_id AND bs.branch_id = _branch_id;
    IF COALESCE(_qty,0) < _r.need THEN
      RAISE EXCEPTION 'Not enough stock available for %',
        (SELECT name FROM public.inventory_items WHERE id = _r.item_id);
    END IF;
  END LOOP;
END $function$;

REVOKE ALL ON FUNCTION public.check_order_stock(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.check_order_stock(uuid, jsonb) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.consume_modifier_recipe_on_sale() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.consume_modifier_recipe_on_sale() TO service_role;
