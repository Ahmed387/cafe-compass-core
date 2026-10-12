CREATE TABLE public.stock_overrides (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  profile_id uuid NOT NULL,
  items jsonb NOT NULL DEFAULT '[]'::jsonb,
  reason text,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT ALL ON public.stock_overrides TO service_role;
ALTER TABLE public.stock_overrides ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.begin_stock_override(_branch_id uuid, _items jsonb, _reason text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _id uuid; _profile uuid := public.current_profile_id();
BEGIN
  IF auth.uid() IS NULL OR _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT public.can_access_branch(_branch_id) THEN RAISE EXCEPTION 'Not allowed'; END IF;
  INSERT INTO public.stock_overrides(company_id, branch_id, profile_id, items, reason, expires_at)
  VALUES (public.current_company_id(), _branch_id, _profile, COALESCE(_items,'[]'::jsonb), _reason, now() + interval '5 minutes')
  RETURNING id INTO _id;
  PERFORM public.log_audit('pos.stock_override','pos','stock_overrides',_id,NULL,
    jsonb_build_object('items',_items,'cashier',_profile,'at',now()),_reason,_branch_id);
  RETURN _id;
END $$;
REVOKE EXECUTE ON FUNCTION public.begin_stock_override(uuid,jsonb,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.begin_stock_override(uuid,jsonb,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.apply_stock_movement(_branch_id uuid, _item_id uuid, _type stock_movement_type, _qty numeric, _unit_cost numeric DEFAULT NULL::numeric, _reason text DEFAULT NULL::text, _reference_type text DEFAULT NULL::text, _reference_id uuid DEFAULT NULL::uuid)
 RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE _company uuid; _profile uuid := public.current_profile_id(); _bal numeric; _bar numeric; _cost numeric; _mv uuid; _min numeric; _barmin numeric; _name text; _recent boolean;
  _loc text := CASE WHEN _type IN ('sale_consumption','sale_return') THEN 'bar' ELSE 'main' END;
BEGIN
  SELECT i.company_id, COALESCE(_unit_cost, i.cost_per_unit), i.min_qty, i.bar_min_qty, i.name
    INTO _company, _cost, _min, _barmin, _name
  FROM public.inventory_items i WHERE i.id = _item_id;
  IF _company IS NULL THEN RAISE EXCEPTION 'Inventory item not found'; END IF;

  INSERT INTO public.branch_stock (item_id, branch_id, quantity, bar_quantity)
  VALUES (_item_id, _branch_id, _qty, CASE WHEN _loc='bar' THEN _qty ELSE 0 END)
  ON CONFLICT (item_id, branch_id) DO UPDATE SET
    quantity = public.branch_stock.quantity + _qty,
    bar_quantity = CASE WHEN _loc='bar' THEN public.branch_stock.bar_quantity + _qty
                        ELSE LEAST(public.branch_stock.bar_quantity, public.branch_stock.quantity + _qty) END,
    updated_at = now()
  RETURNING quantity, bar_quantity INTO _bal, _bar;

  IF _bal < 0 AND NOT (_type = 'sale_consumption' AND EXISTS (
      SELECT 1 FROM public.stock_overrides o
      WHERE o.profile_id = _profile AND o.branch_id = _branch_id AND o.expires_at > now())) THEN
    RAISE EXCEPTION 'Not enough stock available for %', _name;
  END IF;

  INSERT INTO public.stock_movements (company_id, branch_id, item_id, movement_type, quantity, unit_cost,
    balance_after, reference_type, reference_id, reason, created_by, location)
  VALUES (_company, _branch_id, _item_id, _type, _qty, COALESCE(_cost,0), _bal, _reference_type, _reference_id, _reason, _profile, _loc)
  RETURNING id INTO _mv;

  IF _qty < 0 AND (_bal <= _min OR (_loc='bar' AND _bar <= _barmin)) THEN
    SELECT EXISTS (SELECT 1 FROM public.notifications n
      WHERE n.company_id = _company AND n.type = 'inventory.low_stock'
        AND COALESCE(n.branch_id, _branch_id) = _branch_id
        AND (n.data->>'item_id')::uuid = _item_id
        AND (n.read_at IS NULL OR n.created_at > now() - interval '6 hours')) INTO _recent;
    IF NOT _recent THEN
      INSERT INTO public.notifications (company_id, branch_id, required_permission, type, severity, title, body, data)
      VALUES (_company, _branch_id, 'inventory.view', 'inventory.low_stock', 'warning',
        CASE WHEN _loc='bar' AND _bar <= _barmin THEN 'اطلب من المخزن الرئيسي: ' ELSE 'Low stock: ' END || _name,
        'Bar: ' || _bar::text || ' / Total: ' || _bal::text,
        jsonb_build_object('item_id', _item_id, 'quantity', _bal, 'bar_quantity', _bar, 'min_qty', _min));
    END IF;
  END IF;
  RETURN _mv;
END $function$;