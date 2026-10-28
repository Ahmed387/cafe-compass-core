-- Cancel several manual stock movements at once (Ahmed, 2026-10-28).
-- One reason for all. All or nothing: every movement is checked first and the
-- message names the item that stops it; then each one is cancelled exactly as
-- void_stock_movement does (two rows of the same item add up), and the sales
-- cost is recalculated once at the end instead of once per row.
CREATE OR REPLACE FUNCTION public.void_stock_movements(_movement_ids uuid[], _reason text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE _ids uuid[]; _m record; _id uuid; _res jsonb; _out jsonb := '[]'::jsonb; _co uuid := public.current_company_id();
BEGIN
  IF public.current_profile_id() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.is_super_admin() OR public.has_permission('inventory.adjust')) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF length(btrim(COALESCE(_reason, ''))) < 3 THEN RAISE EXCEPTION 'A reason is required'; END IF;
  SELECT array_agg(DISTINCT x) INTO _ids FROM unnest(_movement_ids) x WHERE x IS NOT NULL;
  IF COALESCE(array_length(_ids, 1), 0) = 0 THEN RAISE EXCEPTION 'Choose at least one movement'; END IF;
  IF array_length(_ids, 1) > 200 THEN RAISE EXCEPTION 'Cancel at most 200 movements at a time'; END IF;

  -- Check them all before touching anything.
  FOR _m IN
    SELECT x AS id, m.id AS found, m.voided_at, m.reference_type, m.movement_type, m.branch_id,
           COALESCE(NULLIF(i.name_ar, ''), i.name) AS item
      FROM unnest(_ids) x
      LEFT JOIN public.stock_movements m ON m.id = x AND m.company_id = _co
      LEFT JOIN public.inventory_items i ON i.id = m.item_id
  LOOP
    IF _m.found IS NULL THEN RAISE EXCEPTION 'Movement not found'; END IF;
    IF NOT public.can_access_branch(_m.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
    IF _m.voided_at IS NOT NULL THEN RAISE EXCEPTION 'The movement of % is already cancelled', _m.item; END IF;
    IF COALESCE(_m.reference_type, 'manual') NOT IN ('manual', 'opening_balance')
       OR _m.movement_type NOT IN ('purchase', 'adjustment', 'waste') THEN
      RAISE EXCEPTION 'The movement of % is not a manual one and cannot be cancelled here', _m.item;
    END IF;
    IF EXISTS (SELECT 1 FROM public.staff_penalties p WHERE p.stock_movement_id = _m.id AND COALESCE(p.deducted_amount, 0) > 0) THEN
      RAISE EXCEPTION 'The waste of % was already deducted in payroll and can no longer change', _m.item;
    END IF;
  END LOOP;

  PERFORM set_config('app.void_batch', 'on', true);
  FOR _id IN SELECT m.id FROM public.stock_movements m WHERE m.id = ANY(_ids) ORDER BY m.created_at, m.id LOOP
    _res := public.void_stock_movement(_id, _reason);
    _out := _out || jsonb_build_array(jsonb_build_object('movement_id', _id) || _res);
  END LOOP;
  PERFORM set_config('app.void_batch', 'off', true);

  BEGIN
    PERFORM public.recost_sales(_co, 'purchase');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO public.cost_recalcs (company_id, reason, error) VALUES (_co, 'purchase', SQLERRM);
  END;

  RETURN jsonb_build_object('cancelled', jsonb_array_length(_out), 'rows', _out,
    'negative', EXISTS (SELECT 1 FROM jsonb_array_elements(_out) r WHERE (r->>'negative')::boolean));
END $function$;
REVOKE EXECUTE ON FUNCTION public.void_stock_movements(uuid[], text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.void_stock_movements(uuid[], text) TO authenticated;

-- Inside a batch, void_stock_movement leaves the recalculation to the batch.
DO $p$
DECLARE _f record; _src text; _new text;
BEGIN
  FOR _f IN SELECT * FROM (VALUES
    ('public.void_stock_movement(uuid,text)',
     $a$  BEGIN
    PERFORM public.recost_sales(_m.company_id, 'purchase');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO public.cost_recalcs (company_id, reason, error) VALUES (_m.company_id, 'purchase', SQLERRM);
  END;$a$,
     $b$  IF COALESCE(current_setting('app.void_batch', true), '') <> 'on' THEN
    BEGIN
      PERFORM public.recost_sales(_m.company_id, 'purchase');
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO public.cost_recalcs (company_id, reason, error) VALUES (_m.company_id, 'purchase', SQLERRM);
    END;
  END IF;$b$)
  ) v(fn, old_text, new_text)
  LOOP
    _src := pg_get_functiondef(_f.fn::regprocedure);
    CONTINUE WHEN position(_f.new_text IN _src) > 0;
    _new := replace(_src, _f.old_text, _f.new_text);
    IF _new = _src THEN RAISE EXCEPTION 'Patch text not found in %', _f.fn; END IF;
    EXECUTE _new;
  END LOOP;
END $p$;
