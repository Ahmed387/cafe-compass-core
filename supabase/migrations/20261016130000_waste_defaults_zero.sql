-- =====================================================================
-- Waste % is per ingredient and starts at 0 (owner: "not every item has
-- waste"). The 2026-10-12 costing migration meant this, but the live column
-- already existed with DEFAULT 5, so every ingredient silently got 5% and the
-- owner had to zero items one by one.
--   * new ingredients start at 0
--   * waste_factor() falls back to 0, not 5
--   * ingredients still on the untouched 5% default (never set by anyone,
--     nothing in the audit log) go back to 0; each change is audited
-- Waste % never changes sale cost; it is the stocktake tolerance only.
-- =====================================================================
ALTER TABLE public.inventory_items ALTER COLUMN waste_pct SET DEFAULT 0;

CREATE OR REPLACE FUNCTION public.waste_factor(_item_id uuid)
RETURNS numeric LANGUAGE sql STABLE SET search_path TO 'public' AS $$
  SELECT 1 + COALESCE((SELECT waste_pct FROM public.inventory_items WHERE id = _item_id), 0) / 100.0
$$;

WITH reset AS (
  UPDATE public.inventory_items i SET waste_pct = 0, updated_at = now()
   WHERE i.waste_pct = 5
     AND NOT EXISTS (SELECT 1 FROM public.audit_logs a
                      WHERE a.action = 'inventory.waste_pct' AND a.entity_id = i.id)
  RETURNING i.id, i.company_id)
INSERT INTO public.audit_logs (company_id, action, module, entity_type, entity_id, old_values, new_values, reason)
SELECT company_id, 'inventory.waste_pct', 'inventory', 'inventory_items', id,
       jsonb_build_object('waste_pct', 5), jsonb_build_object('waste_pct', 0),
       'الهالك الافتراضي 5% اتشال: كل خامة بتبدأ من 0 (قرار صاحب الكافيه 2026-10-16)'
  FROM reset;
