-- Cancel a manual stock movement (Ahmed, 2026-10-28).
-- A wrong manual entry (purchase, adjustment, opening balance or waste typed by
-- hand) can be cancelled with a reason, by the super admin or inventory.adjust.
-- Nothing is deleted: the row stays in the log marked cancelled (who, when,
-- why), the stock goes back to what it would be without it (even below zero,
-- the screen warns first), later balances shift with it, the sales cost is
-- recalculated from that date (paid-out days stay as they are) and a waste
-- charge on staff not yet deducted from payroll is removed.
-- Cancelled rows are left out of the cost timeline and of the stock, waste
-- and stocktake figures.
ALTER TABLE public.stock_movements
  ADD COLUMN IF NOT EXISTS voided_at timestamptz,
  ADD COLUMN IF NOT EXISTS voided_by uuid REFERENCES public.user_profiles(id),
  ADD COLUMN IF NOT EXISTS void_reason text;

CREATE OR REPLACE FUNCTION public.void_stock_movement(_movement_id uuid, _reason text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE _m public.stock_movements; _bal numeric; _cost numeric; _why text := btrim(COALESCE(_reason, ''));
BEGIN
  IF public.current_profile_id() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.is_super_admin() OR public.has_permission('inventory.adjust')) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF length(_why) < 3 THEN RAISE EXCEPTION 'A reason is required'; END IF;

  SELECT * INTO _m FROM public.stock_movements
   WHERE id = _movement_id AND company_id = public.current_company_id() FOR UPDATE;
  IF _m.id IS NULL THEN RAISE EXCEPTION 'Movement not found'; END IF;
  IF NOT public.can_access_branch(_m.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _m.voided_at IS NOT NULL THEN RAISE EXCEPTION 'This movement is already cancelled'; END IF;
  IF COALESCE(_m.reference_type, 'manual') NOT IN ('manual', 'opening_balance')
     OR _m.movement_type NOT IN ('purchase', 'adjustment', 'waste') THEN
    RAISE EXCEPTION 'Only manual stock movements can be cancelled';
  END IF;
  IF EXISTS (SELECT 1 FROM public.staff_penalties WHERE stock_movement_id = _m.id AND COALESCE(deducted_amount, 0) > 0) THEN
    RAISE EXCEPTION 'This waste was already deducted in payroll and can no longer change';
  END IF;

  UPDATE public.branch_stock
     SET quantity = quantity - _m.quantity,
         bar_quantity = CASE WHEN _m.location = 'bar' THEN bar_quantity - _m.quantity
                             ELSE LEAST(bar_quantity, quantity - _m.quantity) END,
         updated_at = now()
   WHERE item_id = _m.item_id AND branch_id = _m.branch_id
  RETURNING quantity INTO _bal;
  IF _bal IS NULL THEN RAISE EXCEPTION 'No stock recorded for this item in this branch'; END IF;

  -- Later rows show the balance as if this entry never happened.
  UPDATE public.stock_movements SET balance_after = balance_after - _m.quantity
   WHERE item_id = _m.item_id AND branch_id = _m.branch_id
     AND (created_at > _m.created_at OR (created_at = _m.created_at AND id > _m.id));

  UPDATE public.stock_movements
     SET voided_at = now(), voided_by = public.current_profile_id(), void_reason = _why, cost_event = false
   WHERE id = _m.id;

  -- Removes the staff charge (patched below to charge nothing on a cancelled row).
  IF _m.waste_bearer IN ('staff', 'all_staff') THEN PERFORM public._charge_waste(_m.id, NULL); END IF;

  -- A cancelled purchase no longer counts in the item's average cost.
  IF _m.cost_event THEN
    SELECT t.avg_cost INTO _cost FROM public._cost_timeline(_m.company_id) t
     WHERE t.item_id = _m.item_id AND t.ts > '-infinity'::timestamptz ORDER BY t.ts DESC LIMIT 1;
    PERFORM set_config('app.cost_auto', 'on', true);
    UPDATE public.inventory_items
       SET cost_per_unit = COALESCE(_cost, NULLIF(opening_cost, 0), cost_per_unit), updated_at = now()
     WHERE id = _m.item_id;
    PERFORM set_config('app.cost_auto', 'off', true);
  END IF;

  BEGIN
    PERFORM public.recost_sales(_m.company_id, 'purchase');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO public.cost_recalcs (company_id, reason, error) VALUES (_m.company_id, 'purchase', SQLERRM);
  END;

  PERFORM public.log_audit('inventory.movement_void', 'inventory', 'stock_movements', _m.id,
    jsonb_build_object('quantity', _m.quantity, 'unit_cost', _m.unit_cost, 'movement_type', _m.movement_type,
      'balance_after', _m.balance_after),
    jsonb_build_object('voided', true, 'stock_after', _bal, 'reason', _why),
    _why, _m.branch_id);

  RETURN jsonb_build_object('stock_after', _bal, 'negative', _bal < 0);
END $function$;
REVOKE EXECUTE ON FUNCTION public.void_stock_movement(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.void_stock_movement(uuid, text) TO authenticated;

-- Leave cancelled rows out of the figures. Each function is patched in place
-- (one exact text swap, checked) so the rest of its body stays as it is.
DO $p$
DECLARE _f record; _src text; _new text;
BEGIN
  FOR _f IN SELECT * FROM (VALUES
    ('public._cost_timeline(uuid)',
     $a$WHERE m.company_id = _company AND m.movement_type NOT IN ('transfer_in', 'transfer_out')$a$,
     $b$WHERE m.company_id = _company AND m.movement_type NOT IN ('transfer_in', 'transfer_out') AND m.voided_at IS NULL$b$),
    ('public._range_pnl(uuid,date,date)',
     $a$sm.movement_type = 'waste' AND sm.quantity < 0$a$,
     $b$sm.movement_type = 'waste' AND sm.quantity < 0 AND sm.voided_at IS NULL$b$),
    ('public._shift_figures(public.shifts)',
     $a$sm.movement_type = 'waste' AND sm.quantity < 0$a$,
     $b$sm.movement_type = 'waste' AND sm.quantity < 0 AND sm.voided_at IS NULL$b$),
    ('public.monthly_operating_costs(date,date)',
     $a$WHERE sm.company_id = _company AND sm.quantity < 0$a$,
     $b$WHERE sm.company_id = _company AND sm.quantity < 0 AND sm.voided_at IS NULL$b$),
    ('public.inventory_cogs_report(uuid,date,date)',
     $a$WHERE sm.branch_id = _branch_id$a$,
     $b$WHERE sm.branch_id = _branch_id AND sm.voided_at IS NULL$b$),
    ('public.stocktake_preview(uuid,text)',
     $a$AND m.created_at > COALESCE(b.last_at, '-infinity'::timestamptz)$a$,
     $b$AND m.created_at > COALESCE(b.last_at, '-infinity'::timestamptz) AND m.voided_at IS NULL$b$),
    ('public._charge_waste(uuid,uuid[])',
     $a$IF _m.waste_bearer NOT IN ('staff', 'all_staff') THEN RETURN 0; END IF;$a$,
     $b$IF _m.waste_bearer NOT IN ('staff', 'all_staff') OR _m.voided_at IS NOT NULL THEN RETURN 0; END IF;$b$),
    ('public.edit_stock_movement(uuid,numeric,numeric,text)',
     $a$  _new := CASE WHEN _m.quantity < 0$a$,
     $b$  IF _m.voided_at IS NOT NULL THEN RAISE EXCEPTION 'This movement is already cancelled'; END IF;
  _new := CASE WHEN _m.quantity < 0$b$)
  ) v(fn, old_text, new_text)
  LOOP
    _src := pg_get_functiondef(_f.fn::regprocedure);
    CONTINUE WHEN position(_f.new_text IN _src) > 0;
    _new := replace(_src, _f.old_text, _f.new_text);
    IF _new = _src THEN RAISE EXCEPTION 'Patch text not found in %', _f.fn; END IF;
    EXECUTE _new;
  END LOOP;
END $p$;
