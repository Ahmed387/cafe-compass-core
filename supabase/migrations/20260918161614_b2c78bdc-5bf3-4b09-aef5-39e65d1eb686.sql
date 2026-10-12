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
    RETURN jsonb_build_object('items_deleted', 0);
  END IF;
  _count := array_length(_items, 1);

  DELETE FROM public.modifier_option_recipes WHERE item_id = ANY(_items);
  _mod_recipes := ROW_COUNT_HACK();
  RETURN NULL;
END;
$$;
