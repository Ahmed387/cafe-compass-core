BEGIN;
-- =====================================================================
-- Cancelling a manual stock movement (2026-10-28) on the real "20s"
-- database, in ONE transaction that ends in ROLLBACK. Nothing is kept.
-- Run after 20261028000000_void_stock_movement.sql. The last block raises
-- 'RESULTS [...]' so everything rolls back.
-- It also checks the pages that read stock movements: profit (_range_pnl),
-- the stock/COGS report, monthly operating costs, the stocktake preview,
-- staff waste charges and the item's average cost.
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
  _co uuid := public.current_company_id(); _me uuid := public.current_profile_id();
  _item uuid; _branch uuid; _cost0 numeric; _s0 numeric; _buy uuid; _adj uuid; _w uuid; _mv public.stock_movements;
  _adj_bal numeric; _n numeric; _m numeric; _txt text; _res jsonb; _k int; _pre record; _post record;
  _pnl0 numeric; _staff0 numeric; _cogs0 numeric; _moc0 jsonb;
BEGIN
  -- An item with stock and a cost whose cost is its opening cost.
  SELECT bs.item_id, bs.branch_id, i.cost_per_unit, bs.quantity INTO _item, _branch, _cost0, _s0
    FROM public.branch_stock bs JOIN public.inventory_items i ON i.id = bs.item_id
   WHERE i.company_id = _co AND i.is_active AND bs.quantity >= 20 AND i.cost_per_unit > 0
     AND i.opening_cost = i.cost_per_unit
     AND NOT EXISTS (SELECT 1 FROM public.stock_movements m WHERE m.item_id = i.id AND m.cost_event)
   ORDER BY bs.quantity LIMIT 1;
  PERFORM pg_temp.ok('0 test item found', _item IS NOT NULL, _item::text || ' stock ' || _s0 || ' cost ' || _cost0);

  -- 1. A wrong purchase of 50 at a silly cost, then a later adjustment of -5.
  _buy := public.record_stock_movement(_branch, _item, 'purchase', 50, _cost0 * 10, 'TEST wrong entry');
  _adj := public.record_stock_movement(_branch, _item, 'adjustment', -5, NULL, 'TEST later');
  SELECT balance_after INTO _adj_bal FROM public.stock_movements WHERE id = _adj;
  SELECT cost_per_unit INTO _n FROM public.inventory_items WHERE id = _item;
  PERFORM pg_temp.ok('1 entry raised stock and average cost', pg_temp.stock(_item, _branch) = _s0 + 45 AND _n > _cost0,
    'stock ' || pg_temp.stock(_item, _branch) || ' cost ' || _n);

  -- 2. Cancel it.
  _res := public.void_stock_movement(_buy, 'TEST entered twice');
  SELECT * INTO _mv FROM public.stock_movements WHERE id = _buy;
  PERFORM pg_temp.ok('2a stock back as if it never happened', pg_temp.stock(_item, _branch) = _s0 - 5
    AND (_res->>'stock_after')::numeric = _s0 - 5 AND NOT (_res->>'negative')::boolean, _res::text);
  PERFORM pg_temp.ok('2b row kept, marked cancelled with who and why',
    _mv.voided_at IS NOT NULL AND _mv.voided_by = _me AND _mv.void_reason = 'TEST entered twice'
    AND _mv.quantity = 50 AND NOT _mv.cost_event, _mv.void_reason);
  PERFORM pg_temp.ok('2c later balance moved by the same 50',
    (SELECT balance_after FROM public.stock_movements WHERE id = _adj) = _adj_bal - 50,
    _adj_bal || ' -> ' || (SELECT balance_after FROM public.stock_movements WHERE id = _adj));
  SELECT cost_per_unit INTO _m FROM public.inventory_items WHERE id = _item;
  PERFORM pg_temp.ok('2d average cost back to before', _m = _cost0, _n || ' -> ' || _m);
  PERFORM pg_temp.ok('2e audit log written', EXISTS (SELECT 1 FROM public.audit_logs
    WHERE action = 'inventory.movement_void' AND entity_id = _buy AND reason = 'TEST entered twice'));
  PERFORM pg_temp.ok('2f sales cost recalculated without error', NOT EXISTS (
    SELECT 1 FROM public.cost_recalcs WHERE company_id = _co AND error IS NOT NULL AND ran_at >= now()));

  -- 3. Guards.
  _txt := pg_temp.blocked(format('SELECT public.void_stock_movement(%L, %L)', _buy, 'again'));
  PERFORM pg_temp.ok('3a cannot cancel twice', _txt = 'This movement is already cancelled', _txt);
  _txt := pg_temp.blocked(format('SELECT public.edit_stock_movement(%L, 5, NULL, %L)', _buy, 'edit it'));
  PERFORM pg_temp.ok('3b cannot edit a cancelled row', _txt = 'This movement is already cancelled', _txt);
  _txt := pg_temp.blocked(format('SELECT public.void_stock_movement(%L, %L)', _adj, 'x'));
  PERFORM pg_temp.ok('3c reason required', _txt = 'A reason is required', _txt);
  _txt := pg_temp.blocked(format('SELECT public.void_stock_movement(%L, %L)',
    (SELECT id FROM public.stock_movements WHERE company_id = _co AND movement_type = 'sale_consumption' LIMIT 1), 'sale row'));
  PERFORM pg_temp.ok('3d sale movements cannot be cancelled', _txt = 'Only manual stock movements can be cancelled', _txt);
  IF EXISTS (SELECT 1 FROM public.stock_movements WHERE company_id = _co AND reference_type = 'purchase') THEN
    _txt := pg_temp.blocked(format('SELECT public.void_stock_movement(%L, %L)',
      (SELECT id FROM public.stock_movements WHERE company_id = _co AND reference_type = 'purchase' LIMIT 1), 'invoice row'));
    PERFORM pg_temp.ok('3e purchase-invoice rows go through the invoice', _txt = 'Only manual stock movements can be cancelled', _txt);
  END IF;
  IF pg_temp.act_as('cashier') THEN
    _txt := pg_temp.blocked(format('SELECT public.void_stock_movement(%L, %L)', _adj, 'cashier try'));
    PERFORM pg_temp.ok('3f cashier cannot cancel', _txt IS NOT NULL, _txt);
  END IF;
  PERFORM pg_temp.act_as('super_admin');

  -- 4. Waste charged to a staff member, cancelled: stock back, charge gone,
  --    profit / stock report / monthly costs no longer count it.
  _pnl0 := (public._range_pnl(_co, current_date - 1, current_date + 1)->>'waste_cost')::numeric;
  _staff0 := (public._range_pnl(_co, current_date - 1, current_date + 1)->>'waste_charged_staff')::numeric;
  SELECT (r->>'waste_qty')::numeric INTO _cogs0 FROM jsonb_array_elements(
    public.inventory_cogs_report(_branch, current_date - 1, current_date + 1)->'items') r WHERE r->>'item_id' = _item::text;
  _moc0 := public.monthly_operating_costs(current_date - 1, current_date + 1)->'waste';
  _s0 := pg_temp.stock(_item, _branch);
  _w := (public.record_waste(_branch, _item, 2, 'TEST spilled', 'staff', _me)->>'movement_id')::uuid;
  SELECT count(*) INTO _k FROM public.staff_penalties WHERE stock_movement_id = _w;
  _n := (public._range_pnl(_co, current_date - 1, current_date + 1)->>'waste_cost')::numeric;
  _m := (public._range_pnl(_co, current_date - 1, current_date + 1)->>'waste_charged_staff')::numeric;
  PERFORM pg_temp.ok('4a waste counted and charged first', _k = 1 AND _n = _pnl0 + 2 * _cost0 AND _m = _staff0 + 2 * _cost0,
    'penalties ' || _k || ' waste ' || _pnl0 || ' -> ' || _n || ' staff ' || _staff0 || ' -> ' || _m);
  PERFORM public.void_stock_movement(_w, 'TEST not really spilled');
  SELECT count(*) INTO _k FROM public.staff_penalties WHERE stock_movement_id = _w;
  PERFORM pg_temp.ok('4b staff charge removed', _k = 0, _k::text);
  PERFORM pg_temp.ok('4c stock back', pg_temp.stock(_item, _branch) = _s0, pg_temp.stock(_item, _branch)::text);
  _n := (public._range_pnl(_co, current_date - 1, current_date + 1)->>'waste_cost')::numeric;
  _m := (public._range_pnl(_co, current_date - 1, current_date + 1)->>'waste_charged_staff')::numeric;
  PERFORM pg_temp.ok('4d profit page: waste and staff charge no longer counted', _n = _pnl0 AND _m = _staff0,
    _pnl0 || ' / ' || _n || ' staff ' || _m);
  SELECT (r->>'waste_qty')::numeric INTO _n FROM jsonb_array_elements(
    public.inventory_cogs_report(_branch, current_date - 1, current_date + 1)->'items') r WHERE r->>'item_id' = _item::text;
  PERFORM pg_temp.ok('4e stock report: waste qty unchanged', _n = _cogs0, _cogs0 || ' / ' || _n);
  PERFORM pg_temp.ok('4f monthly costs: waste unchanged',
    (public.monthly_operating_costs(current_date - 1, current_date + 1)->'waste') IS NOT DISTINCT FROM _moc0);

  -- 5. Stocktake preview: the starting count stays right after a cancel.
  SELECT start_qty, expected INTO _pre FROM public.stocktake_preview(_branch, 'main') WHERE item_id = _item;
  PERFORM public.void_stock_movement(_adj, 'TEST later was wrong');
  SELECT start_qty, expected INTO _post FROM public.stocktake_preview(_branch, 'main') WHERE item_id = _item;
  PERFORM pg_temp.ok('5 stocktake start unchanged, expected +5', _post.start_qty = _pre.start_qty AND _post.expected = _pre.expected + 5,
    _pre::text || ' -> ' || _post::text);

  -- 6. Allowed below zero, and says so.
  _buy := public.record_stock_movement(_branch, _item, 'purchase', 3, NULL, 'TEST small entry');
  PERFORM public.record_stock_movement(_branch, _item, 'adjustment', -pg_temp.stock(_item, _branch), NULL, 'TEST used it all');
  _res := public.void_stock_movement(_buy, 'TEST cancel after use');
  PERFORM pg_temp.ok('6 cancel allowed below zero with a flag', (_res->>'negative')::boolean
    AND pg_temp.stock(_item, _branch) = -3, _res::text);

  -- 7. Every figure that reads stock movements leaves cancelled rows out.
  SELECT count(*) INTO _k FROM unnest(ARRAY['_cost_timeline', '_range_pnl', '_shift_figures', 'monthly_operating_costs',
      'inventory_cogs_report', 'stocktake_preview', '_charge_waste', 'edit_stock_movement']) f
   WHERE NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = f
                      AND pg_get_functiondef(p.oid) LIKE '%voided_at%');
  PERFORM pg_temp.ok('7 shift close, profit, reports, stocktake and cost skip cancelled rows', _k = 0, _k::text);

  RAISE EXCEPTION 'RESULTS %', (SELECT jsonb_agg(jsonb_build_array(step, ok, detail) ORDER BY n) FROM _results);
END $$;

ROLLBACK;
