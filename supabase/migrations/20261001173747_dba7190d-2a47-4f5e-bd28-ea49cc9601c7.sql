CREATE OR REPLACE FUNCTION public.bar_low_stock(_branch_id uuid)
 RETURNS TABLE(item_id uuid, name text, unit text, bar_qty numeric, bar_min numeric, product_ids uuid[])
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT i.id, COALESCE(i.name_ar, i.name), i.unit, COALESCE(bs.bar_quantity,0), i.bar_min_qty,
         COALESCE((SELECT array_agg(DISTINCT r.product_id) FROM public.product_recipes r WHERE r.item_id = i.id), '{}')
  FROM public.inventory_items i
  LEFT JOIN public.branch_stock bs ON bs.item_id = i.id AND bs.branch_id = _branch_id
  WHERE i.company_id = public.current_company_id() AND i.is_active
    AND COALESCE(i.bar_min_qty,0) > 0 AND COALESCE(bs.bar_quantity,0) <= i.bar_min_qty
    AND public.can_access_branch(_branch_id)
    AND (public.has_permission('inventory.view') OR public.has_permission('pos.create_order') OR public.is_super_admin())
  ORDER BY 2;
$$;

ALTER TABLE public.stocktakes ADD COLUMN IF NOT EXISTS settlement text,
  ADD COLUMN IF NOT EXISTS settle_staff_id uuid REFERENCES public.user_profiles(id),
  ADD COLUMN IF NOT EXISTS settle_shift_id uuid REFERENCES public.shifts(id);
ALTER TABLE public.stocktakes ADD CONSTRAINT stocktakes_settlement_check CHECK (settlement IS NULL OR settlement IN ('venue','staff','shift'));

CREATE OR REPLACE FUNCTION public.submit_stocktake_settled(_branch_id uuid, _scope text, _counts jsonb, _notes text DEFAULT NULL,
  _settlement text DEFAULT 'venue', _staff_id uuid DEFAULT NULL, _shift_id uuid DEFAULT NULL)
 RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE _id uuid; _cost numeric; _company uuid := public.current_company_id(); _n int; _each numeric; _s record;
BEGIN
  IF _settlement NOT IN ('venue','staff','shift') THEN RAISE EXCEPTION 'طريقة تسوية غير صالحة'; END IF;
  _id := public.submit_stocktake(_branch_id, _scope, _counts, _notes);
  SELECT shortage_cost INTO _cost FROM public.stocktakes WHERE id = _id;
  _cost := round(COALESCE(_cost,0), 2);
  IF _cost <= 0 THEN RETURN _id; END IF;
  IF _settlement = 'staff' THEN
    IF NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE id = _staff_id AND company_id = _company) THEN
      RAISE EXCEPTION 'اختر موظفًا صالحًا'; END IF;
    INSERT INTO public.staff_penalties(company_id, staff_id, amount, reason, created_by)
      VALUES (_company, _staff_id, _cost, 'عجز جرد المخزون', public.current_profile_id());
  ELSIF _settlement = 'shift' THEN
    IF NOT EXISTS (SELECT 1 FROM public.shifts WHERE id = _shift_id AND branch_id = _branch_id) THEN
      RAISE EXCEPTION 'اختر وردية صالحة من هذا الفرع'; END IF;
    SELECT count(*) INTO _n FROM public.shift_staff WHERE shift_id = _shift_id;
    IF _n = 0 THEN RAISE EXCEPTION 'لا يوجد طاقم مسجل لهذه الوردية'; END IF;
    _each := round(_cost / _n, 2);
    FOR _s IN SELECT staff_id FROM public.shift_staff WHERE shift_id = _shift_id LOOP
      INSERT INTO public.staff_penalties(company_id, staff_id, amount, reason, shift_id, created_by)
        VALUES (_company, _s.staff_id, _each, 'عجز جرد المخزون (توزيع على الوردية)', _shift_id, public.current_profile_id());
    END LOOP;
  END IF;
  UPDATE public.stocktakes SET settlement = _settlement,
    settle_staff_id = CASE WHEN _settlement='staff' THEN _staff_id END,
    settle_shift_id = CASE WHEN _settlement='shift' THEN _shift_id END WHERE id = _id;
  PERFORM public.log_audit('stocktake.settle','inventory','stocktake',_id,NULL,
    jsonb_build_object('settlement',_settlement,'amount',_cost,'staff_id',_staff_id,'shift_id',_shift_id),NULL,_branch_id);
  RETURN _id;
END $$;

REVOKE EXECUTE ON FUNCTION public.bar_low_stock(uuid), public.submit_stocktake_settled(uuid,text,jsonb,text,text,uuid,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bar_low_stock(uuid), public.submit_stocktake_settled(uuid,text,jsonb,text,text,uuid,uuid) TO authenticated;