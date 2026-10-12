CREATE OR REPLACE FUNCTION public.save_product_studio(_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  _company uuid := public.current_company_id();
  _profile uuid := public.current_profile_id();
  _product_id uuid := NULLIF(_payload->>'id', '')::uuid;
  _category_id uuid := NULLIF(_payload->>'category_id', '')::uuid;
  _new_category text := NULLIF(trim(_payload->>'new_category'), '');
  _new_category_ar text := NULLIF(trim(_payload->>'new_category_ar'), '');
  _name text := NULLIF(trim(_payload->>'name'), '');
  _name_ar text := NULLIF(trim(_payload->>'name_ar'), '');
  _price numeric := COALESCE((_payload->>'base_price')::numeric, 0);
  _image text := NULLIF(_payload->>'image_url', '');
  _group jsonb;
  _option jsonb;
  _group_id uuid;
  _option_id uuid;
  _keep_groups uuid[] := '{}';
  _keep_options uuid[];
  _dead uuid;
  _item uuid;
  _qty numeric;
  _order int;
  _opt_order int;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.is_super_admin()
          OR public.has_permission('products.update')
          OR public.has_permission('products.create')) THEN
    RAISE EXCEPTION 'ليست لديك صلاحية لتعديل المنتجات.';
  END IF;

  IF _name IS NULL AND _name_ar IS NULL THEN
    RAISE EXCEPTION 'اسم المنتج مطلوب.';
  END IF;
  _name := COALESCE(_name, _name_ar);

  -- Inline category creation
  IF _new_category IS NOT NULL OR _new_category_ar IS NOT NULL THEN
    INSERT INTO public.categories (company_id, name, name_ar, display_order)
    VALUES (
      _company,
      COALESCE(_new_category, _new_category_ar),
      _new_category_ar,
      COALESCE((SELECT max(display_order) + 1 FROM public.categories WHERE company_id = _company), 1)
    )
    RETURNING id INTO _category_id;
  ELSIF _category_id IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM public.categories c WHERE c.id = _category_id AND c.company_id = _company) THEN
      RAISE EXCEPTION 'التصنيف غير موجود.';
    END IF;
  END IF;

  -- Product upsert
  IF _product_id IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM public.products p WHERE p.id = _product_id AND p.company_id = _company) THEN
      RAISE EXCEPTION 'المنتج غير موجود.';
    END IF;
    UPDATE public.products
    SET name = _name,
        name_ar = _name_ar,
        category_id = _category_id,
        base_price = _price,
        image_url = COALESCE(_image, image_url),
        updated_at = now()
    WHERE id = _product_id;
    IF _image IS NULL AND (_payload ? 'image_url') AND _payload->>'image_url' IS NULL THEN
      UPDATE public.products SET image_url = NULL WHERE id = _product_id;
    END IF;
  ELSE
    INSERT INTO public.products (company_id, category_id, name, name_ar, base_price, image_url, display_order, created_by)
    VALUES (
      _company, _category_id, _name, _name_ar, _price, _image,
      COALESCE((SELECT max(display_order) + 1 FROM public.products WHERE company_id = _company), 1),
      _profile
    )
    RETURNING id INTO _product_id;
  END IF;

  -- Recipe (also recomputes products.cost)
  PERFORM public.save_product_recipe(_product_id, COALESCE(_payload->'recipe', '[]'::jsonb));

  -- Modifier groups / options / their stock deductions
  FOR _group IN SELECT * FROM jsonb_array_elements(COALESCE(_payload->'modifier_groups', '[]'::jsonb))
  LOOP
    _group_id := NULLIF(_group->>'id', '')::uuid;
    IF _group_id IS NOT NULL THEN
      IF NOT EXISTS (SELECT 1 FROM public.modifier_groups g WHERE g.id = _group_id AND g.company_id = _company) THEN
        RAISE EXCEPTION 'مجموعة الإضافات غير موجودة.';
      END IF;
      UPDATE public.modifier_groups
      SET name = COALESCE(NULLIF(trim(_group->>'name'), ''), name),
          name_ar = COALESCE(NULLIF(trim(_group->>'name_ar'), ''), name_ar),
          min_select = COALESCE((_group->>'min_select')::int, min_select),
          max_select = COALESCE((_group->>'max_select')::int, max_select),
          is_active = true,
          updated_at = now()
      WHERE id = _group_id;
    ELSE
      IF COALESCE(NULLIF(trim(_group->>'name'), ''), NULLIF(trim(_group->>'name_ar'), '')) IS NULL THEN
        CONTINUE;
      END IF;
      SELECT COALESCE(max(display_order) + 1, 1) INTO _order
      FROM public.modifier_groups WHERE company_id = _company;
      INSERT INTO public.modifier_groups (company_id, name, name_ar, min_select, max_select, display_order)
      VALUES (
        _company,
        COALESCE(NULLIF(trim(_group->>'name'), ''), trim(_group->>'name_ar')),
        NULLIF(trim(_group->>'name_ar'), ''),
        COALESCE((_group->>'min_select')::int, 0),
        COALESCE((_group->>'max_select')::int, 1),
        _order
      )
      RETURNING id INTO _group_id;
    END IF;

    _keep_groups := _keep_groups || _group_id;

    INSERT INTO public.product_modifier_groups (product_id, group_id)
    VALUES (_product_id, _group_id)
    ON CONFLICT DO NOTHING;

    _keep_options := '{}';
    _opt_order := 0;
    FOR _option IN SELECT * FROM jsonb_array_elements(COALESCE(_group->'options', '[]'::jsonb))
    LOOP
      _opt_order := _opt_order + 1;
      _option_id := NULLIF(_option->>'id', '')::uuid;
      IF COALESCE(NULLIF(trim(_option->>'name'), ''), NULLIF(trim(_option->>'name_ar'), '')) IS NULL THEN
        CONTINUE;
      END IF;

      IF _option_id IS NOT NULL THEN
        UPDATE public.modifier_options
        SET name = COALESCE(NULLIF(trim(_option->>'name'), ''), trim(_option->>'name_ar')),
            name_ar = NULLIF(trim(_option->>'name_ar'), ''),
            price_delta = COALESCE((_option->>'price_delta')::numeric, 0),
            display_order = _opt_order,
            is_active = true,
            updated_at = now()
        WHERE id = _option_id AND group_id = _group_id;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'أحد خيارات الإضافات غير موجود.';
        END IF;
      ELSE
        INSERT INTO public.modifier_options (group_id, name, name_ar, price_delta, display_order)
        VALUES (
          _group_id,
          COALESCE(NULLIF(trim(_option->>'name'), ''), trim(_option->>'name_ar')),
          NULLIF(trim(_option->>'name_ar'), ''),
          COALESCE((_option->>'price_delta')::numeric, 0),
          _opt_order
        )
        RETURNING id INTO _option_id;
      END IF;

      _keep_options := _keep_options || _option_id;

      -- One raw material deduction per option
      _item := NULLIF(_option->>'item_id', '')::uuid;
      _qty := COALESCE((_option->>'quantity')::numeric, 0);
      DELETE FROM public.modifier_option_recipes WHERE option_id = _option_id;
      IF _item IS NOT NULL AND _qty > 0 THEN
        IF NOT EXISTS (SELECT 1 FROM public.inventory_items i WHERE i.id = _item AND i.company_id = _company) THEN
          RAISE EXCEPTION 'إحدى خامات الإضافات غير موجودة في المخزن.';
        END IF;
        INSERT INTO public.modifier_option_recipes (option_id, item_id, quantity, created_by)
        VALUES (_option_id, _item, _qty, _profile);
      END IF;
    END LOOP;

    -- Options the user removed in the studio
    FOR _dead IN
      SELECT o.id FROM public.modifier_options o
      WHERE o.group_id = _group_id AND NOT (o.id = ANY(_keep_options))
    LOOP
      PERFORM public.delete_modifier_option(_dead);
    END LOOP;
  END LOOP;

  DELETE FROM public.product_modifier_groups
  WHERE product_id = _product_id AND NOT (group_id = ANY(_keep_groups));

  PERFORM public.log_audit(
    _action => CASE WHEN (_payload ? 'id') AND NULLIF(_payload->>'id','') IS NOT NULL
                    THEN 'product.studio_update' ELSE 'product.studio_create' END,
    _module => 'products',
    _entity_type => 'products',
    _entity_id => _product_id,
    _old_values => NULL,
    _new_values => jsonb_build_object(
      'name', _name,
      'category_id', _category_id,
      'base_price', _price,
      'recipe_lines', jsonb_array_length(COALESCE(_payload->'recipe', '[]'::jsonb)),
      'modifier_groups', jsonb_array_length(COALESCE(_payload->'modifier_groups', '[]'::jsonb))
    )
  );

  RETURN jsonb_build_object(
    'product_id', _product_id,
    'category_id', _category_id,
    'cost', (SELECT cost FROM public.products WHERE id = _product_id)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.save_product_studio(jsonb) FROM public;
GRANT EXECUTE ON FUNCTION public.save_product_studio(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_product_studio(jsonb) TO service_role;