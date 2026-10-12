CREATE OR REPLACE FUNCTION public.apply_stock_movement(_branch_id uuid, _item_id uuid, _type stock_movement_type, _qty numeric, _unit_cost numeric DEFAULT NULL::numeric, _reason text DEFAULT NULL::text, _reference_type text DEFAULT NULL::text, _reference_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _company uuid; _profile uuid := public.current_profile_id(); _bal numeric; _cost numeric; _mv uuid; _min numeric; _name text; _recent boolean;
BEGIN
  SELECT i.company_id, COALESCE(_unit_cost, i.cost_per_unit), i.min_qty, i.name
    INTO _company, _cost, _min, _name
  FROM public.inventory_items i WHERE i.id = _item_id;
  IF _company IS NULL THEN RAISE EXCEPTION 'Inventory item not found'; END IF;

  INSERT INTO public.branch_stock (item_id, branch_id, quantity)
  VALUES (_item_id, _branch_id, _qty)
  ON CONFLICT (item_id, branch_id) DO UPDATE SET quantity = public.branch_stock.quantity + _qty, updated_at = now()
  RETURNING quantity INTO _bal;

  IF _bal < 0 THEN
    RAISE EXCEPTION 'Not enough stock available for %', _name;
  END IF;

  INSERT INTO public.stock_movements (company_id, branch_id, item_id, movement_type, quantity, unit_cost,
    balance_after, reference_type, reference_id, reason, created_by)
  VALUES (_company, _branch_id, _item_id, _type, _qty, COALESCE(_cost,0), _bal, _reference_type, _reference_id, _reason, _profile)
  RETURNING id INTO _mv;

  IF _bal <= _min AND _qty < 0 THEN
    SELECT EXISTS (
      SELECT 1 FROM public.notifications n
      WHERE n.company_id = _company
        AND n.type = 'inventory.low_stock'
        AND COALESCE(n.branch_id, _branch_id) = _branch_id
        AND (n.data->>'item_id')::uuid = _item_id
        AND (n.read_at IS NULL OR n.created_at > now() - interval '6 hours')
    ) INTO _recent;

    IF NOT _recent THEN
      INSERT INTO public.notifications (company_id, branch_id, required_permission, type, severity, title, body, data)
      VALUES (_company, _branch_id, 'inventory.view', 'inventory.low_stock', 'warning',
        'Low stock: ' || _name, 'Remaining quantity: ' || _bal::text,
        jsonb_build_object('item_id', _item_id, 'quantity', _bal, 'min_qty', _min));
    END IF;
  END IF;
  RETURN _mv;
END $function$;