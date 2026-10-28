BEGIN;
-- =====================================================================
-- Resetting all stock of a branch to zero (2026-10-28) on the real "20s"
-- database, in ONE transaction that ends in ROLLBACK. Nothing is kept. Run
-- after 20261028000200_stock_reset.sql. The last block raises
-- 'RESULTS [...]' so everything rolls back.
-- The only manager is also the super admin, so the "not allowed" check uses
-- the cashier.
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
  _co uuid := public.current_company_id(); _branch uuid; _item uuid; _item2 uuid; _s1 numeric;
  _a uuid; _reset uuid; _row1 uuid; _row2 uuid; _res jsonb; _txt text; _nz int; _pos numeric; _neg numeric;
  _from date := date_trunc('month', current_date)::date; _to date := current_date;
  _pnl0 jsonb; _moc0 jsonb; _cogs0 jsonb; _cogs1 jsonb; _t0 timestamptz := clock_timestamp();
BEGIN
  SELECT bs.item_id, bs.branch_id INTO _item, _branch FROM public.branch_stock bs JOIN public.inventory_items i ON i.id = bs.item_id
   WHERE i.company_id = _co AND i.is_active AND i.cost_per_unit > 0 ORDER BY i.name LIMIT 1;
  SELECT bs.item_id INTO _item2 FROM public.branch_stock bs JOIN public.inventory_items i ON i.id = bs.item_id
   WHERE i.company_id = _co AND i.is_active AND i.cost_per_unit > 0 AND bs.branch_id = _branch AND bs.item_id <> _item
   ORDER BY i.name LIMIT 1;

  -- One item bought with part of it at the bar, and one item below zero the
  -- way sales under a stock override leave it.
  _a := public.record_stock_movement(_branch, _item, 'purchase', 30, NULL, 'TEST buy · invoice 1234');
  UPDATE public.branch_stock SET bar_quantity = 4 WHERE item_id = _item AND branch_id = _branch;
  UPDATE public.branch_stock SET quantity = -5, bar_quantity = -5 WHERE item_id = _item2 AND branch_id = _branch;
  _s1 := pg_temp.stock(_item, _branch);
  -- Settle the sales cost first, so the comparisons below only see the reset.
  PERFORM public.recost_sales(_co, 'purchase');
  _pnl0 := public._range_pnl(_co, _from, _to);
  _moc0 := public.monthly_operating_costs(_from, _to);
  _cogs0 := public.inventory_cogs_report(_branch, _from, _to);
  SELECT count(*) FILTER (WHERE bs.quantity <> 0),
         COALESCE(sum(GREATEST(bs.quantity, 0) * COALESCE(i.cost_per_unit, 0)), 0),
         COALESCE(sum(LEAST(bs.quantity, 0) * COALESCE(i.cost_per_unit, 0)), 0)
    INTO _nz, _pos, _neg
    FROM public.branch_stock bs JOIN public.inventory_items i ON i.id = bs.item_id
   WHERE bs.branch_id = _branch AND i.company_id = _co;

  -- 1. Guards.
  IF pg_temp.act_as('cashier') THEN
    _txt := pg_temp.blocked(format('SELECT public.reset_branch_stock(%L, %L)', _branch, 'cashier try'));
    PERFORM pg_temp.ok('1a cashier cannot reset', _txt = 'Only the super admin can reset all stock', _txt);
  END IF;
  PERFORM pg_temp.act_as('super_admin');
  _txt := pg_temp.blocked(format('SELECT public.reset_branch_stock(%L, %L)', _branch, 'x'));
  PERFORM pg_temp.ok('1b reason required', _txt = 'A reason is required', _txt);
  _txt := pg_temp.blocked(format('SELECT public.reset_branch_stock(%L, %L)', gen_random_uuid(), 'TEST wrong branch'));
  PERFORM pg_temp.ok('1c unknown branch', _txt = 'Branch not found', _txt);
  PERFORM pg_temp.ok('1d a refused reset changes nothing', pg_temp.stock(_item, _branch) = _s1 AND pg_temp.stock(_item2, _branch) = -5);

  -- 2. The reset.
  _res := public.reset_branch_stock(_branch, 'TEST reset');
  _reset := (_res->>'reset_id')::uuid;
  PERFORM pg_temp.ok('2a every item of the branch is zero, store and bar', NOT EXISTS (SELECT 1 FROM public.branch_stock
    WHERE branch_id = _branch AND (quantity <> 0 OR bar_quantity <> 0)), _res::text);
  PERFORM pg_temp.ok('2b one reset row per item that had a quantity', (SELECT count(*) FROM public.stock_movements
    WHERE reference_type = 'stock_reset' AND reference_id = _reset) = _nz, _nz::text);
  PERFORM pg_temp.ok('2c the row takes the item down to zero', EXISTS (SELECT 1 FROM public.stock_movements
    WHERE reference_id = _reset AND item_id = _item AND movement_type = 'adjustment' AND quantity = -_s1
      AND balance_after = 0 AND location = 'main' AND reason = 'TEST reset' AND voided_at IS NULL AND NOT cost_event));
  PERFORM pg_temp.ok('2d an item below zero is brought up to zero', EXISTS (SELECT 1 FROM public.stock_movements
    WHERE reference_id = _reset AND item_id = _item2 AND quantity = 5 AND balance_after = 0));
  PERFORM pg_temp.ok('2e value of what was zeroed', (_res->>'positive_value')::numeric = round(_pos, 2)
    AND (_res->>'negative_value')::numeric = round(_neg, 2), _res::text);
  PERFORM pg_temp.ok('2f one audit row', (SELECT count(*) FROM public.audit_logs
    WHERE action = 'inventory.stock_reset' AND entity_id = _reset) = 1);
  PERFORM pg_temp.ok('2g old movements are kept as they were', EXISTS (SELECT 1 FROM public.stock_movements
    WHERE id = _a AND voided_at IS NULL AND quantity = 30));

  -- 3. A fresh start, not a loss.
  PERFORM pg_temp.ok('3a profit unchanged', public._range_pnl(_co, _from, _to) = _pnl0);
  PERFORM pg_temp.ok('3b monthly costs unchanged', public.monthly_operating_costs(_from, _to) = _moc0);
  _cogs1 := public.inventory_cogs_report(_branch, _from, _to);
  PERFORM pg_temp.ok('3c stock report: consumption and adjustments unchanged',
    _cogs1->'total_consumed_cost' = _cogs0->'total_consumed_cost'
    AND (SELECT r->'adjust_qty' FROM jsonb_array_elements(_cogs1->'items') r WHERE r->>'item_id' = _item::text)
      = (SELECT r->'adjust_qty' FROM jsonb_array_elements(_cogs0->'items') r WHERE r->>'item_id' = _item::text));
  PERFORM pg_temp.ok('3d stock report: nothing left on hand', (_cogs1->>'total_valuation')::numeric = 0, _cogs1->>'total_valuation');

  -- 4. Undo, item by item or together.
  SELECT id INTO _row1 FROM public.stock_movements WHERE reference_id = _reset AND item_id = _item;
  SELECT id INTO _row2 FROM public.stock_movements WHERE reference_id = _reset AND item_id = _item2;
  _txt := pg_temp.blocked(format('SELECT public.edit_stock_movement(%L, 1, NULL, %L)', _row1, 'TEST edit'));
  PERFORM pg_temp.ok('4a a reset row cannot be edited', _txt LIKE 'يمكن تعديل الحركات اليدوية فقط%', _txt);
  _res := public.void_stock_movement(_row1, 'TEST undo one item');
  PERFORM pg_temp.ok('4b undo puts the quantity back in the store, bar stays zero', pg_temp.stock(_item, _branch) = _s1
    AND (SELECT bar_quantity FROM public.branch_stock WHERE item_id = _item AND branch_id = _branch) = 0
    AND NOT (_res->>'negative')::boolean, _res::text);
  PERFORM pg_temp.ok('4c other items stay at zero', pg_temp.stock(_item2, _branch) = 0);
  _res := public.void_stock_movements(ARRAY[_row2], 'TEST undo together');
  PERFORM pg_temp.ok('4d undo together works and warns below zero', pg_temp.stock(_item2, _branch) = -5
    AND (_res->>'negative')::boolean, _res::text);
  PERFORM pg_temp.ok('4e the undone rows move to the cancelled tab', (SELECT count(*) FROM public.stock_movements
    WHERE id IN (_row1, _row2) AND voided_at IS NOT NULL) = 2);
  PERFORM pg_temp.ok('4f undo does not touch profit', public._range_pnl(_co, _from, _to) = _pnl0);
  PERFORM pg_temp.ok('4g undo does not count as a monthly cost', public.monthly_operating_costs(_from, _to) = _moc0);

  PERFORM pg_temp.ok('5 took under 5 seconds', clock_timestamp() - _t0 < interval '5 seconds', (clock_timestamp() - _t0)::text);
  RAISE EXCEPTION 'RESULTS %', (SELECT jsonb_agg(jsonb_build_array(step, ok, detail) ORDER BY n) FROM _results);
END $$;

ROLLBACK;
