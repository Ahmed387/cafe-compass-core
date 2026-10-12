CREATE OR REPLACE FUNCTION public.wipe_all_raw_materials()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _company uuid := public.current_company_id();
  _items uuid[];
  _count int := 0;
  _moves int := 0;
  _recipes int := 0;
  _mod_recipes int := 0;
BEGIN
  IF _company IS NULL THEN
    RAISE EXCEPTION 'No company context';
  END IF;
  IF NOT (public.is_super_admin() OR public.has_permission('inventory.adjust')) THEN
    RAISE EXCEPTION 'غير مصرح لك بحذف خامات المخزن';
  END IF;

  SELECT array_agg(id) INTO _items FROM public.inventory_items WHERE company_id = _company;
  IF _items IS NULL OR array_length(_items, 1) = 0 THEN
    RETURN jsonb_build_object('items_deleted', 0, 'recipes_deleted', 0,
      'modifier_recipes_deleted', 0, 'movements_deleted', 0);
  END IF;
  _count := array_length(_items, 1);

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

  PERFORM public.log_audit(
    'WIPE_ALL_RAW_MATERIALS',
    'inventory',
    'inventory_items',
    NULL,
    NULL,
    jsonb_build_object(
      'wiped_by', auth.uid(),
      'timestamp', now(),
      'items_deleted', _count,
      'recipes_deleted', _recipes,
      'modifier_recipes_deleted', _mod_recipes,
      'movements_deleted', _moves
    ),
    NULL,
    NULL
  );

  RETURN jsonb_build_object(
    'items_deleted', _count,
    'recipes_deleted', _recipes,
    'modifier_recipes_deleted', _mod_recipes,
    'movements_deleted', _moves
  );
END;
$$;

REVOKE ALL ON FUNCTION public.wipe_all_raw_materials() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.wipe_all_raw_materials() TO authenticated, service_role;
