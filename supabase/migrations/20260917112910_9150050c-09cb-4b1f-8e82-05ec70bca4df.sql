-- 1) Revoke report permissions from the partner role (financial isolation).
DELETE FROM public.role_permissions rp
USING public.roles r, public.permissions p
WHERE rp.role_id = r.id
  AND rp.permission_id = p.id
  AND r.key = 'partner'
  AND p.key IN ('reports.sales','reports.profit','reports.partners','reports.inventory','reports.payroll','reports.expenses','reports.cashier');

-- 2) Hard-block sales for base products without a stock recipe.
CREATE OR REPLACE FUNCTION public.check_order_stock(_branch_id uuid, _items jsonb)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _item jsonb; _mod jsonb; _r record; _needed jsonb := '{}'::jsonb; _key text; _qty numeric; _pid uuid; _pname text;
BEGIN
  FOR _item IN SELECT * FROM jsonb_array_elements(COALESCE(_items,'[]'::jsonb)) LOOP
    _pid := NULLIF(_item->>'product_id','')::uuid;

    IF _pid IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.product_recipes pr WHERE pr.product_id = _pid
    ) THEN
      SELECT COALESCE(p.name_ar, p.name) INTO _pname FROM public.products p WHERE p.id = _pid;
      RAISE EXCEPTION 'RECIPE_MISSING: % — هذا المنتج بدون وصفة مخزنية، يرجى إضافة الوصفة أولاً من صفحة المخزون', COALESCE(_pname,'');
    END IF;

    FOR _r IN
      SELECT pr.item_id, pr.quantity * COALESCE((_item->>'quantity')::numeric,0) AS need
      FROM public.product_recipes pr
      WHERE pr.product_id = _pid
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

-- 3) Public QR menu hides products that cannot be sold (no recipe).
CREATE OR REPLACE FUNCTION public.public_menu(_branch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _company_id uuid;
  _result jsonb;
BEGIN
  SELECT b.company_id INTO _company_id
  FROM public.branches b
  JOIN public.companies c ON c.id = b.company_id
  WHERE b.id = _branch_id AND b.is_active AND c.is_active;

  IF _company_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT jsonb_build_object(
    'company', (
      SELECT jsonb_build_object('name', c.name, 'logo_url', c.logo_url, 'currency', c.currency, 'default_language', c.default_language)
      FROM public.companies c WHERE c.id = _company_id
    ),
    'branch', (
      SELECT jsonb_build_object('id', b.id, 'name', b.name, 'address', b.address, 'phone', b.phone)
      FROM public.branches b WHERE b.id = _branch_id
    ),
    'categories', COALESCE((
      SELECT jsonb_agg(cat ORDER BY cat->>'display_order', cat->>'name')
      FROM (
        SELECT jsonb_build_object(
          'id', cg.id,
          'name', cg.name,
          'name_ar', cg.name_ar,
          'display_order', cg.display_order,
          'products', COALESCE((
            SELECT jsonb_agg(prod ORDER BY prod->>'display_order', prod->>'name')
            FROM (
              SELECT jsonb_build_object(
                'id', p.id,
                'name', p.name,
                'name_ar', p.name_ar,
                'description', p.description,
                'image_url', p.image_url,
                'display_order', p.display_order,
                'price', COALESCE(pbs.price_override, p.base_price),
                'sizes', COALESCE((
                  SELECT jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'name_ar', s.name_ar, 'price_delta', s.price_delta)
                                   ORDER BY s.display_order, s.name)
                  FROM public.product_sizes s
                  WHERE s.product_id = p.id AND s.is_active
                ), '[]'::jsonb)
              ) AS prod
              FROM public.products p
              LEFT JOIN public.product_branch_settings pbs
                ON pbs.product_id = p.id AND pbs.branch_id = _branch_id
              WHERE p.category_id = cg.id
                AND p.is_active AND p.is_available
                AND COALESCE(pbs.is_available, true)
                AND EXISTS (SELECT 1 FROM public.product_recipes pr WHERE pr.product_id = p.id)
            ) prods
          ), '[]'::jsonb)
        ) AS cat
        FROM public.categories cg
        WHERE cg.company_id = _company_id AND cg.is_active
      ) cats
      WHERE jsonb_array_length(cat->'products') > 0
    ), '[]'::jsonb)
  ) INTO _result;

  RETURN _result;
END;
$function$;

-- 4) Inventory consumption & valuation report, owner/manager only.
CREATE OR REPLACE FUNCTION public.inventory_cogs_report(_branch_id uuid, _from date, _to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _company_id uuid; _rows jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;

  IF NOT (
    public.is_super_admin() OR EXISTS (
      SELECT 1 FROM public.user_profiles up
      JOIN public.user_roles ur ON ur.user_id = up.id
      JOIN public.roles r ON r.id = ur.role_id
      WHERE up.auth_user_id = auth.uid() AND up.is_active AND r.key = 'manager'
    )
  ) THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  _company_id := public.current_company_id();

  SELECT COALESCE(jsonb_agg(row ORDER BY row->>'name'), '[]'::jsonb) INTO _rows
  FROM (
    SELECT jsonb_build_object(
      'item_id', i.id,
      'name', i.name,
      'name_ar', i.name_ar,
      'unit', i.unit,
      'unit_cost', i.cost_per_unit,
      'on_hand', COALESCE(bs.quantity, 0),
      'valuation', ROUND(COALESCE(bs.quantity,0) * i.cost_per_unit, 2),
      'min_qty', i.min_qty,
      'consumed_qty', COALESCE(m.sold_qty, 0),
      'consumed_cost', ROUND(COALESCE(m.sold_cost, 0), 2),
      'waste_qty', COALESCE(m.waste_qty, 0),
      'adjust_qty', COALESCE(m.adjust_qty, 0)
    ) AS row
    FROM public.inventory_items i
    LEFT JOIN public.branch_stock bs
      ON bs.item_id = i.id AND bs.branch_id = _branch_id
    LEFT JOIN (
      SELECT sm.item_id,
        SUM(CASE WHEN sm.movement_type = 'sale_consumption' THEN ABS(sm.quantity) ELSE 0 END) AS sold_qty,
        SUM(CASE WHEN sm.movement_type = 'sale_consumption' THEN ABS(sm.quantity) * COALESCE(sm.unit_cost,0) ELSE 0 END) AS sold_cost,
        SUM(CASE WHEN sm.movement_type = 'waste' THEN ABS(sm.quantity) ELSE 0 END) AS waste_qty,
        SUM(CASE WHEN sm.movement_type = 'adjustment' THEN sm.quantity ELSE 0 END) AS adjust_qty
      FROM public.stock_movements sm
      WHERE sm.branch_id = _branch_id
        AND sm.created_at >= _from::timestamptz
        AND sm.created_at < (_to + 1)::timestamptz
      GROUP BY sm.item_id
    ) m ON m.item_id = i.id
    WHERE i.company_id = _company_id AND i.is_active
  ) s;

  RETURN jsonb_build_object(
    'from', _from,
    'to', _to,
    'items', _rows,
    'total_valuation', (SELECT COALESCE(SUM((v->>'valuation')::numeric),0) FROM jsonb_array_elements(_rows) v),
    'total_consumed_cost', (SELECT COALESCE(SUM((v->>'consumed_cost')::numeric),0) FROM jsonb_array_elements(_rows) v)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.inventory_cogs_report(uuid, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.inventory_cogs_report(uuid, date, date) TO authenticated, service_role;

-- 5) Linking modifier groups to products is an owner-only catalog mutation.
DROP POLICY IF EXISTS pmg_insert ON public.product_modifier_groups;
CREATE POLICY pmg_insert ON public.product_modifier_groups
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.products p WHERE p.id = product_id AND p.company_id = public.current_company_id())
    AND public.is_super_admin()
  );

DROP POLICY IF EXISTS pmg_delete ON public.product_modifier_groups;
CREATE POLICY pmg_delete ON public.product_modifier_groups
  FOR DELETE TO authenticated
  USING (
    EXISTS (SELECT 1 FROM public.products p WHERE p.id = product_id AND p.company_id = public.current_company_id())
    AND public.is_super_admin()
  );