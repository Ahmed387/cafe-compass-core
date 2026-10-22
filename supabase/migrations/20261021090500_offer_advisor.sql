-- =====================================================================
-- Smart offers (owner request 2026-10-20).
--   1) offer_advisor_data: per product, what sold in the period (qty,
--      revenue, cost, orders, last sale) and how many days the slowest-moving
--      ingredient in its recipe still covers at the current pace. The page
--      turns this into suggestions with a reason, cost and margin.
--   2) product_offers.target_margin: the margin % the super admin sets for
--      each offer. save_product_offer refuses a price under it.
--   3) public_menu_offers: active offers for the public menu (no sign-in).
-- No existing data is changed.
-- =====================================================================
ALTER TABLE public.product_offers ADD COLUMN IF NOT EXISTS target_margin numeric
  CHECK (target_margin IS NULL OR (target_margin >= 0 AND target_margin < 100));
COMMENT ON COLUMN public.product_offers.target_margin IS
  'Minimum profit margin % for this offer, set by the super admin. NULL = only the 25% safety floor.';

CREATE OR REPLACE FUNCTION public.offer_advisor_data(_from date DEFAULT (CURRENT_DATE - 30), _to date DEFAULT CURRENT_DATE)
RETURNS TABLE (product_id uuid, name text, name_ar text, category text, image_url text, base_price numeric,
  unit_cost numeric, qty numeric, revenue numeric, cost numeric, orders_count bigint, last_sold_at timestamptz,
  stock_item text, stock_days numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  WITH days AS (SELECT GREATEST(_to - _from + 1, 1)::numeric AS n),
  usage AS (
    -- Ingredient pace: what sales consumed per day in the period.
    SELECT sm.item_id, SUM(abs(sm.quantity)) / (SELECT n FROM days) AS per_day
      FROM public.stock_movements sm
      JOIN public.inventory_items ii ON ii.id = sm.item_id AND ii.company_id = public.current_company_id()
     WHERE sm.movement_type = 'sale_consumption'
       AND public.business_date(sm.created_at, ii.company_id) BETWEEN _from AND _to
     GROUP BY sm.item_id),
  on_hand AS (
    SELECT bs.item_id, SUM(bs.quantity) AS qty FROM public.branch_stock bs
      JOIN public.inventory_items ii ON ii.id = bs.item_id AND ii.company_id = public.current_company_id()
     GROUP BY bs.item_id),
  cover AS (
    -- The ingredient with the MOST days of stock left is the one worth pushing.
    SELECT DISTINCT ON (pr.product_id) pr.product_id, COALESCE(ii.name_ar, ii.name) AS item_name,
           round(oh.qty / NULLIF(u.per_day, 0), 1) AS days_left
      FROM public.product_recipes pr
      JOIN public.inventory_items ii ON ii.id = pr.item_id AND ii.is_active
      JOIN on_hand oh ON oh.item_id = pr.item_id AND oh.qty > 0
      LEFT JOIN usage u ON u.item_id = pr.item_id
     ORDER BY pr.product_id, (oh.qty / NULLIF(u.per_day, 0)) DESC NULLS FIRST)
  SELECT d.product_id, d.name, d.name_ar, d.category, d.image_url, d.base_price, d.unit_cost,
         d.qty, d.revenue, d.cost, d.orders_count, d.last_sold_at,
         c.item_name, c.days_left
    FROM public.product_demand(_from, _to) d
    LEFT JOIN cover c ON c.product_id = d.product_id
$$;
REVOKE EXECUTE ON FUNCTION public.offer_advisor_data(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.offer_advisor_data(date, date) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION pg_temp.patch_fn(_sig regprocedure, _old text, _new text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE _def text := pg_get_functiondef(_sig);
BEGIN
  -- Editors on Windows paste CRLF line ends; function sources use LF.
  _old := replace(_old, E'\r', ''); _new := replace(_new, E'\r', '');
  IF position(_new IN _def) > 0 THEN RAISE NOTICE '% already patched', _sig; RETURN; END IF;
  IF position(_old IN _def) = 0 THEN RAISE EXCEPTION 'Expected text not found in %: %', _sig, left(_old, 60); END IF;
  IF position(_old IN substr(_def, position(_old IN _def) + 1)) > 0 THEN
    RAISE EXCEPTION 'Anchor appears more than once in %', _sig;
  END IF;
  EXECUTE replace(_def, _old, _new);
END $$;

-- The super admin's margin for the offer is a hard floor, on top of the 25% safety floor.
SELECT pg_temp.patch_fn('public.save_product_offer(jsonb)'::regprocedure,
$o$  -- Overlapping active offers on the same product are rejected$o$,
$n$  IF NULLIF(_payload->>'target_margin', '') IS NOT NULL THEN
    IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'السوبر أدمن بس هو اللي يحدد نسبة ربح العرض'; END IF;
    IF (_payload->>'target_margin')::numeric < 0 OR (_payload->>'target_margin')::numeric >= 100 THEN
      RAISE EXCEPTION 'نسبة الربح لازم تكون بين 0 و 99';
    END IF;
    IF _preview.live_cost > 0
       AND _price < round(_preview.live_cost / (1 - (_payload->>'target_margin')::numeric / 100), 2) THEN
      RAISE EXCEPTION 'السعر ده ربحه أقل من النسبة اللي حددتها (%%%). أقل سعر: % ج.م',
        (_payload->>'target_margin')::numeric,
        to_char(round(_preview.live_cost / (1 - (_payload->>'target_margin')::numeric / 100), 2), 'FM999999990.00');
    END IF;
  END IF;

  -- Overlapping active offers on the same product are rejected$n$);

SELECT pg_temp.patch_fn('public.save_product_offer(jsonb)'::regprocedure,
$o$    RETURNING id INTO _id;
    PERFORM public.log_audit('offer.create'$o$,
$n$    RETURNING id INTO _id;
    UPDATE public.product_offers SET target_margin = NULLIF(_payload->>'target_margin', '')::numeric WHERE id = _id;
    PERFORM public.log_audit('offer.create'$n$);

SELECT pg_temp.patch_fn('public.save_product_offer(jsonb)'::regprocedure,
$o$      image_path = NULLIF(btrim(COALESCE(_payload->>'image_path','')),''),
      updated_at = now()$o$,
$n$      image_path = NULLIF(btrim(COALESCE(_payload->>'image_path','')),''),
      target_margin = CASE WHEN _payload ? 'target_margin' THEN NULLIF(_payload->>'target_margin', '')::numeric
                           ELSE target_margin END,
      updated_at = now()$n$);

-- Public menu: what is on offer today. Names and prices only.
CREATE OR REPLACE FUNCTION public.public_menu_offers()
RETURNS TABLE (id uuid, title text, offer_type text, offer_price numeric, base_price numeric,
  product_name text, product_name_ar text, image_path text, ends_at date)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT po.id, po.title, po.offer_type, po.offer_price, po.base_price_snapshot,
         p.name, p.name_ar, po.image_path, po.ends_at
    FROM public.product_offers po
    LEFT JOIN public.products p ON p.id = po.product_id
   WHERE po.is_active
     AND po.starts_at <= public.business_date(now(), po.company_id)
     AND (po.ends_at IS NULL OR po.ends_at >= public.business_date(now(), po.company_id))
     AND public.offers_enabled(po.company_id)
   ORDER BY po.created_at DESC
   LIMIT 20
$$;
REVOKE EXECUTE ON FUNCTION public.public_menu_offers() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.public_menu_offers() TO anon, authenticated, service_role;
