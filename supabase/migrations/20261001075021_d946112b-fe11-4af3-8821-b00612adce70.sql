CREATE TABLE public.stocktakes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  branch_id uuid NOT NULL REFERENCES public.branches(id),
  scope text NOT NULL CHECK (scope IN ('bar','main','both')),
  notes text,
  shortage_cost numeric NOT NULL DEFAULT 0,
  hr_waste_credit numeric NOT NULL DEFAULT 0,
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.stocktake_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  stocktake_id uuid NOT NULL REFERENCES public.stocktakes(id) ON DELETE CASCADE,
  item_id uuid NOT NULL REFERENCES public.inventory_items(id),
  location text NOT NULL CHECK (location IN ('main','bar')),
  expected numeric NOT NULL,
  counted numeric NOT NULL,
  allowance numeric NOT NULL DEFAULT 0,
  variance numeric NOT NULL,
  net_variance numeric NOT NULL,
  unit_cost numeric NOT NULL DEFAULT 0
);
GRANT SELECT ON public.stocktakes, public.stocktake_lines TO authenticated;
GRANT ALL ON public.stocktakes, public.stocktake_lines TO service_role;
ALTER TABLE public.stocktakes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stocktake_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY st_select ON public.stocktakes FOR SELECT TO authenticated
  USING (company_id = public.current_company_id() AND (public.has_permission('inventory.view') OR public.is_super_admin()) AND public.can_access_branch(branch_id));
CREATE POLICY stl_select ON public.stocktake_lines FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.stocktakes s WHERE s.id = stocktake_id));

-- Preview: expected per item/location since the last stocktake of that location
CREATE OR REPLACE FUNCTION public.stocktake_preview(_branch_id uuid, _scope text)
RETURNS TABLE(item_id uuid, name text, unit text, location text, unit_cost numeric, since timestamptz,
  start_qty numeric, transfers_in numeric, transfers_out numeric, consumption numeric, purchases numeric,
  other numeric, expected numeric, allowance numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT (public.has_permission('inventory.view') OR public.is_super_admin()) OR NOT public.can_access_branch(_branch_id) THEN
    RAISE EXCEPTION 'Not allowed'; END IF;
  RETURN QUERY
  WITH locs AS (SELECT unnest(CASE _scope WHEN 'both' THEN ARRAY['main','bar'] ELSE ARRAY[_scope] END) AS loc),
  base AS (
    SELECT i.id, COALESCE(NULLIF(i.name_ar,''), i.name) AS nm, i.unit AS un, COALESCE(i.cost_per_unit,0) AS cost, l.loc,
      CASE WHEN l.loc='bar' THEN COALESCE(bs.bar_quantity,0) ELSE COALESCE(bs.quantity,0) - COALESCE(bs.bar_quantity,0) END AS cur,
      (SELECT max(s.created_at) FROM public.stocktake_lines sl JOIN public.stocktakes s ON s.id = sl.stocktake_id
        WHERE sl.item_id = i.id AND sl.location = l.loc AND s.branch_id = _branch_id) AS last_at
    FROM public.inventory_items i CROSS JOIN locs l
    LEFT JOIN public.branch_stock bs ON bs.item_id = i.id AND bs.branch_id = _branch_id
    WHERE i.company_id = public.current_company_id() AND i.is_active
  ),
  mv AS (
    SELECT b.id, b.loc,
      COALESCE(sum(m.quantity) FILTER (WHERE m.movement_type='transfer_in'),0) tin,
      COALESCE(-sum(m.quantity) FILTER (WHERE m.movement_type='transfer_out'),0) tout,
      COALESCE(-sum(m.quantity) FILTER (WHERE m.movement_type IN ('sale_consumption','sale_return')),0) cons,
      COALESCE(sum(m.quantity) FILTER (WHERE m.movement_type='purchase'),0) pur,
      COALESCE(sum(m.quantity) FILTER (WHERE m.movement_type NOT IN ('transfer_in','transfer_out','sale_consumption','sale_return','purchase')),0) oth
    FROM base b LEFT JOIN public.stock_movements m ON m.item_id = b.id AND m.branch_id = _branch_id AND m.location = b.loc
      AND m.created_at > COALESCE(b.last_at, '-infinity'::timestamptz)
    GROUP BY b.id, b.loc
  )
  SELECT b.id, b.nm, b.un, b.loc, b.cost, b.last_at,
    b.cur - (mv.tin - mv.tout - mv.cons + mv.pur + mv.oth),
    mv.tin, mv.tout, mv.cons, mv.pur, mv.oth, b.cur, round(GREATEST(mv.cons,0) * 0.05, 4)
  FROM base b JOIN mv ON mv.id = b.id AND mv.loc = b.loc
  ORDER BY b.nm, b.loc;
END $$;

CREATE OR REPLACE FUNCTION public.submit_stocktake(_branch_id uuid, _scope text, _counts jsonb, _notes text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _id uuid; _r record; _c jsonb; _counted numeric; _delta numeric; _net numeric; _short numeric := 0;
  _company uuid := public.current_company_id(); _since timestamptz; _hr numeric;
BEGIN
  IF NOT (public.has_permission('inventory.adjust') OR public.is_super_admin()) OR NOT public.can_access_branch(_branch_id) THEN
    RAISE EXCEPTION 'اعتماد الجرد للمدير فقط'; END IF;
  IF _scope NOT IN ('bar','main','both') THEN RAISE EXCEPTION 'نطاق غير صالح'; END IF;
  INSERT INTO public.stocktakes(company_id, branch_id, scope, notes, created_by)
    VALUES (_company, _branch_id, _scope, _notes, public.current_profile_id()) RETURNING id INTO _id;
  FOR _r IN SELECT * FROM public.stocktake_preview(_branch_id, _scope) LOOP
    SELECT e INTO _c FROM jsonb_array_elements(_counts) e
      WHERE (e->>'item_id')::uuid = _r.item_id AND e->>'location' = _r.location LIMIT 1;
    CONTINUE WHEN _c IS NULL OR _c->>'counted' IS NULL OR _c->>'counted' = '';
    _counted := (_c->>'counted')::numeric;
    IF _counted < 0 THEN RAISE EXCEPTION 'كمية سالبة: %', _r.name; END IF;
    _delta := _counted - _r.expected;
    _net := CASE WHEN _delta < 0 THEN LEAST(_delta + _r.allowance, 0) ELSE _delta END;
    IF _net < 0 THEN _short := _short + (-_net) * _r.unit_cost; END IF;
    INSERT INTO public.stocktake_lines(stocktake_id, item_id, location, expected, counted, allowance, variance, net_variance, unit_cost)
      VALUES (_id, _r.item_id, _r.location, _r.expected, _counted, _r.allowance, _delta, _net, _r.unit_cost);
    INSERT INTO public.branch_stock(item_id, branch_id, quantity, bar_quantity) VALUES (_r.item_id, _branch_id, 0, 0)
      ON CONFLICT (item_id, branch_id) DO NOTHING;
    IF _r.location = 'bar' THEN
      UPDATE public.branch_stock SET bar_quantity = _counted, quantity = quantity + _delta, updated_at = now()
        WHERE item_id = _r.item_id AND branch_id = _branch_id;
    ELSE
      UPDATE public.branch_stock SET quantity = quantity + _delta, updated_at = now()
        WHERE item_id = _r.item_id AND branch_id = _branch_id;
    END IF;
    INSERT INTO public.stock_movements(company_id, branch_id, item_id, movement_type, quantity, unit_cost, balance_after, reference_type, reference_id, reason, created_by, location)
      VALUES (_company, _branch_id, _r.item_id, 'stocktake', _delta, _r.unit_cost, _counted, 'stocktake', _id, 'جرد', public.current_profile_id(), _r.location);
  END LOOP;
  SELECT min(since) INTO _since FROM public.stocktake_preview(_branch_id, _scope) WHERE false;
  SELECT COALESCE(sum(p.amount),0) INTO _hr FROM public.staff_penalties p
    WHERE p.company_id = _company AND p.created_at > COALESCE(
      (SELECT max(created_at) FROM public.stocktakes WHERE branch_id = _branch_id AND id <> _id), '-infinity'::timestamptz);
  UPDATE public.stocktakes SET shortage_cost = GREATEST(_short - _hr, 0), hr_waste_credit = _hr WHERE id = _id;
  PERFORM public.log_audit('stocktake.approve','inventory','stocktake',_id,NULL,
    jsonb_build_object('scope',_scope,'shortage_cost',GREATEST(_short - _hr,0),'hr_credit',_hr),_notes,_branch_id);
  RETURN _id;
END $$;

REVOKE EXECUTE ON FUNCTION public.stocktake_preview(uuid,text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.submit_stocktake(uuid,text,jsonb,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.stocktake_preview(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_stocktake(uuid,text,jsonb,text) TO authenticated;