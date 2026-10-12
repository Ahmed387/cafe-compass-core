CREATE OR REPLACE FUNCTION public.inventory_item_usage(_item_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE _company uuid := public.current_company_id(); _owner uuid;
        _products jsonb; _mods jsonb; _purchases int;
BEGIN
  IF NOT (public.is_super_admin() OR public.has_permission('inventory.adjust')) THEN
    RAISE EXCEPTION 'غير مصرح لك بعرض ارتباطات أصناف المخزن';
  END IF;
  SELECT company_id INTO _owner FROM public.inventory_items WHERE id = _item_id;
  IF _owner IS NULL OR _owner <> _company THEN RAISE EXCEPTION 'الصنف غير موجود'; END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'name_ar', p.name_ar)), '[]'::jsonb)
    INTO _products
  FROM public.product_recipes r JOIN public.products p ON p.id = r.product_id
  WHERE r.item_id = _item_id;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'name_ar', o.name_ar)), '[]'::jsonb)
    INTO _mods
  FROM public.modifier_option_recipes mr JOIN public.modifier_options o ON o.id = mr.option_id
  WHERE mr.item_id = _item_id;

  SELECT count(*) INTO _purchases FROM public.purchase_items WHERE item_id = _item_id;

  RETURN jsonb_build_object('products', _products, 'modifiers', _mods, 'purchase_lines', _purchases);
END $function$;

REVOKE ALL ON FUNCTION public.inventory_item_usage(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.inventory_item_usage(uuid) TO authenticated, service_role;

DROP FUNCTION IF EXISTS public.delete_inventory_item(uuid);

CREATE OR REPLACE FUNCTION public.delete_inventory_item(_item_id uuid, _unlink_recipes boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
  IF (_recipes > 0 OR _mods > 0) AND NOT _unlink_recipes THEN
    RAISE EXCEPTION 'لا يمكن حذف هذا الصنف لأنه مرتبط بوصفات منتجات حالية. قم بإزالته من الوصفات أولاً أو استخدم خيار التعطيل.';
  END IF;

  SELECT count(*) INTO _purchases FROM public.purchase_items WHERE item_id = _item_id;
  IF _purchases > 0 THEN
    RAISE EXCEPTION 'لا يمكن حذف هذا الصنف لأنه مستخدم في فواتير مشتريات مسجلة. استخدم خيار التعطيل.';
  END IF;

  -- Setup-time cleanup: stock ledger rows are append-only for operations,
  -- so disable the guard triggers for this statement only.
  SET LOCAL session_replication_role = 'replica';

  IF _unlink_recipes THEN
    DELETE FROM public.product_recipes WHERE item_id = _item_id;
    DELETE FROM public.modifier_option_recipes WHERE item_id = _item_id;
  END IF;

  DELETE FROM public.stock_movements WHERE item_id = _item_id;
  GET DIAGNOSTICS _moves = ROW_COUNT;
  DELETE FROM public.branch_stock WHERE item_id = _item_id;
  DELETE FROM public.inventory_items WHERE id = _item_id;

  SET LOCAL session_replication_role = 'origin';

  PERFORM public.log_audit('inventory_item.delete','inventory','inventory_items',_item_id,NULL,
    jsonb_build_object('name',_name,'movements_deleted',_moves,'recipe_lines_unlinked',_recipes,'modifier_lines_unlinked',_mods), NULL, NULL);
  RETURN jsonb_build_object('deleted', true, 'movements_deleted', _moves,
    'recipe_lines_unlinked', _recipes, 'modifier_lines_unlinked', _mods);
END $function$;

REVOKE ALL ON FUNCTION public.delete_inventory_item(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_inventory_item(uuid, boolean) TO authenticated, service_role;