-- =====================================================================
-- One-off data fix for the 20s cafe database (owner decision 2026-10-16):
-- "12oz cup double" jumped from 3.7 to 15 EGP a piece on 10 Oct with no
-- audited change (8oz is 3.4, 4oz is 2.5). Back to 3.7, and the 7 sold lines
-- that froze the 15 (8.1 cups, 91.53 EGP of extra cost) are corrected:
--   order line unit cost −= cups per unit × 11.3, stock movement cost = 3.7.
-- Prices, totals and payments are untouched. Audited.
-- =====================================================================
DO $$
DECLARE _item uuid := '764db2c2-7fd8-4985-995d-e54a8b442b25'; _r record; _n int := 0; _sum numeric := 0;
BEGIN
  PERFORM set_config('app.shift_rpc_edit', 'on', true);
  FOR _r IN
    SELECT sm.id AS mv, oi.id AS line, -sm.quantity AS cups, oi.quantity AS line_qty
      FROM public.stock_movements sm JOIN public.order_items oi ON oi.id = sm.reference_id
     WHERE sm.item_id = _item AND sm.unit_cost = 15
       AND sm.movement_type = 'sale_consumption' AND sm.reference_type = 'order_item'
  LOOP
    UPDATE public.order_items SET unit_cost = round(unit_cost - (_r.cups / _r.line_qty) * 11.3, 4) WHERE id = _r.line;
    UPDATE public.stock_movements SET unit_cost = 3.7 WHERE id = _r.mv;
    _n := _n + 1; _sum := _sum + _r.cups * 11.3;
  END LOOP;
  UPDATE public.inventory_items SET cost_per_unit = 3.7, updated_at = now() WHERE id = _item;
  INSERT INTO public.audit_logs (company_id, action, module, entity_type, entity_id, old_values, new_values, reason)
  SELECT company_id, 'inventory.cost_fix', 'inventory', 'inventory_items', _item,
         jsonb_build_object('cost_per_unit', 15), jsonb_build_object('cost_per_unit', 3.7, 'lines_fixed', _n, 'cost_removed', round(_sum, 2)),
         'سعر كوب 12oz رجع 3.7 وتكلفة الفواتير اللي اتحسبت بـ 15 اتصلحت (قرار صاحب الكافيه 2026-10-16)'
    FROM public.inventory_items WHERE id = _item;
  IF _n <> 7 OR round(_sum, 2) <> 91.53 THEN RAISE EXCEPTION 'Expected 7 lines / 91.53, got % / %', _n, round(_sum, 2); END IF;
END $$;
