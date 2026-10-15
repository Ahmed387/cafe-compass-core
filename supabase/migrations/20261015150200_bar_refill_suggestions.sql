-- =====================================================================
-- Two warehouses made workable (owner decision 2026-10-15: keep a main store
-- and the café/bar stock that is actually used).
-- Sales take stock from the bar; the bar is refilled from the main store.
-- Refills were never done, so 66 bar items went negative. This suggests the
-- quantity to move per item: enough for _days of average use over the last
-- 7 days (never below the bar's reorder level), minus what the bar holds,
-- capped at what the main store has.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.bar_refill_suggestions(_branch_id uuid, _days integer DEFAULT 2)
RETURNS TABLE(item_id uuid, name text, unit text, main_qty numeric, bar_qty numeric, bar_min numeric,
  daily_use numeric, suggested numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NOT public.has_permission('inventory.view') OR NOT public.can_access_branch(_branch_id) THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;
  RETURN QUERY
  WITH use7 AS (
    SELECT sm.item_id, GREATEST(SUM(-sm.quantity), 0) / 7.0 AS per_day
      FROM public.stock_movements sm
     WHERE sm.branch_id = _branch_id AND sm.movement_type IN ('sale_consumption', 'sale_return')
       AND sm.created_at >= now() - interval '7 days'
     GROUP BY sm.item_id
  ), base AS (
    SELECT i.id, COALESCE(NULLIF(i.name_ar, ''), i.name) AS nm, i.unit AS un,
           COALESCE(bs.quantity, 0) - COALESCE(bs.bar_quantity, 0) AS main_q,
           COALESCE(bs.bar_quantity, 0) AS bar_q, COALESCE(i.bar_min_qty, 0) AS bmin,
           COALESCE(u.per_day, 0) AS per_day
      FROM public.inventory_items i
      LEFT JOIN public.branch_stock bs ON bs.item_id = i.id AND bs.branch_id = _branch_id
      LEFT JOIN use7 u ON u.item_id = i.id
     WHERE i.company_id = public.current_company_id() AND i.is_active
  )
  SELECT b.id, b.nm, b.un, round(b.main_q, 3), round(b.bar_q, 3), b.bmin, round(b.per_day, 3),
         CASE WHEN b.main_q <= 0 THEN 0
              ELSE LEAST(b.main_q,
                CASE WHEN lower(b.un) IN ('pcs', 'piece', 'pc', 'unit', 'box')
                     THEN ceil(GREATEST(GREATEST(b.bmin, b.per_day * GREATEST(_days, 1)) - b.bar_q, 0))
                     ELSE round(GREATEST(GREATEST(b.bmin, b.per_day * GREATEST(_days, 1)) - b.bar_q, 0), 1) END) END
    FROM base b
   ORDER BY (b.bar_q < 0) DESC, b.nm;
END $$;
REVOKE ALL ON FUNCTION public.bar_refill_suggestions(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bar_refill_suggestions(uuid, integer) TO authenticated, service_role;
