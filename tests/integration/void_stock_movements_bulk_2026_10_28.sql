BEGIN;
-- =====================================================================
-- Cancelling several manual stock movements at once (2026-10-28) on the
-- real "20s" database, in ONE transaction that ends in ROLLBACK. Nothing is
-- kept. Run after 20261028000100_void_stock_movements_bulk.sql. The last
-- block raises 'RESULTS [...]' so everything rolls back.
-- =====================================================================
CREATE TEMP TABLE _results (n serial, step text, ok boolean, detail text);

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
CREATE OR REPLACE FUNCTION pg_temp.stock(_item uuid, _branch uuid) RETURNS numeric LANGUAGE sql AS $$
  SELECT quantity FROM public.branch_stock WHERE item_id = _item AND branch_id = _branch
$$;
CREATE OR REPLACE FUNCTION pg_temp.blocked(_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE _sql;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN RETURN SQLERRM;
END $$;

SELECT pg_temp.act_as('super_admin');

DO $$
DECLARE
  _co uuid := public.current_company_id(); _item uuid; _item2 uuid; _branch uuid; _s1 numeric; _s2 numeric;
  _a uuid; _b uuid; _c uuid; _sale uuid; _res jsonb; _txt text; _k int; _t0 timestamptz := clock_timestamp();
BEGIN
  SELECT bs.item_id, bs.branch_id INTO _item, _branch FROM public.branch_stock bs JOIN public.inventory_items i ON i.id = bs.item_id
   WHERE i.company_id = _co AND i.is_active AND bs.quantity >= 20 AND i.cost_per_unit > 0 ORDER BY bs.quantity LIMIT 1;
  SELECT bs.item_id INTO _item2 FROM public.branch_stock bs JOIN public.inventory_items i ON i.id = bs.item_id
   WHERE i.company_id = _co AND i.is_active AND bs.branch_id = _branch AND bs.quantity >= 20 AND i.cost_per_unit > 0
     AND bs.item_id <> _item ORDER BY bs.quantity LIMIT 1;
  _s1 := pg_temp.stock(_item, _branch);
  _s2 := pg_temp.stock(_item2, _branch);
  SELECT id INTO _sale FROM public.stock_movements WHERE company_id = _co AND movement_type = 'sale_consumption' LIMIT 1;

  -- Two entries of the same item and a waste of another, all wrong.
  _a := public.record_stock_movement(_branch, _item, 'purchase', 10, NULL, 'TEST a · invoice 1234');
  _b := public.record_stock_movement(_branch, _item, 'purchase', 7, NULL, 'TEST b · invoice 1234');
  _c := (public.record_waste(_branch, _item2, 2, 'TEST w', 'business', NULL)->>'movement_id')::uuid;

  -- 1. All or nothing: one row that cannot be cancelled stops the batch, by name.
  _txt := pg_temp.blocked(format('SELECT public.void_stock_movements(ARRAY[%L, %L, %L]::uuid[], %L)', _a, _b, _sale, 'TEST mixed'));
  PERFORM pg_temp.ok('1a a sale row stops the batch and is named', _txt LIKE 'The movement of % is not a manual one and cannot be cancelled here', _txt);
  PERFORM pg_temp.ok('1b nothing was cancelled', NOT EXISTS (SELECT 1 FROM public.stock_movements WHERE id IN (_a, _b) AND voided_at IS NOT NULL)
    AND pg_temp.stock(_item, _branch) = _s1 + 17);

  -- 2. The batch: duplicates ignored, both items back, one recalculation.
  SELECT count(*) INTO _k FROM public.cost_recalcs WHERE ran_at >= now();
  _res := public.void_stock_movements(ARRAY[_a, _b, _c, _a], 'TEST bulk cancel');
  PERFORM pg_temp.ok('2a three cancelled', (_res->>'cancelled')::int = 3 AND NOT (_res->>'negative')::boolean, _res::text);
  PERFORM pg_temp.ok('2b same item twice adds up', pg_temp.stock(_item, _branch) = _s1, pg_temp.stock(_item, _branch)::text);
  PERFORM pg_temp.ok('2c waste put back', pg_temp.stock(_item2, _branch) = _s2, pg_temp.stock(_item2, _branch)::text);
  PERFORM pg_temp.ok('2d all marked cancelled with the reason', (SELECT count(*) FROM public.stock_movements
    WHERE id IN (_a, _b, _c) AND voided_at IS NOT NULL AND void_reason = 'TEST bulk cancel') = 3);
  PERFORM pg_temp.ok('2e sales cost recalculated once', (SELECT count(*) FROM public.cost_recalcs WHERE ran_at >= now()) - _k = 1);
  PERFORM pg_temp.ok('2f one audit row per movement', (SELECT count(*) FROM public.audit_logs
    WHERE action = 'inventory.movement_void' AND entity_id IN (_a, _b, _c)) = 3);

  -- 3. Guards.
  _txt := pg_temp.blocked(format('SELECT public.void_stock_movements(ARRAY[%L]::uuid[], %L)', _a, 'TEST again'));
  PERFORM pg_temp.ok('3a already cancelled, by name', _txt LIKE 'The movement of % is already cancelled', _txt);
  _txt := pg_temp.blocked($q$SELECT public.void_stock_movements(ARRAY[]::uuid[], 'TEST empty')$q$);
  PERFORM pg_temp.ok('3b nothing chosen', _txt = 'Choose at least one movement', _txt);
  _txt := pg_temp.blocked(format('SELECT public.void_stock_movements(ARRAY[%L]::uuid[], %L)', _a, 'x'));
  PERFORM pg_temp.ok('3c reason required', _txt = 'A reason is required', _txt);
  IF pg_temp.act_as('cashier') THEN
    _txt := pg_temp.blocked(format('SELECT public.void_stock_movements(ARRAY[%L]::uuid[], %L)', _a, 'cashier try'));
    PERFORM pg_temp.ok('3d cashier cannot cancel', _txt IS NOT NULL, _txt);
  END IF;
  PERFORM pg_temp.act_as('super_admin');

  -- 4. A single cancel outside a batch still recalculates by itself.
  _a := public.record_stock_movement(_branch, _item, 'adjustment', 1, NULL, 'TEST single');
  SELECT count(*) INTO _k FROM public.cost_recalcs WHERE ran_at >= now();
  PERFORM public.void_stock_movement(_a, 'TEST single cancel');
  PERFORM pg_temp.ok('4 single cancel still recalculates', (SELECT count(*) FROM public.cost_recalcs WHERE ran_at >= now()) - _k = 1);

  PERFORM pg_temp.ok('5 took under 5 seconds', clock_timestamp() - _t0 < interval '5 seconds', (clock_timestamp() - _t0)::text);
  RAISE EXCEPTION 'RESULTS %', (SELECT jsonb_agg(jsonb_build_array(step, ok, detail) ORDER BY n) FROM _results);
END $$;

ROLLBACK;
