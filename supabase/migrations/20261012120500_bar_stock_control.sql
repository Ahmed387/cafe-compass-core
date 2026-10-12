-- =====================================================================
-- Core re-architecture 6/6 — bar stock control
--   Sales consume from the bar. A sale may no longer push the bar below
--   zero silently (which used to borrow from the main warehouse unseen).
--   A cashier override (begin_stock_override, 5 minutes, audited) still
--   allows the sale, and managers get an explicit "bar negative" alert.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.apply_stock_movement(_branch_id uuid, _item_id uuid, _type stock_movement_type,
  _qty numeric, _unit_cost numeric DEFAULT NULL::numeric, _reason text DEFAULT NULL::text,
  _reference_type text DEFAULT NULL::text, _reference_id uuid DEFAULT NULL::uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE _company uuid; _profile uuid := public.current_profile_id(); _bal numeric; _bar numeric; _cost numeric;
  _mv uuid; _min numeric; _barmin numeric; _name text; _recent boolean; _override boolean;
  _loc text := CASE WHEN _type IN ('sale_consumption', 'sale_return') THEN 'bar' ELSE 'main' END;
BEGIN
  SELECT i.company_id, COALESCE(_unit_cost, i.cost_per_unit), i.min_qty, i.bar_min_qty, COALESCE(i.name_ar, i.name)
    INTO _company, _cost, _min, _barmin, _name
    FROM public.inventory_items i WHERE i.id = _item_id;
  IF _company IS NULL THEN RAISE EXCEPTION 'Inventory item not found'; END IF;

  INSERT INTO public.branch_stock (item_id, branch_id, quantity, bar_quantity)
  VALUES (_item_id, _branch_id, _qty, CASE WHEN _loc = 'bar' THEN _qty ELSE 0 END)
  ON CONFLICT (item_id, branch_id) DO UPDATE SET
    quantity = public.branch_stock.quantity + _qty,
    bar_quantity = CASE WHEN _loc = 'bar' THEN public.branch_stock.bar_quantity + _qty
                        ELSE LEAST(public.branch_stock.bar_quantity, public.branch_stock.quantity + _qty) END,
    updated_at = now()
  RETURNING quantity, bar_quantity INTO _bal, _bar;

  _override := _type = 'sale_consumption' AND EXISTS (
    SELECT 1 FROM public.stock_overrides o
     WHERE o.profile_id = _profile AND o.branch_id = _branch_id AND o.expires_at > now());

  IF _bal < 0 AND NOT _override THEN
    RAISE EXCEPTION 'Not enough stock available for %', _name;
  END IF;
  -- The bar itself must cover a sale. Main-warehouse stock has to be transferred first.
  IF _loc = 'bar' AND _qty < 0 AND _bar < 0 AND NOT _override THEN
    RAISE EXCEPTION 'رصيد البار من "%" مش كفاية (البار: %، المخزن الرئيسي: %). حوّل من المخزن الأول.',
      _name, round(_bar - _qty, 3), round(_bal - _bar, 3);
  END IF;

  INSERT INTO public.stock_movements (company_id, branch_id, item_id, movement_type, quantity, unit_cost,
    balance_after, reference_type, reference_id, reason, created_by, location)
  VALUES (_company, _branch_id, _item_id, _type, _qty, COALESCE(_cost, 0),
    _bal, _reference_type, _reference_id, _reason, _profile, _loc)
  RETURNING id INTO _mv;

  -- Negative bar after an override: always alert, the count is now wrong until a transfer.
  IF _loc = 'bar' AND _bar < 0 THEN
    INSERT INTO public.notifications (company_id, branch_id, required_permission, type, severity, title, body, data)
    VALUES (_company, _branch_id, 'inventory.view', 'inventory.bar_negative', 'critical',
      'البار بالسالب: ' || _name,
      'اتباع بتجاوز للمخزون والبار بقى ' || round(_bar, 3)::text || '. اعمل تحويل من المخزن الرئيسي.',
      jsonb_build_object('item_id', _item_id, 'bar_quantity', _bar, 'quantity', _bal, 'movement_id', _mv));
  ELSIF _qty < 0 AND (_bal <= _min OR (_loc = 'bar' AND _bar <= _barmin)) THEN
    SELECT EXISTS (SELECT 1 FROM public.notifications n
      WHERE n.company_id = _company AND n.type = 'inventory.low_stock'
        AND COALESCE(n.branch_id, _branch_id) = _branch_id
        AND (n.data->>'item_id')::uuid = _item_id
        AND (n.read_at IS NULL OR n.created_at > now() - interval '6 hours')) INTO _recent;
    IF NOT _recent THEN
      INSERT INTO public.notifications (company_id, branch_id, required_permission, type, severity, title, body, data)
      VALUES (_company, _branch_id, 'inventory.view', 'inventory.low_stock', 'warning',
        CASE WHEN _loc = 'bar' AND _bar <= _barmin THEN 'اطلب من المخزن الرئيسي: ' ELSE 'المخزون قرب يخلص: ' END || _name,
        'البار: ' || round(_bar, 3)::text || ' / الإجمالي: ' || round(_bal, 3)::text,
        jsonb_build_object('item_id', _item_id, 'quantity', _bal, 'bar_quantity', _bar, 'min_qty', _min, 'bar_min_qty', _barmin));
    END IF;
  END IF;
  RETURN _mv;
END $function$;

-- Bar items at/below the reorder level, plus anything already negative.
CREATE OR REPLACE FUNCTION public.bar_low_stock(_branch_id uuid)
RETURNS TABLE(item_id uuid, name text, unit text, bar_qty numeric, bar_min numeric, product_ids uuid[])
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT i.id, COALESCE(i.name_ar, i.name), i.unit, COALESCE(bs.bar_quantity, 0), COALESCE(i.bar_min_qty, 0),
         COALESCE((SELECT array_agg(DISTINCT r.product_id) FROM public.product_recipes r WHERE r.item_id = i.id), '{}')
  FROM public.inventory_items i
  LEFT JOIN public.branch_stock bs ON bs.item_id = i.id AND bs.branch_id = _branch_id
  WHERE i.company_id = public.current_company_id() AND i.is_active
    AND (COALESCE(bs.bar_quantity, 0) < 0
         OR (COALESCE(i.bar_min_qty, 0) > 0 AND COALESCE(bs.bar_quantity, 0) <= i.bar_min_qty))
    AND public.can_access_branch(_branch_id)
    AND (public.has_permission('inventory.view') OR public.has_permission('pos.create_order') OR public.is_super_admin())
  ORDER BY COALESCE(bs.bar_quantity, 0) < 0 DESC, 2;
$$;
REVOKE EXECUTE ON FUNCTION public.bar_low_stock(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bar_low_stock(uuid) TO authenticated;
