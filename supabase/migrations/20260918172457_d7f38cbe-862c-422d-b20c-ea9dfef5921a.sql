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

  -- Setup-time cleanup: stock ledger rows are append-only for operations,
  -- so disable the guard triggers for this statement only.
  SET LOCAL session_replication_role = 'replica';

  DELETE FROM public.stock_movements WHERE item_id = _item_id;
  GET DIAGNOSTICS _moves = ROW_COUNT;
  DELETE FROM public.branch_stock WHERE item_id = _item_id;
  DELETE FROM public.inventory_items WHERE id = _item_id;

  SET LOCAL session_replication_role = 'origin';

  PERFORM public.log_audit('inventory_item.delete','inventory','inventory_items',_item_id,NULL,
    jsonb_build_object('name',_name,'movements_deleted',_moves), NULL, NULL);
  RETURN jsonb_build_object('deleted', true, 'movements_deleted', _moves);
END $$;

CREATE OR REPLACE FUNCTION public.wipe_all_raw_materials()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  _company uuid := public.current_company_id();
  _items uuid[];
  _count int := 0;
  _moves int := 0;
  _recipes int := 0;
  _mod_recipes int := 0;
BEGIN
  IF _company IS NULL THEN RAISE EXCEPTION 'No company context'; END IF;
  IF NOT (public.is_super_admin() OR public.has_permission('inventory.adjust')) THEN
    RAISE EXCEPTION 'غير مصرح لك بحذف خامات المخزن';
  END IF;

  SELECT array_agg(id) INTO _items FROM public.inventory_items WHERE company_id = _company;
  IF _items IS NULL OR array_length(_items, 1) = 0 THEN
    RETURN jsonb_build_object('items_deleted', 0, 'recipes_deleted', 0,
      'modifier_recipes_deleted', 0, 'movements_deleted', 0);
  END IF;
  _count := array_length(_items, 1);

  SET LOCAL session_replication_role = 'replica';

  DELETE FROM public.modifier_option_recipes WHERE item_id = ANY(_items);
  GET DIAGNOSTICS _mod_recipes = ROW_COUNT;

  DELETE FROM public.product_recipes WHERE item_id = ANY(_items);
  GET DIAGNOSTICS _recipes = ROW_COUNT;

  DELETE FROM public.purchase_return_items WHERE item_id = ANY(_items);
  DELETE FROM public.purchase_items WHERE item_id = ANY(_items);

  DELETE FROM public.stock_movements WHERE item_id = ANY(_items);
  GET DIAGNOSTICS _moves = ROW_COUNT;

  DELETE FROM public.branch_stock WHERE item_id = ANY(_items);
  DELETE FROM public.inventory_items WHERE id = ANY(_items);

  SET LOCAL session_replication_role = 'origin';

  PERFORM public.log_audit('WIPE_ALL_RAW_MATERIALS','inventory','inventory_items',NULL,NULL,
    jsonb_build_object('wiped_by', auth.uid(), 'timestamp', now(), 'items_deleted', _count,
      'recipes_deleted', _recipes, 'modifier_recipes_deleted', _mod_recipes,
      'movements_deleted', _moves), NULL, NULL);

  RETURN jsonb_build_object('items_deleted', _count, 'recipes_deleted', _recipes,
    'modifier_recipes_deleted', _mod_recipes, 'movements_deleted', _moves);
END $$;

REVOKE ALL ON FUNCTION public.delete_inventory_item(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_inventory_item(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.wipe_all_raw_materials() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.wipe_all_raw_materials() TO authenticated, service_role;