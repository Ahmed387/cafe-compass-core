-- =====================================================================
-- Inventory costing
--   * Waste % per ingredient is an internal tracking figure only: the
--     expected loss for that item. It defaults to 0 and NEVER marks up cost:
--       - a sale deducts exactly the recipe quantity from stock,
--       - a sold line's cost (COGS) is the raw recipe cost,
--       - menu and offer prices never see it.
--     It sets the stocktake tolerance and is frozen on each sold line
--     (unit_waste_cost) as "expected waste" for reporting.
--     Real losses are logged as waste movements (record_waste), each with
--     who bears the cost. Lines sold before this change keep the flat 5%
--     they were actually charged.
--   * Add-on (modifier) ingredients now add their cost to the line.
--   * Purchase cost = weighted average of stock on hand and the delivery,
--     after the invoice discount — no more "last price wins" jumps.
--   * Sanity guard against unit mix-ups (e.g. bag price typed as gram price).
-- =====================================================================

ALTER TABLE public.inventory_items ADD COLUMN IF NOT EXISTS waste_pct numeric(5,2) NOT NULL DEFAULT 0;
ALTER TABLE public.inventory_items DROP CONSTRAINT IF EXISTS inventory_items_waste_pct_check;
ALTER TABLE public.inventory_items ADD CONSTRAINT inventory_items_waste_pct_check CHECK (waste_pct >= 0 AND waste_pct <= 100);

-- Expected waste for the line (info only). NULL = sold before per-item waste
-- existed, when every line was charged a flat 5% extra.
ALTER TABLE public.order_items ADD COLUMN IF NOT EXISTS unit_waste_cost numeric(14,4);

-- ---------------------------------------------------------------------
-- Cost helpers used by every money function.
-- ---------------------------------------------------------------------
-- Cost of goods for a sold line = its raw recipe cost. Waste is never added;
-- legacy lines (NULL unit_waste_cost) were sold with 5% extra stock taken out,
-- so they keep that cost.
CREATE OR REPLACE FUNCTION public.line_cogs(_oi public.order_items)
RETURNS numeric LANGUAGE sql IMMUTABLE SET search_path TO 'public' AS $$
  SELECT COALESCE(_oi.quantity, 0) * CASE WHEN _oi.unit_waste_cost IS NULL THEN COALESCE(_oi.unit_cost, 0) * 1.05
                                          ELSE COALESCE(_oi.unit_cost, 0) END
$$;
-- Ingredient cost for a sold line.
CREATE OR REPLACE FUNCTION public.line_raw_cost(_oi public.order_items)
RETURNS numeric LANGUAGE sql IMMUTABLE SET search_path TO 'public' AS $$
  SELECT COALESCE(_oi.quantity, 0) * COALESCE(_oi.unit_cost, 0)
$$;
-- Per-unit COGS of a line (for partial refunds).
CREATE OR REPLACE FUNCTION public.order_item_unit_cogs(_order_item_id uuid)
RETURNS numeric LANGUAGE sql STABLE SET search_path TO 'public' AS $$
  SELECT CASE WHEN oi.quantity > 0 THEN public.line_cogs(oi) / oi.quantity ELSE 0 END
    FROM public.order_items oi WHERE oi.id = _order_item_id
$$;

-- ---------------------------------------------------------------------
-- Freeze cost at sale time: raw recipe cost, plus expected waste kept apart (info).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_line_recipe_cost()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _raw numeric; _waste numeric;
BEGIN
  IF NEW.product_id IS NULL THEN
    NEW.unit_waste_cost := COALESCE(NEW.unit_waste_cost, 0);
    RETURN NEW;
  END IF;
  SELECT SUM(pr.quantity * COALESCE(i.cost_per_unit, 0)),
         SUM(pr.quantity * COALESCE(i.cost_per_unit, 0) * COALESCE(i.waste_pct, 0) / 100.0)
    INTO _raw, _waste
    FROM public.product_recipes pr JOIN public.inventory_items i ON i.id = pr.item_id
   WHERE pr.product_id = NEW.product_id AND (pr.size_id IS NULL OR pr.size_id = NEW.size_id);
  IF COALESCE(_raw, 0) > 0 THEN
    NEW.unit_cost := round(_raw, 4);
    NEW.unit_waste_cost := round(COALESCE(_waste, 0), 4);
  ELSE
    NEW.unit_waste_cost := COALESCE(NEW.unit_waste_cost, 0);
  END IF;
  RETURN NEW;
END $$;

-- A sale takes exactly the recipe quantity from the bar (no waste markup).
CREATE OR REPLACE FUNCTION public.consume_recipe_on_sale()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _branch uuid; _r record;
BEGIN
  SELECT o.branch_id INTO _branch FROM public.orders o WHERE o.id = NEW.order_id;
  IF _branch IS NULL OR NEW.product_id IS NULL THEN RETURN NEW; END IF;
  FOR _r IN
    SELECT pr.item_id, pr.quantity FROM public.product_recipes pr
     WHERE pr.product_id = NEW.product_id AND (pr.size_id IS NULL OR pr.size_id = NEW.size_id)
  LOOP
    PERFORM public.apply_stock_movement(_branch, _r.item_id, 'sale_consumption',
      -round(_r.quantity * NEW.quantity, 4), NULL, NULL, 'order_item', NEW.id);
  END LOOP;
  RETURN NEW;
END $$;

-- Add-ons: consume their exact ingredients AND add their raw cost to the line.
CREATE OR REPLACE FUNCTION public.consume_modifier_recipe_on_sale()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _branch uuid; _qty int; _r record; _raw numeric := 0; _waste numeric := 0;
BEGIN
  IF NEW.option_id IS NULL THEN RETURN NEW; END IF;
  SELECT o.branch_id, oi.quantity INTO _branch, _qty
    FROM public.order_items oi JOIN public.orders o ON o.id = oi.order_id WHERE oi.id = NEW.order_item_id;
  IF _branch IS NULL THEN RETURN NEW; END IF;
  FOR _r IN
    SELECT mr.item_id, mr.quantity, COALESCE(i.cost_per_unit, 0) AS cost, COALESCE(i.waste_pct, 0) AS wpct
      FROM public.modifier_option_recipes mr JOIN public.inventory_items i ON i.id = mr.item_id
     WHERE mr.option_id = NEW.option_id
  LOOP
    PERFORM public.apply_stock_movement(_branch, _r.item_id, 'sale_consumption',
      -round(_r.quantity * COALESCE(_qty, 1), 4), NULL, NULL, 'order_item', NEW.order_item_id);
    _raw := _raw + _r.quantity * _r.cost;
    _waste := _waste + _r.quantity * _r.cost * _r.wpct / 100.0;
  END LOOP;
  IF _raw > 0 THEN
    UPDATE public.order_items
       SET unit_cost = round(COALESCE(unit_cost, 0) + _raw, 4),
           unit_waste_cost = round(COALESCE(unit_waste_cost, 0) + _waste, 4)
     WHERE id = NEW.order_item_id;
  END IF;
  RETURN NEW;
END $$;

-- Pre-sale stock check: sales leave the bar, so check the bar for the exact recipe.
CREATE OR REPLACE FUNCTION public.check_order_stock(_branch_id uuid, _items jsonb)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _item jsonb; _mod jsonb; _r record; _needed jsonb := '{}'::jsonb; _key text; _bar numeric; _main numeric;
  _pid uuid; _pname text; _override boolean;
BEGIN
  _override := EXISTS (SELECT 1 FROM public.stock_overrides o
    WHERE o.profile_id = public.current_profile_id() AND o.branch_id = _branch_id AND o.expires_at > now());
  FOR _item IN SELECT * FROM jsonb_array_elements(COALESCE(_items, '[]'::jsonb)) LOOP
    _pid := NULLIF(_item->>'product_id', '')::uuid;
    IF _pid IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.product_recipes pr WHERE pr.product_id = _pid)
       AND NOT EXISTS (SELECT 1 FROM public.products px WHERE px.id = _pid AND NOT px.track_stock) THEN
      SELECT COALESCE(p.name_ar, p.name) INTO _pname FROM public.products p WHERE p.id = _pid;
      RAISE EXCEPTION 'RECIPE_MISSING: % — هذا المنتج بدون وصفة مخزنية، يرجى إضافة الوصفة أولاً من صفحة المخزون', COALESCE(_pname, '');
    END IF;
    CONTINUE WHEN _override;
    FOR _r IN
      SELECT pr.item_id, pr.quantity * COALESCE((_item->>'quantity')::numeric, 0) AS need
        FROM public.product_recipes pr
       WHERE pr.product_id = _pid AND (pr.size_id IS NULL OR pr.size_id = NULLIF(_item->>'size_id', '')::uuid)
    LOOP
      _key := _r.item_id::text;
      _needed := jsonb_set(_needed, ARRAY[_key], to_jsonb(COALESCE((_needed->>_key)::numeric, 0) + _r.need), true);
    END LOOP;
    IF _item ? 'modifiers' THEN
      FOR _mod IN SELECT * FROM jsonb_array_elements(_item->'modifiers') LOOP
        FOR _r IN
          SELECT mr.item_id, mr.quantity * COALESCE((_item->>'quantity')::numeric, 0) AS need
            FROM public.modifier_option_recipes mr WHERE mr.option_id = NULLIF(_mod->>'option_id', '')::uuid
        LOOP
          _key := _r.item_id::text;
          _needed := jsonb_set(_needed, ARRAY[_key], to_jsonb(COALESCE((_needed->>_key)::numeric, 0) + _r.need), true);
        END LOOP;
      END LOOP;
    END IF;
  END LOOP;
  IF _override THEN RETURN; END IF;
  FOR _r IN SELECT key::uuid AS item_id, value::numeric AS need FROM jsonb_each_text(_needed) LOOP
    SELECT COALESCE(bs.bar_quantity, 0), COALESCE(bs.quantity - bs.bar_quantity, 0) INTO _bar, _main
      FROM public.branch_stock bs WHERE bs.item_id = _r.item_id AND bs.branch_id = _branch_id;
    IF COALESCE(_bar, 0) < round(_r.need, 4) THEN
      RAISE EXCEPTION 'رصيد البار من "%" مش كفاية (البار: %، المخزن الرئيسي: %). حوّل من المخزن الأول.',
        (SELECT COALESCE(name_ar, name) FROM public.inventory_items WHERE id = _r.item_id), round(COALESCE(_bar, 0), 3), round(COALESCE(_main, 0), 3);
    END IF;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- Purchase costing: weighted average, discount spread over lines.
-- ---------------------------------------------------------------------
DROP TRIGGER IF EXISTS t_sync_latest_item_cost ON public.stock_movements;
DROP FUNCTION IF EXISTS public.sync_latest_item_cost();

-- Average cost after receiving _qty at _unit_cost (per stock unit).
CREATE OR REPLACE FUNCTION public.apply_weighted_cost(_item_id uuid, _branch_id uuid, _qty numeric, _unit_cost numeric)
RETURNS numeric LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _old_cost numeric; _on_hand numeric; _new numeric;
BEGIN
  IF COALESCE(_qty, 0) <= 0 OR COALESCE(_unit_cost, 0) <= 0 THEN RETURN NULL; END IF;
  SELECT COALESCE(cost_per_unit, 0) INTO _old_cost FROM public.inventory_items WHERE id = _item_id FOR UPDATE;
  -- Stock on hand across branches before this delivery (never negative in the average).
  SELECT GREATEST(COALESCE(SUM(quantity), 0), 0) INTO _on_hand FROM public.branch_stock WHERE item_id = _item_id;
  _new := CASE WHEN _on_hand <= 0 OR _old_cost <= 0 THEN _unit_cost
               ELSE (_on_hand * _old_cost + _qty * _unit_cost) / (_on_hand + _qty) END;
  UPDATE public.inventory_items SET cost_per_unit = round(_new, 6), updated_at = now() WHERE id = _item_id;
  RETURN _new;
END $$;
REVOKE ALL ON FUNCTION public.apply_weighted_cost(uuid, uuid, numeric, numeric) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.receive_purchase(_purchase_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _p public.purchases; _profile uuid := public.current_profile_id(); _r record; _ratio numeric; _net_cost numeric;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('purchases.receive') OR public.has_permission('purchases.create') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  SELECT * INTO _p FROM public.purchases WHERE id = _purchase_id AND company_id = public.current_company_id() FOR UPDATE;
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Purchase not found'; END IF;
  IF NOT public.can_access_branch(_p.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _p.status = 'received' THEN RAISE EXCEPTION 'This purchase was already received'; END IF;
  IF _p.status = 'cancelled' THEN RAISE EXCEPTION 'This purchase is cancelled'; END IF;

  -- Invoice discount lowers every line's cost proportionally.
  _ratio := CASE WHEN COALESCE(_p.subtotal, 0) > 0 THEN GREATEST(_p.subtotal - COALESCE(_p.discount_amount, 0), 0) / _p.subtotal ELSE 1 END;

  FOR _r IN SELECT item_id, quantity, unit_cost FROM public.purchase_items WHERE purchase_id = _purchase_id LOOP
    _net_cost := round(_r.unit_cost * _ratio, 6);
    -- Average first (uses stock on hand before this delivery), then move the stock in.
    PERFORM public.apply_weighted_cost(_r.item_id, _p.branch_id, _r.quantity, _net_cost);
    PERFORM public.apply_stock_movement(_p.branch_id, _r.item_id, 'purchase', _r.quantity, _net_cost,
      'Purchase received', 'purchase', _purchase_id);
  END LOOP;

  UPDATE public.purchases SET status = 'received', received_at = now(), received_by = _profile WHERE id = _purchase_id;
  PERFORM public.log_audit('purchase.receive', 'purchases', 'purchases', _purchase_id,
    jsonb_build_object('status', _p.status), jsonb_build_object('status', 'received', 'discount_ratio', _ratio), NULL, _p.branch_id);
  RETURN _purchase_id;
END $$;

-- Manual stock-in with a price (inventory page) also averages instead of overwriting.
CREATE OR REPLACE FUNCTION public.trg_average_cost_on_manual_purchase()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NEW.movement_type = 'purchase' AND COALESCE(NEW.unit_cost, 0) > 0 AND COALESCE(NEW.reference_type, '') <> 'purchase' THEN
    -- Stock already includes this movement, so remove it before averaging.
    UPDATE public.inventory_items i
       SET cost_per_unit = round(CASE
             WHEN GREATEST(NEW.balance_after - NEW.quantity, 0) <= 0 OR COALESCE(i.cost_per_unit, 0) <= 0 THEN NEW.unit_cost
             ELSE (GREATEST(NEW.balance_after - NEW.quantity, 0) * i.cost_per_unit + NEW.quantity * NEW.unit_cost)
                  / (GREATEST(NEW.balance_after - NEW.quantity, 0) + NEW.quantity) END, 6),
           updated_at = now()
     WHERE i.id = NEW.item_id;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS t_average_cost_on_manual_purchase ON public.stock_movements;
CREATE TRIGGER t_average_cost_on_manual_purchase AFTER INSERT ON public.stock_movements
  FOR EACH ROW EXECUTE FUNCTION public.trg_average_cost_on_manual_purchase();

-- ---------------------------------------------------------------------
-- Guard against unit mix-ups when a purchase is entered: a delivery priced
-- more than 10x the item's current cost must be explicitly confirmed.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.purchase_cost_warnings(_items jsonb)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('item_id', i.id, 'name', COALESCE(i.name_ar, i.name), 'unit', i.unit,
           'current_cost', i.cost_per_unit, 'new_cost', (x->>'unit_cost')::numeric,
           'ratio', round((x->>'unit_cost')::numeric / NULLIF(i.cost_per_unit, 0), 1))), '[]'::jsonb)
    FROM jsonb_array_elements(COALESCE(_items, '[]'::jsonb)) x
    JOIN public.inventory_items i ON i.id = NULLIF(x->>'item_id', '')::uuid AND i.company_id = public.current_company_id()
   WHERE COALESCE(i.cost_per_unit, 0) > 0 AND (x->>'unit_cost')::numeric > i.cost_per_unit * 10
$$;
REVOKE ALL ON FUNCTION public.purchase_cost_warnings(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.purchase_cost_warnings(jsonb) TO authenticated;

-- Owners set the expected waste % per ingredient (tracking + stocktake tolerance).
CREATE OR REPLACE FUNCTION public.set_item_waste_pct(_item_id uuid, _waste_pct numeric)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _old numeric;
BEGIN
  IF NOT (public.has_permission('inventory.adjust') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF _waste_pct IS NULL OR _waste_pct < 0 OR _waste_pct > 100 THEN RAISE EXCEPTION 'Waste must be between 0 and 100%%'; END IF;
  SELECT waste_pct INTO _old FROM public.inventory_items WHERE id = _item_id AND company_id = public.current_company_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Inventory item not found'; END IF;
  UPDATE public.inventory_items SET waste_pct = round(_waste_pct, 2), updated_at = now() WHERE id = _item_id;
  PERFORM public.log_audit('inventory.waste_pct', 'inventory', 'inventory_items', _item_id,
    jsonb_build_object('waste_pct', _old), jsonb_build_object('waste_pct', round(_waste_pct, 2)), NULL, NULL);
END $$;
REVOKE ALL ON FUNCTION public.set_item_waste_pct(uuid, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_item_waste_pct(uuid, numeric) TO authenticated;
