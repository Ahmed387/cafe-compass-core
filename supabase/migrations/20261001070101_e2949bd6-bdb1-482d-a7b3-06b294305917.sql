ALTER TABLE public.branch_stock ADD COLUMN IF NOT EXISTS bar_quantity numeric NOT NULL DEFAULT 0;
ALTER TABLE public.stock_movements ADD COLUMN IF NOT EXISTS location text NOT NULL DEFAULT 'main' CHECK (location IN ('main','bar'));
ALTER TABLE public.inventory_items ADD COLUMN IF NOT EXISTS bar_min_qty numeric NOT NULL DEFAULT 0;

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

  IF _bal < 0 THEN RAISE EXCEPTION 'Not enough stock available for %', _name; END IF;

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

CREATE TABLE public.stock_transfers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  branch_id uuid NOT NULL REFERENCES public.branches(id),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
  notes text,
  requested_by uuid REFERENCES public.user_profiles(id),
  decided_by uuid REFERENCES public.user_profiles(id),
  decided_at timestamptz,
  reject_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.stock_transfer_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transfer_id uuid NOT NULL REFERENCES public.stock_transfers(id) ON DELETE CASCADE,
  item_id uuid NOT NULL REFERENCES public.inventory_items(id),
  quantity numeric NOT NULL CHECK (quantity > 0)
);
GRANT SELECT ON public.stock_transfers, public.stock_transfer_items TO authenticated;
GRANT ALL ON public.stock_transfers, public.stock_transfer_items TO service_role;
ALTER TABLE public.stock_transfers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_transfer_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY st_select ON public.stock_transfers FOR SELECT TO authenticated
  USING (company_id = public.current_company_id() AND public.has_permission('inventory.view') AND public.can_access_branch(branch_id));
CREATE POLICY sti_select ON public.stock_transfer_items FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.stock_transfers t WHERE t.id = transfer_id));

CREATE OR REPLACE FUNCTION public.request_stock_transfer(_branch_id uuid, _items jsonb, _notes text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _id uuid; _it jsonb; _n int := 0;
BEGIN
  IF NOT public.has_permission('inventory.view') OR NOT public.can_access_branch(_branch_id) THEN RAISE EXCEPTION 'Not allowed'; END IF;
  INSERT INTO public.stock_transfers(company_id, branch_id, notes, requested_by)
  VALUES (public.current_company_id(), _branch_id, NULLIF(trim(_notes),''), public.current_profile_id()) RETURNING id INTO _id;
  FOR _it IN SELECT * FROM jsonb_array_elements(COALESCE(_items,'[]')) LOOP
    IF COALESCE((_it->>'quantity')::numeric,0) <= 0 THEN CONTINUE; END IF;
    INSERT INTO public.stock_transfer_items(transfer_id, item_id, quantity)
    SELECT _id, i.id, (_it->>'quantity')::numeric FROM public.inventory_items i
    WHERE i.id = (_it->>'item_id')::uuid AND i.company_id = public.current_company_id();
    _n := _n + 1;
  END LOOP;
  IF _n = 0 THEN RAISE EXCEPTION 'أضف صنفًا واحدًا على الأقل'; END IF;
  PERFORM public.log_audit('stock_transfer.request','inventory','stock_transfer',_id,NULL,_items,_notes,_branch_id);
  RETURN _id;
END $$;

CREATE OR REPLACE FUNCTION public.decide_stock_transfer(_id uuid, _approve boolean, _reason text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _t public.stock_transfers; _r record; _main numeric;
BEGIN
  IF NOT public.has_permission('inventory.adjust') THEN RAISE EXCEPTION 'الموافقة للمدير فقط'; END IF;
  SELECT * INTO _t FROM public.stock_transfers WHERE id = _id AND company_id = public.current_company_id() FOR UPDATE;
  IF _t.id IS NULL OR _t.status <> 'pending' THEN RAISE EXCEPTION 'الطلب غير موجود أو تم البت فيه'; END IF;
  IF NOT public.can_access_branch(_t.branch_id) THEN RAISE EXCEPTION 'Not allowed'; END IF;
  IF _approve THEN
    FOR _r IN SELECT ti.item_id, ti.quantity, i.name, i.cost_per_unit FROM public.stock_transfer_items ti JOIN public.inventory_items i ON i.id = ti.item_id WHERE ti.transfer_id = _id LOOP
      SELECT bs.quantity - bs.bar_quantity INTO _main FROM public.branch_stock bs WHERE bs.item_id = _r.item_id AND bs.branch_id = _t.branch_id FOR UPDATE;
      IF COALESCE(_main,0) < _r.quantity THEN RAISE EXCEPTION 'المخزن الرئيسي لا يكفي: % (متاح %)', _r.name, COALESCE(_main,0); END IF;
      UPDATE public.branch_stock SET bar_quantity = bar_quantity + _r.quantity, updated_at = now()
        WHERE item_id = _r.item_id AND branch_id = _t.branch_id;
      INSERT INTO public.stock_movements(company_id, branch_id, item_id, movement_type, quantity, unit_cost, balance_after, reference_type, reference_id, reason, created_by, location)
      SELECT _t.company_id, _t.branch_id, _r.item_id, 'transfer_out', -_r.quantity, _r.cost_per_unit, bs.quantity - bs.bar_quantity, 'stock_transfer', _id, 'Main → Bar', public.current_profile_id(), 'main'
        FROM public.branch_stock bs WHERE bs.item_id = _r.item_id AND bs.branch_id = _t.branch_id;
      INSERT INTO public.stock_movements(company_id, branch_id, item_id, movement_type, quantity, unit_cost, balance_after, reference_type, reference_id, reason, created_by, location)
      SELECT _t.company_id, _t.branch_id, _r.item_id, 'transfer_in', _r.quantity, _r.cost_per_unit, bs.bar_quantity, 'stock_transfer', _id, 'Main → Bar', public.current_profile_id(), 'bar'
        FROM public.branch_stock bs WHERE bs.item_id = _r.item_id AND bs.branch_id = _t.branch_id;
    END LOOP;
  END IF;
  UPDATE public.stock_transfers SET status = CASE WHEN _approve THEN 'approved' ELSE 'rejected' END,
    decided_by = public.current_profile_id(), decided_at = now(), reject_reason = CASE WHEN _approve THEN NULL ELSE _reason END, updated_at = now()
    WHERE id = _id;
  PERFORM public.log_audit(CASE WHEN _approve THEN 'stock_transfer.approve' ELSE 'stock_transfer.reject' END,'inventory','stock_transfer',_id,NULL,NULL,_reason,_t.branch_id);
END $$;

CREATE OR REPLACE FUNCTION public.set_bar_min_qty(_item_id uuid, _qty numeric)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NOT public.has_permission('inventory.adjust') THEN RAISE EXCEPTION 'Not allowed'; END IF;
  UPDATE public.inventory_items SET bar_min_qty = GREATEST(COALESCE(_qty,0),0), updated_at = now()
  WHERE id = _item_id AND company_id = public.current_company_id();
END $$;

REVOKE EXECUTE ON FUNCTION public.request_stock_transfer(uuid,jsonb,text), public.decide_stock_transfer(uuid,boolean,text), public.set_bar_min_qty(uuid,numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_stock_transfer(uuid,jsonb,text), public.decide_stock_transfer(uuid,boolean,text), public.set_bar_min_qty(uuid,numeric) TO authenticated;