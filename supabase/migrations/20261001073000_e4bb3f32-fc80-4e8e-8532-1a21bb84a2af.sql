ALTER TABLE public.product_recipes ADD COLUMN IF NOT EXISTS unit text;

CREATE OR REPLACE FUNCTION public.save_recipe_matrix(_product_id uuid, _lines jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _l jsonb; _company uuid;
BEGIN
  IF NOT (public.has_permission('products.update') OR public.has_permission('inventory.adjust')) THEN RAISE EXCEPTION 'Not allowed'; END IF;
  SELECT company_id INTO _company FROM public.products WHERE id = _product_id;
  IF _company IS NULL OR _company <> public.current_company_id() THEN RAISE EXCEPTION 'Product not found'; END IF;
  DELETE FROM public.product_recipes WHERE product_id = _product_id;
  FOR _l IN SELECT * FROM jsonb_array_elements(COALESCE(_lines,'[]')) LOOP
    IF COALESCE((_l->>'quantity')::numeric,0) <= 0 THEN CONTINUE; END IF;
    INSERT INTO public.product_recipes(product_id, size_id, item_id, quantity, unit, created_by)
    SELECT _product_id, NULLIF(_l->>'size_id','')::uuid, i.id, (_l->>'quantity')::numeric, NULLIF(_l->>'unit',''), public.current_profile_id()
    FROM public.inventory_items i WHERE i.id = (_l->>'item_id')::uuid AND i.company_id = _company;
  END LOOP;
  PERFORM public.log_audit('recipe.save','catalog','product',_product_id,NULL,_lines,NULL,NULL);
END $$;
REVOKE EXECUTE ON FUNCTION public.save_recipe_matrix(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_recipe_matrix(uuid, jsonb) TO authenticated;

-- Recipe cost onto each sold line (so COGS is real even when product.cost is 0)
CREATE OR REPLACE FUNCTION public.set_line_recipe_cost()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _c numeric;
BEGIN
  IF NEW.product_id IS NULL THEN RETURN NEW; END IF;
  SELECT SUM(pr.quantity * COALESCE(i.cost_per_unit,0)) INTO _c
  FROM public.product_recipes pr JOIN public.inventory_items i ON i.id = pr.item_id
  WHERE pr.product_id = NEW.product_id AND (pr.size_id IS NULL OR pr.size_id = NEW.size_id);
  IF COALESCE(_c,0) > 0 THEN NEW.unit_cost := _c; END IF;
  RETURN NEW;
END $$;
REVOKE EXECUTE ON FUNCTION public.set_line_recipe_cost() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_set_line_recipe_cost ON public.order_items;
CREATE TRIGGER trg_set_line_recipe_cost BEFORE INSERT ON public.order_items FOR EACH ROW EXECUTE FUNCTION public.set_line_recipe_cost();

-- One-step emergency transfer Main -> Bar (request + approval in one transaction)
CREATE OR REPLACE FUNCTION public.emergency_stock_transfer(_branch_id uuid, _items jsonb, _notes text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _id uuid; _it jsonb; _n int := 0; _main numeric; _name text; _cost numeric; _q numeric; _item uuid; _company uuid := public.current_company_id(); _me uuid := public.current_profile_id();
BEGIN
  IF NOT (public.has_permission('inventory.view') OR public.has_permission('pos.create_order')) OR NOT public.can_access_branch(_branch_id) THEN RAISE EXCEPTION 'Not allowed'; END IF;
  INSERT INTO public.stock_transfers(company_id, branch_id, notes, requested_by, status, decided_by, decided_at)
  VALUES (_company, _branch_id, COALESCE(NULLIF(trim(_notes),''),'تحويل طارئ من الكاشير'), _me, 'approved', _me, now()) RETURNING id INTO _id;
  FOR _it IN SELECT * FROM jsonb_array_elements(COALESCE(_items,'[]')) LOOP
    _q := COALESCE((_it->>'quantity')::numeric,0);
    IF _q <= 0 THEN CONTINUE; END IF;
    SELECT i.id, i.name, i.cost_per_unit INTO _item, _name, _cost FROM public.inventory_items i
      WHERE i.id = (_it->>'item_id')::uuid AND i.company_id = _company;
    IF _item IS NULL THEN RAISE EXCEPTION 'Item not found'; END IF;
    SELECT bs.quantity - bs.bar_quantity INTO _main FROM public.branch_stock bs WHERE bs.item_id = _item AND bs.branch_id = _branch_id FOR UPDATE;
    IF COALESCE(_main,0) < _q THEN RAISE EXCEPTION 'المخزن الرئيسي لا يكفي: % (متاح %)', _name, COALESCE(_main,0); END IF;
    INSERT INTO public.stock_transfer_items(transfer_id, item_id, quantity) VALUES (_id, _item, _q);
    UPDATE public.branch_stock SET bar_quantity = bar_quantity + _q, updated_at = now() WHERE item_id = _item AND branch_id = _branch_id;
    INSERT INTO public.stock_movements(company_id, branch_id, item_id, movement_type, quantity, unit_cost, balance_after, reference_type, reference_id, reason, created_by, location)
    SELECT _company, _branch_id, _item, 'transfer_out', -_q, _cost, bs.quantity - bs.bar_quantity, 'stock_transfer', _id, 'Main → Bar (طارئ)', _me, 'main' FROM public.branch_stock bs WHERE bs.item_id=_item AND bs.branch_id=_branch_id;
    INSERT INTO public.stock_movements(company_id, branch_id, item_id, movement_type, quantity, unit_cost, balance_after, reference_type, reference_id, reason, created_by, location)
    SELECT _company, _branch_id, _item, 'transfer_in', _q, _cost, bs.bar_quantity, 'stock_transfer', _id, 'Main → Bar (طارئ)', _me, 'bar' FROM public.branch_stock bs WHERE bs.item_id=_item AND bs.branch_id=_branch_id;
    _n := _n + 1;
  END LOOP;
  IF _n = 0 THEN RAISE EXCEPTION 'أضف صنفًا واحدًا على الأقل'; END IF;
  PERFORM public.log_audit('stock_transfer.emergency','inventory','stock_transfer',_id,NULL,_items,_notes,_branch_id);
  RETURN _id;
END $$;
REVOKE EXECUTE ON FUNCTION public.emergency_stock_transfer(uuid, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.emergency_stock_transfer(uuid, jsonb, text) TO authenticated;