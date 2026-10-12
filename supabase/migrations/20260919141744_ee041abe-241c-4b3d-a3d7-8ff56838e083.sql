CREATE OR REPLACE FUNCTION public.save_product_recipe(_product_id uuid, _lines jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _company uuid := public.current_company_id();
  _line jsonb;
  _item uuid;
  _qty numeric;
  _count int := 0;
  _total numeric := 0;
BEGIN
  IF NOT (public.is_super_admin() OR public.has_permission('inventory.adjust')) THEN
    RAISE EXCEPTION 'ليست لديك صلاحية لتعديل الوصفات.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.products p
    WHERE p.id = _product_id AND p.company_id = _company
  ) THEN
    RAISE EXCEPTION 'المنتج غير موجود.';
  END IF;

  DELETE FROM public.product_recipes WHERE product_id = _product_id;

  FOR _line IN SELECT * FROM jsonb_array_elements(COALESCE(_lines, '[]'::jsonb))
  LOOP
    _item := NULLIF(_line->>'item_id', '')::uuid;
    _qty := COALESCE((_line->>'quantity')::numeric, 0);
    IF _item IS NULL OR _qty <= 0 THEN
      CONTINUE;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.inventory_items i
      WHERE i.id = _item AND i.company_id = _company
    ) THEN
      RAISE EXCEPTION 'أحد المكونات غير موجود في المخزن.';
    END IF;

    INSERT INTO public.product_recipes (product_id, item_id, quantity, created_by)
    VALUES (_product_id, _item, _qty, public.current_profile_id())
    ON CONFLICT DO NOTHING;

    _count := _count + 1;
    _total := _total + _qty * COALESCE(
      (SELECT i.cost_per_unit FROM public.inventory_items i WHERE i.id = _item), 0);
  END LOOP;

  UPDATE public.products
  SET cost = round(_total, 4)
  WHERE id = _product_id;

  PERFORM public.log_audit(
    'product_recipe.save',
    'products',
    _product_id,
    NULL,
    jsonb_build_object('lines', _count, 'unit_cost', round(_total, 4))
  );

  RETURN jsonb_build_object('lines', _count, 'unit_cost', round(_total, 4));
END;
$$;

REVOKE ALL ON FUNCTION public.save_product_recipe(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_product_recipe(uuid, jsonb) TO authenticated, service_role;