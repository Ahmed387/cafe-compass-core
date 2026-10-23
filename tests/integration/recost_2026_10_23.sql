BEGIN;
-- =====================================================================
-- Automatic re-costing test (2026-10-23) on the real "20s" database, in
-- ONE transaction that ends in ROLLBACK. Nothing is kept.
-- Run after 20261023000700_auto_recost_sales.sql (or paste that file in a
-- DO $pre$ BEGIN EXECUTE $mig$ ... $mig$; END $pre$; block right after
-- the helpers to test it before applying). The last block raises
-- 'RESULTS [...]' so everything rolls back.
-- =====================================================================
CREATE TEMP TABLE _results (n serial, step text, ok boolean, detail text) ON COMMIT DROP;
CREATE TEMP TABLE _snap ON COMMIT DROP AS
  SELECT oi.id, oi.unit_cost, oi.created_at, od.business_date, oi.product_id, oi.product_name
    FROM public.order_items oi JOIN public.orders od ON od.id = oi.order_id
   WHERE oi.status = 'active';
CREATE TEMP TABLE _totals ON COMMIT DROP AS
  SELECT (SELECT SUM(total) FROM public.orders) AS orders_total,
         (SELECT SUM(unit_cost * quantity) FROM public.order_items WHERE status = 'active') AS cogs,
         (SELECT count(*) FROM public.order_items WHERE status = 'active' AND unit_cost = 0) AS zero_lines,
         clock_timestamp() AS t0;

CREATE OR REPLACE FUNCTION pg_temp.act_as(_role_key text) RETURNS boolean LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', up.auth_user_id, 'role', 'authenticated')::text, true) IS NOT NULL
    FROM public.user_profiles up
    JOIN public.user_roles ur ON ur.user_id = up.id
    JOIN public.roles r ON r.id = ur.role_id
   WHERE r.key = _role_key AND up.is_active AND up.auth_user_id IS NOT NULL
   ORDER BY up.created_at LIMIT 1
$$;
CREATE OR REPLACE FUNCTION pg_temp.ok(_step text, _ok boolean, _detail text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$
  INSERT INTO _results (step, ok, detail) VALUES (_step, COALESCE(_ok, false), _detail)
$$;
-- Lines whose product recipe uses an item.
CREATE OR REPLACE FUNCTION pg_temp.uses(_item uuid) RETURNS TABLE(id uuid) LANGUAGE sql AS $$
  SELECT oi.id FROM public.order_items oi
   WHERE oi.status = 'active' AND oi.product_id IN (SELECT pr.product_id FROM public.product_recipes pr WHERE pr.item_id = _item)
$$;
CREATE OR REPLACE FUNCTION pg_temp.buy(_item uuid, _qty numeric, _cost numeric, _date date) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE _p uuid; _branch uuid;
BEGIN
  SELECT id INTO _branch FROM public.branches WHERE company_id = public.current_company_id() AND is_active ORDER BY created_at LIMIT 1;
  INSERT INTO public.purchases (company_id, branch_id, purchase_date, subtotal, total, status, notes)
  VALUES (public.current_company_id(), _branch, _date, _qty * _cost, _qty * _cost, 'draft', 'TEST recost') RETURNING id INTO _p;
  INSERT INTO public.purchase_items (purchase_id, item_id, quantity, unit_cost, line_total) VALUES (_p, _item, _qty, _cost, _qty * _cost);
  PERFORM public.receive_purchase(_p);
  RETURN _p;
END $$;

SELECT pg_temp.act_as('super_admin');

DO $$
DECLARE
  _co uuid := public.current_company_id(); _r public.cost_recalcs; _esp uuid := '3a649326-5369-4c0f-9440-3d9a92287032';
  _cut timestamptz; _n numeric; _m numeric; _k int; _j int; _dist uuid; _lemon uuid := '285539b7-c748-4012-a35e-80a9802840f9';
  _milk uuid := 'fa4bb9ed-0678-412b-93a8-23984da75634'; _txt text; _ms numeric;
BEGIN
  _ms := extract(epoch FROM clock_timestamp() - (SELECT t0 FROM _totals)) * 1000;
  -- 1. First run.
  SELECT * INTO _r FROM public.cost_recalcs WHERE company_id = _co AND reason = 'initial' ORDER BY ran_at DESC LIMIT 1;
  PERFORM pg_temp.ok('1 first run recorded', _r.id IS NOT NULL AND _r.error IS NULL,
    'lines ' || _r.lines_changed || ' delta ' || _r.cogs_delta || ' from ' || _r.first_date || ' ms ' || round(_ms));
  PERFORM pg_temp.ok('1b history = changed lines', (SELECT count(*) FROM public.order_item_cost_history WHERE recalc_id = _r.id) = _r.lines_changed);
  SELECT SUM(unit_cost * quantity) INTO _n FROM public.order_items WHERE status = 'active';
  PERFORM pg_temp.ok('1c cogs moved by the logged delta', abs(_n - (SELECT cogs FROM _totals) - _r.cogs_delta) < 0.05,
    'before ' || (SELECT cogs FROM _totals) || ' after ' || _n);
  PERFORM pg_temp.ok('1d invoice totals untouched', (SELECT SUM(total) FROM public.orders) = (SELECT orders_total FROM _totals));
  PERFORM pg_temp.ok('1e zero-cost lines fewer',
    (SELECT count(*) FROM public.order_items WHERE status = 'active' AND unit_cost = 0) < (SELECT zero_lines FROM _totals),
    (SELECT zero_lines FROM _totals) || ' → ' || (SELECT count(*) FROM public.order_items WHERE status = 'active' AND unit_cost = 0));
  PERFORM pg_temp.ok('1f old-site lines costed by name',
    (SELECT count(*) FROM public.order_items WHERE status = 'active' AND product_id IS NULL AND unit_cost > 0) > 0,
    (SELECT count(*) FROM public.order_items WHERE status = 'active' AND product_id IS NULL AND unit_cost > 0)::text);
  PERFORM pg_temp.ok('1g no line lost its cost',
    NOT EXISTS (SELECT 1 FROM public.order_items oi JOIN _snap s ON s.id = oi.id WHERE s.unit_cost > 0 AND COALESCE(oi.unit_cost, 0) = 0));
  SELECT jsonb_agg(x)::text INTO _txt FROM (
    SELECT to_char(s.business_date, 'YYYY-MM') mon, round(SUM(s.unit_cost * oi.quantity), 2) before, round(SUM(oi.unit_cost * oi.quantity), 2) after
      FROM _snap s JOIN public.order_items oi ON oi.id = s.id GROUP BY 1 ORDER BY 1) x;
  PERFORM pg_temp.ok('1h by month', true, _txt);

  -- 2. Backdated purchase: espresso dated 1/10 at double price.
  PERFORM set_config('app.recost_txn', '', true);
  UPDATE _snap s SET unit_cost = oi.unit_cost FROM public.order_items oi WHERE oi.id = s.id;
  PERFORM pg_temp.buy(_esp, 1000, 3.2, '2026-10-01');
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  SELECT * INTO _r FROM public.cost_recalcs WHERE company_id = _co ORDER BY ran_at DESC, id LIMIT 1;
  PERFORM pg_temp.ok('2 purchase re-costs on its own', _r.reason = 'purchase' AND _r.lines_changed > 0 AND _r.cogs_delta > 0,
    'reason ' || _r.reason || ' lines ' || _r.lines_changed || ' delta ' || _r.cogs_delta || ' from ' || _r.first_date || ' err ' || COALESCE(_r.error, '-'));
  _cut := public.business_day_start('2026-10-01', _co);
  PERFORM pg_temp.ok('2b sales before the invoice date unchanged', NOT EXISTS (
    SELECT 1 FROM public.order_items oi JOIN _snap s ON s.id = oi.id WHERE s.created_at < _cut AND oi.unit_cost <> s.unit_cost));
  SELECT count(*) INTO _k FROM public.order_items oi JOIN _snap s ON s.id = oi.id
   WHERE s.created_at >= _cut AND oi.id IN (SELECT id FROM pg_temp.uses(_esp)) AND oi.unit_cost > s.unit_cost;
  PERFORM pg_temp.ok('2c espresso drinks from 1/10 cost more', _k > 0, _k::text);
  PERFORM pg_temp.ok('2d super admin note', EXISTS (SELECT 1 FROM public.notifications WHERE type = 'cost.recalc' AND data->>'recalc_id' = _r.id::text),
    (SELECT body FROM public.notifications WHERE type = 'cost.recalc' AND data->>'recalc_id' = _r.id::text LIMIT 1));
  PERFORM pg_temp.ok('2e stock use follows the average', NOT EXISTS (
    SELECT 1 FROM public.stock_movements m WHERE m.item_id = _esp AND m.movement_type = 'sale_consumption' AND m.created_at >= _cut
       AND m.unit_cost <> (SELECT t.avg_cost FROM public._cost_timeline(_co) t WHERE t.item_id = _esp AND t.ts <= m.created_at ORDER BY t.ts DESC LIMIT 1)));
  PERFORM pg_temp.ok('2f opening cost kept, item cost averaged',
    (SELECT opening_cost FROM public.inventory_items WHERE id = _esp) = 1.6 AND (SELECT cost_per_unit FROM public.inventory_items WHERE id = _esp) > 1.6,
    (SELECT opening_cost || ' / ' || cost_per_unit FROM public.inventory_items WHERE id = _esp));

  -- 3. Paid days never change.
  BEGIN
    _dist := public.execute_payout('2026-09-01', '2026-09-30', 0, 'TEST');
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('3 payout for September', false, SQLERRM); END;
  IF _dist IS NOT NULL THEN
    PERFORM set_config('app.recost_txn', '', true);
    UPDATE _snap s SET unit_cost = oi.unit_cost FROM public.order_items oi WHERE oi.id = s.id;
    PERFORM pg_temp.buy(_esp, 1000, 10, '2026-09-20');
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
    PERFORM pg_temp.ok('3 paid September untouched', NOT EXISTS (
      SELECT 1 FROM public.order_items oi JOIN _snap s ON s.id = oi.id WHERE s.business_date <= '2026-09-30' AND oi.unit_cost <> s.unit_cost));
    SELECT count(*) INTO _k FROM public.order_items oi JOIN _snap s ON s.id = oi.id
     WHERE s.business_date >= '2026-10-01' AND oi.unit_cost <> s.unit_cost;
    PERFORM pg_temp.ok('3b unpaid October re-costed', _k > 0, _k::text);
  END IF;

  -- 4. A recipe added later costs that product's past sales (old site too).
  PERFORM set_config('app.recost_txn', '', true);
  INSERT INTO public.product_recipes (product_id, item_id, quantity) VALUES (_lemon, _milk, 100);
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  SELECT count(*) FILTER (WHERE unit_cost > 0), count(*) INTO _k, _j FROM public.order_items oi
   WHERE oi.status = 'active' AND (oi.product_id = _lemon OR (oi.product_id IS NULL AND oi.product_name = 'ليمون نعناع / Lemon Mint'))
     AND NOT EXISTS (SELECT 1 FROM public.orders o WHERE o.id = oi.order_id AND o.business_date <= '2026-09-30' AND _dist IS NOT NULL);
  PERFORM pg_temp.ok('4 new recipe costs its unpaid sales', _k = _j AND _j > 0, _k || '/' || _j);

  -- 4b. Editing the cost on an item with no purchase yet moves its opening cost.
  PERFORM set_config('app.recost_txn', '', true);
  UPDATE public.inventory_items SET cost_per_unit = 0.05 WHERE id = _milk;
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  SELECT * INTO _r FROM public.cost_recalcs WHERE company_id = _co ORDER BY ran_at DESC, id LIMIT 1;
  PERFORM pg_temp.ok('4b editing an item cost (no purchase yet) re-costs', _r.reason = 'item_cost' AND _r.lines_changed > 0,
    'reason ' || _r.reason || ' lines ' || _r.lines_changed || ' delta ' || _r.cogs_delta);

  -- 5. Only a super admin can run it by hand.
  PERFORM pg_temp.act_as('cashier');
  BEGIN
    PERFORM public.recost_sales_now();
    PERFORM pg_temp.ok('5 cashier blocked', false);
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('5 cashier blocked', true, SQLERRM); END;
  PERFORM pg_temp.act_as('super_admin');
  PERFORM pg_temp.ok('6 nightly job scheduled', EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'recost-sales-nightly'));
  PERFORM pg_temp.ok('7 no failed runs', NOT EXISTS (SELECT 1 FROM public.cost_recalcs WHERE error IS NOT NULL),
    (SELECT string_agg(error, '; ') FROM public.cost_recalcs WHERE error IS NOT NULL));

  RAISE EXCEPTION 'RESULTS %', (SELECT jsonb_agg(jsonb_build_array(step, ok, detail) ORDER BY n) FROM _results);
END $$;

ROLLBACK;
