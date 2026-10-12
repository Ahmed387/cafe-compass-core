-- =====================================================================
-- Waste attribution, full vs partial returns, per-item stocktake tolerance
--
-- Waste: every damaged / wasted stock entry must say who bears its cost.
--   business  → an operational loss in the P&L (stock waste line)
--   staff     → one employee: a payroll penalty for the full cost
--   all_staff → split evenly over every active staff member as penalties
-- Staff-borne waste stays in the P&L stock-waste line; the penalties lower
-- payroll cost when they are deducted, so the café's result is exact.
--
-- Returns:
--   refund_order_full    → returns everything still on the invoice, restocks
--                          it, refunds the rest of the money, closes the bill
--   refund_order_items_* → returns chosen items / quantities, the rest of the
--                          order stays active
-- =====================================================================

-- ---------------------------------------------------------------------
-- Who bears each waste movement (NULL on old rows = the business).
-- ---------------------------------------------------------------------
ALTER TABLE public.stock_movements ADD COLUMN IF NOT EXISTS waste_bearer text;
ALTER TABLE public.stock_movements ADD COLUMN IF NOT EXISTS waste_staff_id uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL;
ALTER TABLE public.stock_movements DROP CONSTRAINT IF EXISTS stock_movements_waste_bearer_check;
ALTER TABLE public.stock_movements ADD CONSTRAINT stock_movements_waste_bearer_check
  CHECK (waste_bearer IS NULL OR waste_bearer IN ('business', 'staff', 'all_staff'));

ALTER TABLE public.staff_penalties ADD COLUMN IF NOT EXISTS stock_movement_id uuid
  REFERENCES public.stock_movements(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS staff_penalties_stock_movement_idx ON public.staff_penalties(stock_movement_id)
  WHERE stock_movement_id IS NOT NULL;

-- Staff who can share a collective charge: the same people the shift roster offers.
CREATE OR REPLACE FUNCTION public.waste_share_staff(_company uuid)
RETURNS uuid[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT COALESCE(array_agg(up.id ORDER BY up.id), '{}'::uuid[])
    FROM public.user_profiles up
   WHERE up.company_id = _company AND up.is_active
     AND NOT EXISTS (SELECT 1 FROM public.partners pa WHERE pa.user_id = up.id AND pa.status = 'active' AND NOT pa.is_managing_staff)
     AND (up.is_managing_staff OR NOT EXISTS (
           SELECT 1 FROM public.user_roles ur JOIN public.roles r ON r.id = ur.role_id
            WHERE ur.user_id = up.id AND r.key = 'super_admin'))
$$;
REVOKE ALL ON FUNCTION public.waste_share_staff(uuid) FROM PUBLIC, anon, authenticated;

-- Charge a loss to staff as payroll penalties: one employee ('staff') or split
-- evenly over the whole team ('all_staff'). Returns the penalties created.
CREATE OR REPLACE FUNCTION public._charge_staff(_company uuid, _amount numeric, _bearer text, _staff_id uuid,
  _reason text, _order_id uuid, _shift_id uuid, _source text)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _staff uuid[]; _n int; _each numeric; _amt numeric; _count int := 0;
BEGIN
  _amount := round(COALESCE(_amount, 0), 2);
  IF _bearer NOT IN ('staff', 'all_staff') OR _amount <= 0 THEN RETURN 0; END IF;
  IF _bearer = 'staff' THEN
    IF _staff_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.user_profiles
                                         WHERE id = _staff_id AND company_id = _company AND is_active) THEN
      RAISE EXCEPTION 'Select the employee who bears this cost';
    END IF;
    _staff := ARRAY[_staff_id];
  ELSE
    _staff := public.waste_share_staff(_company);
  END IF;
  _n := COALESCE(array_length(_staff, 1), 0);
  IF _n = 0 THEN RAISE EXCEPTION 'No active staff to share this cost'; END IF;
  _each := floor(_amount / _n * 100) / 100;
  FOR i IN 1.._n LOOP
    _amt := CASE WHEN i = _n THEN round(_amount - _each * (_n - 1), 2) ELSE _each END;
    IF _amt > 0 THEN
      INSERT INTO public.staff_penalties (company_id, staff_id, amount, reason, order_id, shift_id, created_by, source)
      VALUES (_company, _staff[i], _amt, _reason || CASE WHEN _n > 1 THEN ' (موزع على الفريق)' ELSE '' END,
              _order_id, _shift_id, public.current_profile_id(), _source);
      _count := _count + 1;
    END IF;
  END LOOP;
  RETURN _count;
END $$;
REVOKE ALL ON FUNCTION public._charge_staff(uuid, numeric, text, uuid, text, uuid, uuid, text) FROM PUBLIC, anon, authenticated;

-- (Re)create the payroll penalties for a staff-borne waste movement.
CREATE OR REPLACE FUNCTION public._charge_waste(_mv uuid, _staff uuid[])
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _m public.stock_movements; _amount numeric; _n int; _each numeric; _amt numeric; _count int := 0;
  _what text;
BEGIN
  SELECT * INTO _m FROM public.stock_movements WHERE id = _mv;
  IF EXISTS (SELECT 1 FROM public.staff_penalties WHERE stock_movement_id = _mv AND COALESCE(deducted_amount, 0) > 0) THEN
    RAISE EXCEPTION 'This waste was already deducted in payroll and can no longer change';
  END IF;
  DELETE FROM public.staff_penalties WHERE stock_movement_id = _mv;
  IF _m.waste_bearer NOT IN ('staff', 'all_staff') THEN RETURN 0; END IF;

  _amount := round(GREATEST(-_m.quantity, 0) * COALESCE(_m.unit_cost, 0), 2);
  IF _amount <= 0 THEN RETURN 0; END IF;
  _n := COALESCE(array_length(_staff, 1), 0);
  IF _n = 0 THEN RAISE EXCEPTION 'No staff to charge for this waste'; END IF;

  SELECT 'هالك: ' || COALESCE(NULLIF(i.name_ar, ''), i.name) || ' (' || round(-_m.quantity, 3)::text || ' ' || i.unit || ')'
    INTO _what FROM public.inventory_items i WHERE i.id = _m.item_id;
  _what := _what || CASE WHEN COALESCE(btrim(_m.reason), '') <> '' THEN ' — ' || btrim(_m.reason) ELSE '' END;

  _each := floor(_amount / _n * 100) / 100;
  FOR i IN 1.._n LOOP
    _amt := CASE WHEN i = _n THEN round(_amount - _each * (_n - 1), 2) ELSE _each END;
    IF _amt > 0 THEN
      INSERT INTO public.staff_penalties (company_id, staff_id, amount, reason, created_by, source, stock_movement_id)
      VALUES (_m.company_id, _staff[i], _amt,
              _what || CASE WHEN _n > 1 THEN ' (موزع على الفريق)' ELSE '' END,
              COALESCE(public.current_profile_id(), _m.created_by), 'waste', _mv);
      _count := _count + 1;
    END IF;
  END LOOP;
  RETURN _count;
END $$;
REVOKE ALL ON FUNCTION public._charge_waste(uuid, uuid[]) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- Log damaged / wasted stock with who bears the cost.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_waste(_branch_id uuid, _item_id uuid, _qty numeric, _reason text,
  _bearer text, _staff_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _company uuid := public.current_company_id(); _profile uuid := public.current_profile_id();
  _current numeric; _mv uuid; _cost numeric; _staff uuid[]; _count int := 0;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT public.can_access_branch(_branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF NOT (public.has_permission('inventory.waste') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF _qty IS NULL OR _qty <= 0 THEN RAISE EXCEPTION 'Quantity must be greater than zero'; END IF;
  IF length(btrim(COALESCE(_reason, ''))) < 3 THEN RAISE EXCEPTION 'A reason is required'; END IF;
  IF _bearer IS NULL OR _bearer NOT IN ('business', 'staff', 'all_staff') THEN
    RAISE EXCEPTION 'Choose who bears the cost of this waste';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.inventory_items WHERE id = _item_id AND company_id = _company) THEN
    RAISE EXCEPTION 'Inventory item not found';
  END IF;

  IF _bearer IN ('staff', 'all_staff') THEN
    -- Charging people's pay is a manager decision.
    IF NOT (public.is_super_admin() OR public.has_permission('inventory.adjust') OR public.has_permission('payroll.manage')) THEN
      RAISE EXCEPTION 'Only a manager can charge waste to staff';
    END IF;
    IF _bearer = 'staff' THEN
      IF _staff_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.user_profiles
                                           WHERE id = _staff_id AND company_id = _company AND is_active) THEN
        RAISE EXCEPTION 'Select the employee who bears this waste';
      END IF;
      _staff := ARRAY[_staff_id];
    ELSE
      _staff := public.waste_share_staff(_company);
      IF COALESCE(array_length(_staff, 1), 0) = 0 THEN RAISE EXCEPTION 'No active staff to share this waste'; END IF;
    END IF;
  END IF;

  SELECT COALESCE(bs.quantity, 0) INTO _current FROM public.branch_stock bs
   WHERE bs.item_id = _item_id AND bs.branch_id = _branch_id;
  IF COALESCE(_current, 0) < _qty THEN RAISE EXCEPTION 'Not enough stock available'; END IF;

  _mv := public.apply_stock_movement(_branch_id, _item_id, 'waste', -abs(_qty), NULL, btrim(_reason), 'manual', NULL);
  UPDATE public.stock_movements
     SET waste_bearer = _bearer, waste_staff_id = CASE WHEN _bearer = 'staff' THEN _staff_id END
   WHERE id = _mv
   RETURNING round(-quantity * unit_cost, 2) INTO _cost;
  IF _bearer IN ('staff', 'all_staff') THEN _count := public._charge_waste(_mv, _staff); END IF;

  PERFORM public.log_audit('inventory.waste', 'inventory', 'stock_movements', _mv, NULL,
    jsonb_build_object('item_id', _item_id, 'quantity', -abs(_qty), 'cost', _cost, 'bearer', _bearer,
                       'staff_id', _staff_id, 'penalties', _count), btrim(_reason), _branch_id);
  RETURN jsonb_build_object('movement_id', _mv, 'cost', _cost, 'bearer', _bearer, 'penalties', _count);
END $$;
REVOKE ALL ON FUNCTION public.record_waste(uuid, uuid, numeric, text, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_waste(uuid, uuid, numeric, text, text, uuid) TO authenticated;

-- Editing a staff-borne waste movement re-splits its penalties to the new cost.
CREATE OR REPLACE FUNCTION public.trg_waste_recharge()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _staff uuid[];
BEGIN
  IF NEW.quantity IS NOT DISTINCT FROM OLD.quantity AND NEW.unit_cost IS NOT DISTINCT FROM OLD.unit_cost THEN RETURN NEW; END IF;
  SELECT array_agg(staff_id ORDER BY staff_id) INTO _staff FROM public.staff_penalties WHERE stock_movement_id = NEW.id;
  IF _staff IS NULL THEN
    _staff := CASE WHEN NEW.waste_bearer = 'staff' THEN ARRAY[NEW.waste_staff_id] ELSE public.waste_share_staff(NEW.company_id) END;
  END IF;
  PERFORM public._charge_waste(NEW.id, _staff);
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS t_waste_recharge ON public.stock_movements;
CREATE TRIGGER t_waste_recharge AFTER UPDATE ON public.stock_movements
  FOR EACH ROW WHEN (NEW.waste_bearer IN ('staff', 'all_staff')) EXECUTE FUNCTION public.trg_waste_recharge();

-- Waste must go through record_waste so its cost is always attributed.
CREATE OR REPLACE FUNCTION public.record_stock_movement(
  _branch_id uuid, _item_id uuid, _type public.stock_movement_type, _qty numeric,
  _unit_cost numeric DEFAULT NULL, _reason text DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _needed text; _signed numeric; _current numeric := 0; _mv uuid;
BEGIN
  IF public.current_profile_id() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT public.can_access_branch(_branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _qty IS NULL OR _qty = 0 THEN RAISE EXCEPTION 'Quantity is required'; END IF;
  IF _type = 'waste' THEN
    RAISE EXCEPTION 'Waste needs to say who bears the cost — use the waste form';
  END IF;

  _needed := CASE _type WHEN 'transfer_in' THEN 'inventory.transfer'
    WHEN 'transfer_out' THEN 'inventory.transfer' WHEN 'purchase' THEN 'purchases.create' ELSE 'inventory.adjust' END;
  IF NOT (public.has_permission(_needed) OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF _type = 'transfer_out' AND (_reason IS NULL OR btrim(_reason) = '') THEN
    RAISE EXCEPTION 'A reason is required';
  END IF;

  SELECT COALESCE(bs.quantity,0) INTO _current FROM public.branch_stock bs
  WHERE bs.item_id = _item_id AND bs.branch_id = _branch_id;

  IF _type = 'stocktake' THEN
    _signed := _qty - COALESCE(_current,0);
    IF _signed = 0 THEN RETURN NULL; END IF;
  ELSIF _type = 'transfer_out' THEN
    _signed := -abs(_qty);
  ELSIF _type = 'adjustment' THEN
    _signed := _qty;
  ELSE
    _signed := abs(_qty);
  END IF;

  IF COALESCE(_current,0) + _signed < 0 THEN RAISE EXCEPTION 'Not enough stock available'; END IF;

  _mv := public.apply_stock_movement(_branch_id, _item_id, _type, _signed, _unit_cost, _reason, 'manual', NULL);
  PERFORM public.log_audit('inventory.' || _type::text, 'inventory', 'stock_movements', _mv, NULL,
    jsonb_build_object('item_id', _item_id, 'quantity', _signed, 'reason', _reason), _reason, _branch_id);
  RETURN _mv;
END $$;

-- ---------------------------------------------------------------------
-- Stocktake tolerance = each item's own expected waste % of what was used
-- (was a flat 5%). Items left at 0% get no tolerance.
-- ---------------------------------------------------------------------
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
      COALESCE(i.waste_pct, 0) AS wpct,
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
    mv.tin, mv.tout, mv.cons, mv.pur, mv.oth, b.cur, round(GREATEST(mv.cons,0) * b.wpct / 100.0, 4)
  FROM base b JOIN mv ON mv.id = b.id AND mv.loc = b.loc
  ORDER BY b.nm, b.loc;
END $$;

-- ---------------------------------------------------------------------
-- Partial item return: same as before, plus the bill closes itself once
-- everything on it has been given back. Staff-fault penalties are tagged.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.refund_order_items_attributed(_order_id uuid, _items jsonb,
  _method_key text, _reason text, _fault text, _staff_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _res jsonb; _ref public.order_refunds; _paid numeric; _already numeric; _left_qty numeric;
BEGIN
  -- 'business' and 'venue' mean the same: the café absorbs it.
  _fault := CASE WHEN _fault = 'business' THEN 'venue' ELSE _fault END;
  IF _fault IS NULL OR _fault NOT IN ('staff', 'venue', 'all_staff') THEN RAISE EXCEPTION 'Refund attribution is required'; END IF;
  IF _fault = 'staff' AND _staff_id IS NULL THEN RAISE EXCEPTION 'Select the responsible staff member'; END IF;
  _res := public.refund_order_items(_order_id, _items, COALESCE(_method_key, 'cash'), _reason);
  SELECT * INTO _ref FROM public.order_refunds WHERE id = (_res->>'refund_id')::uuid;
  IF _fault = 'staff' AND NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE id = _staff_id AND company_id = _ref.company_id) THEN
    RAISE EXCEPTION 'Invalid staff member';
  END IF;
  UPDATE public.order_refunds SET fault = _fault, blamed_staff_id = CASE WHEN _fault = 'staff' THEN _staff_id END
   WHERE id = _ref.id;
  IF _fault IN ('staff', 'all_staff') THEN
    PERFORM public._charge_staff(_ref.company_id, _ref.amount, _fault, _staff_id,
      'خطأ موظف — مرتجع: ' || _reason, _order_id, _ref.shift_id, 'refund');
  END IF;

  -- Nothing left to give back → the bill is fully returned.
  SELECT COALESCE(SUM(amount), 0) INTO _paid FROM public.order_payments WHERE order_id = _order_id;
  SELECT COALESCE(SUM(amount), 0) INTO _already FROM public.order_refunds WHERE order_id = _order_id AND status = 'active';
  SELECT COALESCE(SUM(oi.quantity), 0) - COALESCE((
           SELECT SUM((e->>'quantity')::numeric) FROM public.order_refunds r
            CROSS JOIN LATERAL jsonb_array_elements(COALESCE(r.items_payload, '[]'::jsonb)) e
            WHERE r.order_id = _order_id AND r.status = 'active' AND r.origin = 'manual'), 0)
    INTO _left_qty FROM public.order_items oi WHERE oi.order_id = _order_id AND oi.status = 'active';
  IF round(_paid - _already, 2) <= 0 OR _left_qty <= 0 THEN
    UPDATE public.orders SET status = 'refunded', updated_at = now() WHERE id = _order_id;
    _res := _res || jsonb_build_object('kind', 'full', 'status', 'refunded');
  END IF;
  RETURN _res;
END $$;

-- ---------------------------------------------------------------------
-- Full invoice return: everything still on the bill comes back to stock,
-- the rest of the money goes back, and the bill closes.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.refund_order_full(_order_id uuid, _reason text, _method_key text DEFAULT 'cash',
  _fault text DEFAULT 'venue', _staff_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _o public.orders; _items jsonb := '[]'::jsonb; _r record; _res jsonb; _ref_id uuid;
  _paid numeric; _already numeric; _left numeric;
BEGIN
  SELECT * INTO _o FROM public.orders WHERE id = _order_id;
  IF _o.id IS NULL THEN RAISE EXCEPTION 'Order not found'; END IF;
  IF _o.status NOT IN ('completed', 'partially_refunded') THEN
    RAISE EXCEPTION 'Only delivered orders can be returned';
  END IF;

  FOR _r IN
    SELECT oi.id, oi.quantity - COALESCE((
             SELECT SUM((e->>'quantity')::int) FROM public.order_refunds r
              CROSS JOIN LATERAL jsonb_array_elements(COALESCE(r.items_payload, '[]'::jsonb)) e
              WHERE r.order_id = _order_id AND r.status = 'active' AND r.origin = 'manual'
                AND e->>'order_item_id' = oi.id::text), 0) AS left_qty
      FROM public.order_items oi
     WHERE oi.order_id = _order_id AND oi.status = 'active'
  LOOP
    IF _r.left_qty > 0 THEN
      _items := _items || jsonb_build_object('order_item_id', _r.id, 'quantity', _r.left_qty, 'disposition', 'restock');
    END IF;
  END LOOP;
  IF jsonb_array_length(_items) = 0 THEN RAISE EXCEPTION 'Everything on this invoice was already returned'; END IF;

  _res := public.refund_order_items_attributed(_order_id, _items, _method_key, _reason, _fault, _staff_id);
  _ref_id := (_res->>'refund_id')::uuid;

  -- The proportional share can round a piastre short; give back the exact rest.
  SELECT COALESCE(SUM(amount), 0) INTO _paid FROM public.order_payments WHERE order_id = _order_id;
  SELECT COALESCE(SUM(amount), 0) INTO _already FROM public.order_refunds WHERE order_id = _order_id AND status = 'active';
  _left := round(_paid - _already, 2);
  IF _left > 0 THEN
    UPDATE public.order_refunds SET amount = round(amount + _left, 2) WHERE id = _ref_id;
    UPDATE public.staff_penalties SET amount = round(amount + _left, 2)
     WHERE id = (SELECT id FROM public.staff_penalties
                  WHERE order_id = _order_id AND source = 'refund' AND created_at = now()
                  ORDER BY created_at DESC, amount DESC LIMIT 1);
  END IF;
  UPDATE public.order_refunds SET kind = 'full' WHERE id = _ref_id;
  UPDATE public.orders SET status = 'refunded', updated_at = now() WHERE id = _order_id;

  PERFORM public.log_audit('order.refund_full', 'pos', 'orders', _order_id, jsonb_build_object('status', _o.status),
    jsonb_build_object('status', 'refunded', 'refund_id', _ref_id, 'items', _items), _reason, _o.branch_id);
  SELECT amount INTO _left FROM public.order_refunds WHERE id = _ref_id;
  RETURN _res || jsonb_build_object('kind', 'full', 'status', 'refunded', 'amount', _left);
END $$;
REVOKE ALL ON FUNCTION public.refund_order_full(uuid, text, text, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.refund_order_full(uuid, text, text, text, uuid) TO authenticated;
