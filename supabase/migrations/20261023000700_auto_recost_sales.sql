-- Automatic re-costing of past sales.
--
-- When a purchase invoice or opening stock is entered (also with an old date),
-- a recipe is added or changed, or an item's cost is edited, the cost of every
-- sold line whose day is not yet paid out to partners is recomputed:
--
-- * Each stock item starts at its opening cost (the cost typed on the item,
--   kept in opening_cost until the item's first purchase). Purchases blend in
--   as a moving average from their invoice date (purchase_date), using the
--   stock on hand replayed from all movements.
-- * Stock movements recorded before this change are not used as prices: many
--   were typed in the wrong unit and corrected on the item later.
-- * A sold line costs its product recipe at that average on the sale time.
--   Lines from the old site (no product link) are matched by product name.
-- * Lines without a recipe keep their cost. Days already paid out never change.
-- * Every change is kept in order_item_cost_history (old and new cost), and
--   super admins get a note with the effect on profit.

-- 1. Log tables --------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.cost_recalcs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  reason text NOT NULL,
  ran_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  lines_changed int NOT NULL DEFAULT 0,
  cogs_delta numeric NOT NULL DEFAULT 0,
  first_date date,
  error text,
  created_by uuid
);
CREATE INDEX IF NOT EXISTS cost_recalcs_company_idx ON public.cost_recalcs (company_id, ran_at DESC);
ALTER TABLE public.cost_recalcs ENABLE ROW LEVEL SECURITY;
CREATE POLICY cost_recalcs_read ON public.cost_recalcs FOR SELECT TO authenticated
  USING (company_id = public.current_company_id() AND public.is_super_admin());
REVOKE ALL ON public.cost_recalcs FROM anon;

CREATE TABLE IF NOT EXISTS public.order_item_cost_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  recalc_id uuid NOT NULL REFERENCES public.cost_recalcs(id),
  order_item_id uuid NOT NULL REFERENCES public.order_items(id),
  old_unit_cost numeric,
  old_waste_cost numeric,
  new_unit_cost numeric,
  new_waste_cost numeric
);
CREATE INDEX IF NOT EXISTS order_item_cost_history_item_idx ON public.order_item_cost_history (order_item_id);
CREATE INDEX IF NOT EXISTS order_item_cost_history_recalc_idx ON public.order_item_cost_history (recalc_id);
ALTER TABLE public.order_item_cost_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY order_item_cost_history_read ON public.order_item_cost_history FOR SELECT TO authenticated
  USING (public.is_super_admin() AND EXISTS (
    SELECT 1 FROM public.cost_recalcs r WHERE r.id = recalc_id AND r.company_id = public.current_company_id()));
REVOKE ALL ON public.order_item_cost_history FROM anon;

-- 2. Opening cost and cost events ---------------------------------------------
ALTER TABLE public.inventory_items ADD COLUMN IF NOT EXISTS opening_cost numeric;
ALTER TABLE public.stock_movements ADD COLUMN IF NOT EXISTS cost_event boolean NOT NULL DEFAULT false;
UPDATE public.inventory_items SET opening_cost = cost_per_unit WHERE opening_cost IS NULL;

-- A stock-in with a price from now on (purchase invoice or quick purchase) moves the average.
CREATE OR REPLACE FUNCTION public.trg_stock_cost_event()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  NEW.cost_event := NEW.movement_type = 'purchase' AND COALESCE(NEW.quantity, 0) > 0 AND COALESCE(NEW.unit_cost, 0) > 0;
  RETURN NEW;
END $function$;
CREATE OR REPLACE TRIGGER t_stock_cost_event BEFORE INSERT ON public.stock_movements
  FOR EACH ROW EXECUTE FUNCTION public.trg_stock_cost_event();

-- The cost typed on an item is its opening cost until the item has a purchase.
-- Averages written by purchases (app.cost_auto) never touch it.
CREATE OR REPLACE FUNCTION public.trg_item_opening_cost()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.opening_cost := COALESCE(NEW.opening_cost, NEW.cost_per_unit);
  ELSIF NEW.cost_per_unit IS DISTINCT FROM OLD.cost_per_unit
        AND COALESCE(current_setting('app.cost_auto', true), '') <> 'on'
        AND NOT EXISTS (SELECT 1 FROM public.stock_movements m WHERE m.item_id = NEW.id AND m.cost_event) THEN
    NEW.opening_cost := NEW.cost_per_unit;
  END IF;
  RETURN NEW;
END $function$;
CREATE OR REPLACE TRIGGER t_item_opening_cost BEFORE INSERT OR UPDATE ON public.inventory_items
  FOR EACH ROW EXECUTE FUNCTION public.trg_item_opening_cost();

CREATE OR REPLACE FUNCTION public.apply_weighted_cost(_item_id uuid, _branch_id uuid, _qty numeric, _unit_cost numeric)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _old_cost numeric; _on_hand numeric; _new numeric;
BEGIN
  IF COALESCE(_qty, 0) <= 0 OR COALESCE(_unit_cost, 0) <= 0 THEN RETURN NULL; END IF;
  SELECT COALESCE(cost_per_unit, 0) INTO _old_cost FROM public.inventory_items WHERE id = _item_id FOR UPDATE;
  -- Stock on hand across branches before this delivery (never negative in the average).
  SELECT GREATEST(COALESCE(SUM(quantity), 0), 0) INTO _on_hand FROM public.branch_stock WHERE item_id = _item_id;
  _new := CASE WHEN _on_hand <= 0 OR _old_cost <= 0 THEN _unit_cost
               ELSE (_on_hand * _old_cost + _qty * _unit_cost) / (_on_hand + _qty) END;
  PERFORM set_config('app.cost_auto', 'on', true);
  UPDATE public.inventory_items SET cost_per_unit = round(_new, 6), updated_at = now() WHERE id = _item_id;
  PERFORM set_config('app.cost_auto', 'off', true);
  RETURN _new;
END $function$;

CREATE OR REPLACE FUNCTION public.trg_average_cost_on_manual_purchase()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.movement_type = 'purchase' AND COALESCE(NEW.unit_cost, 0) > 0 AND COALESCE(NEW.reference_type, '') <> 'purchase' THEN
    -- Stock already includes this movement, so remove it before averaging.
    PERFORM set_config('app.cost_auto', 'on', true);
    UPDATE public.inventory_items i
       SET cost_per_unit = round(CASE
             WHEN GREATEST(NEW.balance_after - NEW.quantity, 0) <= 0 OR COALESCE(i.cost_per_unit, 0) <= 0 THEN NEW.unit_cost
             ELSE (GREATEST(NEW.balance_after - NEW.quantity, 0) * i.cost_per_unit + NEW.quantity * NEW.unit_cost)
                  / (GREATEST(NEW.balance_after - NEW.quantity, 0) + NEW.quantity) END, 6),
           updated_at = now()
     WHERE i.id = NEW.item_id;
    PERFORM set_config('app.cost_auto', 'off', true);
  END IF;
  RETURN NEW;
END $function$;

-- 3. Cost timeline -----------------------------------------------------------
-- One row for the opening cost, then one per priced stock-in with the item's
-- moving-average cost right after it. Transfers move stock between places of
-- the same café, so they never change the average.
CREATE OR REPLACE FUNCTION public._cost_timeline(_company uuid)
 RETURNS TABLE(item_id uuid, ts timestamptz, avg_cost numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH RECURSIVE ev AS (
    SELECT m.item_id, m.id, m.quantity, COALESCE(m.unit_cost, 0) AS unit_cost,
           CASE WHEN m.reference_type = 'purchase' AND p.purchase_date IS NOT NULL
                THEN LEAST(m.created_at, public.business_day_start(p.purchase_date, _company))
                ELSE m.created_at END AS ts,
           m.cost_event AS costed
      FROM public.stock_movements m
      LEFT JOIN public.purchases p ON m.reference_type = 'purchase' AND p.id = m.reference_id
     WHERE m.company_id = _company AND m.movement_type NOT IN ('transfer_in', 'transfer_out')
  ), o AS (
    SELECT ev.*, row_number() OVER (PARTITION BY ev.item_id ORDER BY ev.ts, ev.id) AS rn FROM ev
  ), walk AS (
    SELECT i.id AS item_id, 0::bigint AS rn, '-infinity'::timestamptz AS ts, 0::numeric AS onhand,
           COALESCE(NULLIF(i.opening_cost, 0), NULLIF(i.cost_per_unit, 0), 0)::numeric AS avg_cost, true AS costed
      FROM public.inventory_items i WHERE i.company_id = _company
    UNION ALL
    SELECT o.item_id, o.rn, o.ts, w.onhand + o.quantity,
           CASE WHEN NOT o.costed THEN w.avg_cost
                WHEN w.onhand <= 0 OR w.avg_cost <= 0 THEN o.unit_cost
                ELSE (w.onhand * w.avg_cost + o.quantity * o.unit_cost) / (w.onhand + o.quantity) END,
           o.costed
      FROM walk w JOIN o ON o.item_id = w.item_id AND o.rn = w.rn + 1
  )
  SELECT walk.item_id, walk.ts, round(walk.avg_cost, 6) FROM walk WHERE walk.costed
$function$;

-- 3. Re-costing ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.recost_sales(_company uuid, _reason text DEFAULT 'manual')
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _rid uuid := gen_random_uuid(); _n int := 0; _delta numeric := 0; _first date;
  _mv int := 0; _why text;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('recost:' || _company::text));
  PERFORM set_config('app.recost_txn', txid_current()::text, true);
  INSERT INTO public.cost_recalcs (id, company_id, reason, created_by)
  VALUES (_rid, _company, COALESCE(_reason, 'manual'), public.current_profile_id());

  -- Sold lines on days not yet paid out.
  WITH tl AS MATERIALIZED (SELECT * FROM public._cost_timeline(_company)),
  lines AS (
    SELECT oi.id, oi.quantity, oi.unit_cost AS old_c, oi.unit_waste_cost AS old_w, oi.created_at AS ts,
           od.business_date, COALESCE(oi.product_id, pm.id) AS pid, COALESCE(oi.size_id, sm.id) AS sid
      FROM public.order_items oi
      JOIN public.orders od ON od.id = oi.order_id
      -- Old-site lines carry only the product name ("عربي / English").
      LEFT JOIN LATERAL (
        SELECT p.id FROM public.products p
         WHERE oi.product_id IS NULL AND p.company_id = _company
           AND oi.product_name IN (COALESCE(p.name_ar, '') || ' / ' || p.name, p.name, p.name_ar)
         ORDER BY p.is_active DESC, p.created_at LIMIT 1) pm ON true
      LEFT JOIN LATERAL (
        SELECT ps.id FROM public.product_sizes ps
         WHERE oi.size_id IS NULL AND ps.product_id = pm.id AND oi.size_name IS NOT NULL
           AND split_part(oi.size_name, ' · ', 1) IN (COALESCE(ps.name_ar, '') || ' / ' || ps.name, ps.name, ps.name_ar)
         ORDER BY ps.is_active DESC, ps.display_order LIMIT 1) sm ON true
     WHERE od.company_id = _company AND oi.status = 'active'
       AND NOT EXISTS (SELECT 1 FROM public.profit_distributions d
                        WHERE d.company_id = _company AND d.status = 'active' AND d.range_from IS NOT NULL
                          AND od.business_date BETWEEN d.range_from AND d.range_to)
  ), costs AS (
    SELECT l.id, l.quantity, l.old_c, l.old_w, l.business_date,
           round(SUM(pr.quantity * c.cost), 2) AS new_c,
           round(SUM(pr.quantity * c.cost * COALESCE(i.waste_pct, 0) / 100.0), 4) AS new_w
      FROM lines l
      JOIN public.product_recipes pr ON pr.product_id = l.pid AND (pr.size_id IS NULL OR pr.size_id = l.sid)
      JOIN public.inventory_items i ON i.id = pr.item_id
      CROSS JOIN LATERAL (SELECT COALESCE(
          (SELECT t.avg_cost FROM tl t WHERE t.item_id = pr.item_id AND t.ts <= l.ts ORDER BY t.ts DESC LIMIT 1), 0) AS cost) c
     GROUP BY l.id, l.quantity, l.old_c, l.old_w, l.business_date
  ), chg AS (
    SELECT * FROM costs
     WHERE new_c > 0 AND (new_c IS DISTINCT FROM old_c OR new_w IS DISTINCT FROM COALESCE(old_w, 0))
  ), h AS (
    INSERT INTO public.order_item_cost_history (recalc_id, order_item_id, old_unit_cost, old_waste_cost, new_unit_cost, new_waste_cost)
    SELECT _rid, chg.id, chg.old_c, chg.old_w, chg.new_c, chg.new_w FROM chg
    RETURNING 1
  ), u AS (
    UPDATE public.order_items oi SET unit_cost = chg.new_c, unit_waste_cost = chg.new_w
      FROM chg WHERE oi.id = chg.id
    RETURNING 1
  )
  SELECT count(*), COALESCE(SUM((chg.new_c - COALESCE(chg.old_c, 0)) * chg.quantity), 0), MIN(chg.business_date)
    INTO _n, _delta, _first FROM chg;

  -- Stock used by sales (and returned) follows the same average, for stock reports.
  WITH tl AS MATERIALIZED (SELECT * FROM public._cost_timeline(_company)),
  mc AS (
    SELECT m.id, m.unit_cost AS old_c, round(
        (SELECT t.avg_cost FROM tl t WHERE t.item_id = m.item_id AND t.ts <= m.created_at ORDER BY t.ts DESC LIMIT 1), 6) AS new_c
      FROM public.stock_movements m
     WHERE m.company_id = _company AND m.movement_type IN ('sale_consumption', 'sale_return')
       AND NOT EXISTS (SELECT 1 FROM public.profit_distributions d
                        WHERE d.company_id = _company AND d.status = 'active' AND d.range_from IS NOT NULL
                          AND m.business_date BETWEEN d.range_from AND d.range_to)
  ), u AS (
    UPDATE public.stock_movements m SET unit_cost = mc.new_c
      FROM mc WHERE m.id = mc.id AND mc.new_c > 0 AND mc.new_c IS DISTINCT FROM mc.old_c
    RETURNING 1
  )
  SELECT count(*) INTO _mv FROM u;

  UPDATE public.cost_recalcs SET lines_changed = _n, cogs_delta = round(_delta, 2), first_date = _first WHERE id = _rid;

  IF abs(_delta) >= 1 THEN
    _why := CASE _reason
      WHEN 'purchase' THEN 'دخول فاتورة شراء أو مخزون'
      WHEN 'recipe' THEN 'تعديل وصفة منتج'
      WHEN 'item_cost' THEN 'تعديل تكلفة أول المدة لصنف'
      WHEN 'nightly' THEN 'المراجعة اليومية'
      WHEN 'initial' THEN 'تشغيل إعادة الحساب لأول مرة'
      ELSE 'إعادة الحساب' END;
    INSERT INTO public.notifications (company_id, user_id, type, severity, title, body, data)
    SELECT _company, up.id, 'cost.recalc', 'info', 'اتعادت تكلفة المبيعات',
      'بعد ' || _why || '، اتعدلت تكلفة ' || _n || ' صنف مباع من يوم ' || to_char(_first, 'DD/MM/YYYY') ||
      '. تكلفة المبيعات ' || CASE WHEN _delta > 0 THEN 'زادت ' ELSE 'قلت ' END ||
      to_char(abs(_delta), 'FM999999990.00') || ' ج.م، فصافي الربح ' ||
      CASE WHEN _delta > 0 THEN 'قل' ELSE 'زاد' END || ' بنفس المبلغ. الأيام اللي اتوزعت أرباحها متغيرتش.',
      jsonb_build_object('recalc_id', _rid, 'lines', _n, 'cogs_delta', round(_delta, 2), 'from', _first, 'reason', _reason)
      FROM public.user_profiles up
      JOIN public.user_roles ur ON ur.user_id = up.id JOIN public.roles r ON r.id = ur.role_id
     WHERE up.company_id = _company AND up.is_active AND r.key = 'super_admin';
  END IF;

  RETURN jsonb_build_object('recalc_id', _rid, 'lines_changed', _n, 'cogs_delta', round(_delta, 2),
    'first_date', _first, 'movements_changed', _mv);
END $function$;

-- Super admin button.
CREATE OR REPLACE FUNCTION public.recost_sales_now()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  RETURN public.recost_sales(public.current_company_id(), 'manual');
END $function$;

-- 4. Automatic runs ------------------------------------------------------------
-- Runs once per transaction, when it commits, after all its rows are in.
-- A failure never blocks the purchase or recipe being saved; it is logged
-- and the nightly run tries again.
CREATE OR REPLACE FUNCTION public.trg_queue_recost()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _company uuid; _reason text := TG_ARGV[0];
BEGIN
  IF current_setting('app.recost_txn', true) = txid_current()::text THEN RETURN NULL; END IF;
  IF TG_TABLE_NAME = 'product_recipes' THEN
    SELECT p.company_id INTO _company FROM public.products p WHERE p.id = NEW.product_id;
  ELSE
    _company := NEW.company_id;
  END IF;
  IF _company IS NULL THEN RETURN NULL; END IF;
  PERFORM set_config('app.recost_txn', txid_current()::text, true);
  BEGIN
    PERFORM public.recost_sales(_company, _reason);
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO public.cost_recalcs (company_id, reason, error) VALUES (_company, _reason, SQLERRM);
    RAISE WARNING 'recost_sales failed: %', SQLERRM;
  END;
  RETURN NULL;
END $function$;

DO $$ BEGIN
  CREATE CONSTRAINT TRIGGER t_recost_on_stock_in AFTER INSERT ON public.stock_movements
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    WHEN (NEW.cost_event)
    EXECUTE FUNCTION public.trg_queue_recost('purchase');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE CONSTRAINT TRIGGER t_recost_on_stock_edit AFTER UPDATE OF quantity, unit_cost ON public.stock_movements
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    WHEN (NEW.cost_event AND (OLD.quantity IS DISTINCT FROM NEW.quantity OR OLD.unit_cost IS DISTINCT FROM NEW.unit_cost))
    EXECUTE FUNCTION public.trg_queue_recost('purchase');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE CONSTRAINT TRIGGER t_recost_on_recipe AFTER INSERT OR UPDATE ON public.product_recipes
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION public.trg_queue_recost('recipe');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE CONSTRAINT TRIGGER t_recost_on_item_cost AFTER UPDATE ON public.inventory_items
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    WHEN (OLD.opening_cost IS DISTINCT FROM NEW.opening_cost)
    EXECUTE FUNCTION public.trg_queue_recost('item_cost');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

REVOKE ALL ON FUNCTION public._cost_timeline(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.recost_sales(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.trg_queue_recost() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.trg_stock_cost_event() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.trg_item_opening_cost() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.recost_sales_now() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.recost_sales_now() TO authenticated;

-- Nightly safety net (02:30 UTC = early morning in Cairo).
SELECT cron.schedule('recost-sales-nightly', '30 2 * * *',
  'SELECT public.recost_sales(id, ''nightly'') FROM public.companies');

-- First run: cost the past with the stock and recipes entered so far.
SELECT public.recost_sales(id, 'initial') FROM public.companies;
