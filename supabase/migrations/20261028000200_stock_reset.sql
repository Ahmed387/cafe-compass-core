-- Reset all stock of a branch to zero (Ahmed, 2026-10-28): he is entering
-- the whole stock again from scratch. Super admin only, with a reason.
-- Nothing is deleted: each item gets one "stock_reset" adjustment that takes
-- it to zero (main and bar), visible in the movements log. The reset is a
-- fresh start, not a loss: it is not counted in profit, monthly costs or the
-- stock report. Each reset row can be cancelled like a manual movement to
-- put that item's quantity back.
CREATE OR REPLACE FUNCTION public.reset_branch_stock(_branch_id uuid, _reason text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE _co uuid := public.current_company_id(); _me uuid := public.current_profile_id();
  _why text := btrim(COALESCE(_reason, '')); _batch uuid := gen_random_uuid(); _r record;
  _n int := 0; _pos numeric := 0; _neg numeric := 0;
BEGIN
  IF _me IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only the super admin can reset all stock'; END IF;
  IF length(_why) < 3 THEN RAISE EXCEPTION 'A reason is required'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = _branch_id AND company_id = _co) THEN
    RAISE EXCEPTION 'Branch not found';
  END IF;

  FOR _r IN
    SELECT bs.item_id, bs.quantity, bs.bar_quantity, COALESCE(i.cost_per_unit, 0) AS cost
      FROM public.branch_stock bs JOIN public.inventory_items i ON i.id = bs.item_id
     WHERE bs.branch_id = _branch_id AND i.company_id = _co AND (bs.quantity <> 0 OR bs.bar_quantity <> 0)
     ORDER BY i.name
       FOR UPDATE OF bs
  LOOP
    UPDATE public.branch_stock SET quantity = 0, bar_quantity = 0, updated_at = now()
     WHERE item_id = _r.item_id AND branch_id = _branch_id;
    IF _r.quantity <> 0 THEN
      INSERT INTO public.stock_movements (company_id, branch_id, item_id, movement_type, quantity, unit_cost,
        balance_after, reference_type, reference_id, reason, created_by, location)
      VALUES (_co, _branch_id, _r.item_id, 'adjustment', -_r.quantity, _r.cost, 0, 'stock_reset', _batch, _why, _me, 'main');
    END IF;
    _n := _n + 1;
    _pos := _pos + GREATEST(_r.quantity, 0) * _r.cost;
    _neg := _neg + LEAST(_r.quantity, 0) * _r.cost;
  END LOOP;

  PERFORM public.log_audit('inventory.stock_reset', 'inventory', 'branch_stock', _batch, NULL,
    jsonb_build_object('items', _n, 'positive_value', round(_pos, 2), 'negative_value', round(_neg, 2)),
    _why, _branch_id);

  RETURN jsonb_build_object('reset_id', _batch, 'items', _n,
    'positive_value', round(_pos, 2), 'negative_value', round(_neg, 2));
END $function$;
REVOKE EXECUTE ON FUNCTION public.reset_branch_stock(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reset_branch_stock(uuid, text) TO authenticated;

-- Reset rows are a fresh start, not consumption or an adjustment worth
-- reporting; and they can be cancelled one by one or together.
DO $p$
DECLARE _f record; _src text; _new text;
BEGIN
  FOR _f IN SELECT * FROM (VALUES
    ('public.monthly_operating_costs(date,date)',
     $a$WHERE sm.company_id = _company AND sm.quantity < 0 AND sm.voided_at IS NULL$a$,
     $b$WHERE sm.company_id = _company AND sm.quantity < 0 AND sm.voided_at IS NULL AND sm.reference_type IS DISTINCT FROM 'stock_reset'$b$),
    ('public.inventory_cogs_report(uuid,date,date)',
     $a$WHERE sm.branch_id = _branch_id AND sm.voided_at IS NULL$a$,
     $b$WHERE sm.branch_id = _branch_id AND sm.voided_at IS NULL AND sm.reference_type IS DISTINCT FROM 'stock_reset'$b$),
    ('public.void_stock_movement(uuid,text)',
     $a$IF COALESCE(_m.reference_type, 'manual') NOT IN ('manual', 'opening_balance')$a$,
     $b$IF COALESCE(_m.reference_type, 'manual') NOT IN ('manual', 'opening_balance', 'stock_reset')$b$),
    ('public.void_stock_movements(uuid[],text)',
     $a$IF COALESCE(_m.reference_type, 'manual') NOT IN ('manual', 'opening_balance')$a$,
     $b$IF COALESCE(_m.reference_type, 'manual') NOT IN ('manual', 'opening_balance', 'stock_reset')$b$)
  ) v(fn, old_text, new_text)
  LOOP
    _src := pg_get_functiondef(_f.fn::regprocedure);
    CONTINUE WHEN position(_f.new_text IN _src) > 0;
    _new := replace(_src, _f.old_text, _f.new_text);
    IF _new = _src THEN RAISE EXCEPTION 'Patch text not found in %', _f.fn; END IF;
    EXECUTE _new;
  END LOOP;
END $p$;
