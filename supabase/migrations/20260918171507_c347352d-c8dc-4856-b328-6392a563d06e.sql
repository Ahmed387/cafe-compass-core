-- 1) Create a raw item with optional atomic opening balance
CREATE OR REPLACE FUNCTION public.create_inventory_item(
  _name text,
  _name_ar text DEFAULT NULL,
  _unit text DEFAULT 'kg',
  _sku text DEFAULT NULL,
  _cost_per_unit numeric DEFAULT 0,
  _min_qty numeric DEFAULT 0,
  _opening_qty numeric DEFAULT 0,
  _branch_id uuid DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _company uuid := public.current_company_id(); _item uuid;
BEGIN
  IF _company IS NULL THEN RAISE EXCEPTION 'No company context'; END IF;
  IF NOT (public.is_super_admin() OR public.has_permission('inventory.adjust')) THEN
    RAISE EXCEPTION 'غير مصرح لك بإضافة أصناف المخزن';
  END IF;
  IF _name IS NULL OR btrim(_name) = '' THEN RAISE EXCEPTION 'اسم الصنف مطلوب'; END IF;

  INSERT INTO public.inventory_items (company_id, name, name_ar, sku, unit, cost_per_unit, min_qty)
  VALUES (_company, btrim(_name), NULLIF(btrim(COALESCE(_name_ar,'')),''), NULLIF(btrim(COALESCE(_sku,'')),''),
          COALESCE(NULLIF(btrim(_unit),''),'kg'), COALESCE(_cost_per_unit,0), COALESCE(_min_qty,0))
  RETURNING id INTO _item;

  IF COALESCE(_opening_qty,0) > 0 THEN
    IF _branch_id IS NULL THEN RAISE EXCEPTION 'يرجى اختيار الفرع لتسجيل الرصيد الافتتاحي'; END IF;
    IF NOT public.can_access_branch(_branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
    PERFORM public.apply_stock_movement(_branch_id, _item, 'adjustment', _opening_qty,
      COALESCE(_cost_per_unit,0), 'الرصيد الافتتاحي', 'opening_balance', NULL);
  END IF;

  PERFORM public.log_audit('inventory_item.create','inventory','inventory_items',_item,NULL,
    jsonb_build_object('name',_name,'unit',_unit,'cost_per_unit',_cost_per_unit,
      'min_qty',_min_qty,'opening_qty',COALESCE(_opening_qty,0)), NULL, _branch_id);
  RETURN _item;
END $$;

REVOKE ALL ON FUNCTION public.create_inventory_item(text,text,text,text,numeric,numeric,numeric,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_inventory_item(text,text,text,text,numeric,numeric,numeric,uuid) TO authenticated, service_role;

-- 2) Bulk create raw items + opening balances in one transaction
CREATE OR REPLACE FUNCTION public.bulk_create_inventory_items(
  _items jsonb,
  _branch_id uuid DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _row jsonb; _created int := 0; _with_stock int := 0;
BEGIN
  IF jsonb_typeof(_items) <> 'array' THEN RAISE EXCEPTION 'Invalid payload'; END IF;
  FOR _row IN SELECT * FROM jsonb_array_elements(_items) LOOP
    IF COALESCE(btrim(_row->>'name'),'') = '' AND COALESCE(btrim(_row->>'name_ar'),'') = '' THEN
      CONTINUE;
    END IF;
    PERFORM public.create_inventory_item(
      COALESCE(NULLIF(btrim(_row->>'name'),''), btrim(_row->>'name_ar')),
      _row->>'name_ar',
      COALESCE(NULLIF(_row->>'unit',''),'kg'),
      NULL,
      COALESCE((_row->>'cost_per_unit')::numeric, 0),
      COALESCE((_row->>'min_qty')::numeric, 0),
      COALESCE((_row->>'opening_qty')::numeric, 0),
      _branch_id
    );
    _created := _created + 1;
    IF COALESCE((_row->>'opening_qty')::numeric,0) > 0 THEN _with_stock := _with_stock + 1; END IF;
  END LOOP;

  IF _created = 0 THEN RAISE EXCEPTION 'لا توجد أصناف صالحة للحفظ'; END IF;
  RETURN jsonb_build_object('created', _created, 'with_opening_stock', _with_stock);
END $$;

REVOKE ALL ON FUNCTION public.bulk_create_inventory_items(jsonb,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bulk_create_inventory_items(jsonb,uuid) TO authenticated, service_role;

-- 3) Safe hard delete of a single raw item with dependency guards
CREATE OR REPLACE FUNCTION public.delete_inventory_item(_item_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _company uuid := public.current_company_id(); _owner uuid; _name text;
        _recipes int; _mods int; _purchases int; _moves int;
BEGIN
  IF NOT (public.is_super_admin() OR public.has_permission('inventory.adjust')) THEN
    RAISE EXCEPTION 'غير مصرح لك بحذف أصناف المخزن';
  END IF;
  SELECT company_id, name INTO _owner, _name FROM public.inventory_items WHERE id = _item_id;
  IF _owner IS NULL OR _owner <> _company THEN RAISE EXCEPTION 'الصنف غير موجود'; END IF;

  SELECT count(*) INTO _recipes FROM public.product_recipes WHERE item_id = _item_id;
  SELECT count(*) INTO _mods FROM public.modifier_option_recipes WHERE item_id = _item_id;
  IF _recipes > 0 OR _mods > 0 THEN
    RAISE EXCEPTION 'لا يمكن حذف هذا الصنف لأنه مرتبط بوصفات منتجات حالية. قم بإزالته من الوصفات أولاً أو استخدم خيار التعطيل.';
  END IF;

  SELECT count(*) INTO _purchases FROM public.purchase_items WHERE item_id = _item_id;
  IF _purchases > 0 THEN
    RAISE EXCEPTION 'لا يمكن حذف هذا الصنف لأنه مستخدم في فواتير مشتريات مسجلة. استخدم خيار التعطيل.';
  END IF;

  DELETE FROM public.stock_movements WHERE item_id = _item_id;
  GET DIAGNOSTICS _moves = ROW_COUNT;
  DELETE FROM public.branch_stock WHERE item_id = _item_id;
  DELETE FROM public.inventory_items WHERE id = _item_id;

  PERFORM public.log_audit('inventory_item.delete','inventory','inventory_items',_item_id,NULL,
    jsonb_build_object('name',_name,'movements_deleted',_moves), NULL, NULL);
  RETURN jsonb_build_object('deleted', true, 'movements_deleted', _moves);
END $$;

REVOKE ALL ON FUNCTION public.delete_inventory_item(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_inventory_item(uuid) TO authenticated, service_role;

-- 4) Edit a manual stock movement and rebalance atomically
CREATE OR REPLACE FUNCTION public.edit_stock_movement(
  _movement_id uuid,
  _quantity numeric,
  _unit_cost numeric DEFAULT NULL,
  _reason text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _m record; _new numeric; _delta numeric; _bal numeric;
BEGIN
  IF NOT (public.is_super_admin() OR public.has_permission('inventory.adjust')) THEN
    RAISE EXCEPTION 'غير مصرح لك بتعديل حركات المخزن';
  END IF;
  IF _reason IS NULL OR btrim(_reason) = '' THEN RAISE EXCEPTION 'سبب التعديل مطلوب'; END IF;
  IF _quantity IS NULL OR _quantity <= 0 THEN RAISE EXCEPTION 'الكمية يجب أن تكون أكبر من صفر'; END IF;

  SELECT * INTO _m FROM public.stock_movements WHERE id = _movement_id;
  IF _m.id IS NULL OR _m.company_id <> public.current_company_id() THEN
    RAISE EXCEPTION 'الحركة غير موجودة';
  END IF;
  IF COALESCE(_m.reference_type,'manual') NOT IN ('manual','opening_balance') THEN
    RAISE EXCEPTION 'يمكن تعديل الحركات اليدوية فقط. الحركات الناتجة عن المبيعات أو المشتريات غير قابلة للتعديل.';
  END IF;

  _new := CASE WHEN _m.quantity < 0 THEN -abs(_quantity) ELSE abs(_quantity) END;
  _delta := _new - _m.quantity;

  IF _delta <> 0 THEN
    UPDATE public.branch_stock SET quantity = quantity + _delta, updated_at = now()
    WHERE item_id = _m.item_id AND branch_id = _m.branch_id
    RETURNING quantity INTO _bal;
    IF _bal IS NULL THEN RAISE EXCEPTION 'لا يوجد رصيد مسجل لهذا الصنف في هذا الفرع'; END IF;
    IF _bal < 0 THEN RAISE EXCEPTION 'التعديل يجعل الرصيد بالسالب'; END IF;

    UPDATE public.stock_movements SET balance_after = balance_after + _delta
    WHERE item_id = _m.item_id AND branch_id = _m.branch_id
      AND (created_at > _m.created_at OR (created_at = _m.created_at AND id = _m.id));
  END IF;

  UPDATE public.stock_movements
  SET quantity = _new,
      unit_cost = COALESCE(_unit_cost, unit_cost),
      reason = btrim(_reason)
  WHERE id = _movement_id;

  PERFORM public.log_audit('inventory.movement_edit','inventory','stock_movements',_movement_id,
    jsonb_build_object('quantity', _m.quantity, 'unit_cost', _m.unit_cost, 'reason', _m.reason),
    jsonb_build_object('movement_id', _movement_id, 'old_quantity', _m.quantity, 'new_quantity', _new,
      'delta', _delta, 'unit_cost', COALESCE(_unit_cost, _m.unit_cost), 'reason', btrim(_reason),
      'user_id', auth.uid()),
    btrim(_reason), _m.branch_id);

  RETURN jsonb_build_object('old_quantity', _m.quantity, 'new_quantity', _new, 'delta', _delta);
END $$;

REVOKE ALL ON FUNCTION public.edit_stock_movement(uuid,numeric,numeric,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.edit_stock_movement(uuid,numeric,numeric,text) TO authenticated, service_role;