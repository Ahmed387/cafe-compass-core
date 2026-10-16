-- =====================================================================
-- Phase 2: closing a shift (owner decisions 2026-10-16).
--
-- 1) Refunds, line removals and cancellations are only possible while the
--    invoice's own shift is open. Nobody is exempt. One guard,
--    _assert_order_shift_open, is called by every entry point:
--    refund_order, refund_order_items (behind refund_order_items_attributed and
--    refund_order_full), void_order_item and cancel_pos_order.
-- 2) A shift cannot close while any of its refunds has no bearer. The manager
--    decides per refund: the cafe, one employee, or the shift team
--    (set_refund_bearer). shift_refunds_to_decide lists what is left.
--    Applies to every close path (normal, handover, forced) through
--    _finalize_shift_close.
-- 3) "The whole team" means the people on that shift (cashier + roster), not
--    every employee of the cafe. _charge_staff uses the shift team whenever it
--    knows the shift; it falls back to all staff only without a shift.
-- No data is changed.
-- =====================================================================

CREATE OR REPLACE FUNCTION public._assert_order_shift_open(_o public.orders)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NOT public._on_open_order_shift(_o) THEN
    RAISE EXCEPTION 'الوردية بتاعة الفاتورة دي اتقفلت: المرتجع والإلغاء وشيل الأصناف مش متاحين';
  END IF;
END $$;
REVOKE EXECUTE ON FUNCTION public._assert_order_shift_open(public.orders) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._assert_order_shift_open(public.orders) TO service_role;

CREATE OR REPLACE FUNCTION pg_temp.patch_fn(_sig regprocedure, _old text, _new text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE _def text := pg_get_functiondef(_sig);
BEGIN
  IF position(_new IN _def) > 0 THEN RAISE NOTICE '% already patched', _sig; RETURN; END IF;
  IF position(_old IN _def) = 0 THEN RAISE EXCEPTION 'Expected text not found in %: %', _sig, left(_old, 60); END IF;
  IF position(_old IN substr(_def, position(_old IN _def) + 1)) > 0 THEN
    RAISE EXCEPTION 'Anchor appears more than once in %', _sig;
  END IF;
  EXECUTE replace(_def, _old, _new);
END $$;

-- 1) the refund window
SELECT pg_temp.patch_fn('public.refund_order(uuid, numeric, text, text)'::regprocedure,
$o$  IF _o.status <> 'completed' THEN RAISE EXCEPTION 'Only completed orders can be refunded'; END IF;$o$,
$n$  IF _o.status <> 'completed' THEN RAISE EXCEPTION 'Only completed orders can be refunded'; END IF;
  PERFORM public._assert_order_shift_open(_o);$n$);

SELECT pg_temp.patch_fn('public.refund_order_items(uuid, jsonb, text, text)'::regprocedure,
$o$  IF NOT public.can_refund_order(_o) THEN RAISE EXCEPTION 'Not authorized'; END IF;$o$,
$n$  IF NOT public.can_refund_order(_o) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  PERFORM public._assert_order_shift_open(_o);$n$);

SELECT pg_temp.patch_fn('public.void_order_item(uuid, text, boolean, text, uuid)'::regprocedure,
$o$  IF _o.status IN ('cancelled', 'refunded') THEN RAISE EXCEPTION 'Order is already closed'; END IF;$o$,
$n$  IF _o.status IN ('cancelled', 'refunded') THEN RAISE EXCEPTION 'Order is already closed'; END IF;
  PERFORM public._assert_order_shift_open(_o);$n$);

SELECT pg_temp.patch_fn('public.cancel_pos_order(uuid, text, boolean, text, uuid)'::regprocedure,
$o$  IF _o.status = 'cancelled' THEN RAISE EXCEPTION 'Order already cancelled'; END IF;$o$,
$n$  IF _o.status = 'cancelled' THEN RAISE EXCEPTION 'Order already cancelled'; END IF;
  PERFORM public._assert_order_shift_open(_o);$n$);

-- 3) "the whole team" = the shift's team
SELECT pg_temp.patch_fn('public._charge_staff(uuid, numeric, text, uuid, text, uuid, uuid, text)'::regprocedure,
$o$  ELSE
    _staff := public.waste_share_staff(_company);
  END IF;$o$,
$n$  ELSIF _shift_id IS NOT NULL THEN
    -- The people who worked that shift: its cashier plus its roster.
    SELECT array_agg(DISTINCT x.id) INTO _staff FROM (
      SELECT s.user_id AS id FROM public.shifts s WHERE s.id = _shift_id
      UNION SELECT ss.staff_id FROM public.shift_staff ss WHERE ss.shift_id = _shift_id) x
      JOIN public.user_profiles up ON up.id = x.id AND up.company_id = _company AND up.is_active;
  ELSE
    _staff := public.waste_share_staff(_company);
  END IF;$n$);

-- 2) refunds that still need a bearer
CREATE OR REPLACE FUNCTION public.shift_refunds_to_decide(_shift_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'refund_id', r.id, 'order_id', o.id, 'order_number', o.order_number, 'amount', r.amount,
           'method', COALESCE(r.method_key, 'cash'), 'origin', r.origin, 'reason', r.reason, 'at', r.created_at)
           ORDER BY r.created_at), '[]'::jsonb)
    FROM public.order_refunds r JOIN public.orders o ON o.id = r.order_id
    JOIN public.shifts s ON s.id = r.shift_id
   WHERE r.shift_id = _shift_id AND r.status = 'active' AND r.fault IS NULL
     AND s.company_id = public.current_company_id() AND public.can_access_branch(s.branch_id)
     AND (public.has_permission('shifts.view') OR public.has_permission('shifts.close') OR public.is_super_admin()
          OR s.user_id = public.current_profile_id())
$$;
REVOKE EXECUTE ON FUNCTION public.shift_refunds_to_decide(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.shift_refunds_to_decide(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.set_refund_bearer(_refund_id uuid, _fault text, _staff_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _r public.order_refunds; _s public.shifts; _n int := 0; _number text;
BEGIN
  IF public.current_profile_id() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('shifts.close') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'المدير بس هو اللي يحدد مين يتحمل المرتجع';
  END IF;
  _fault := CASE WHEN _fault = 'business' THEN 'venue' ELSE _fault END;
  IF _fault IS NULL OR _fault NOT IN ('venue', 'staff', 'all_staff') THEN RAISE EXCEPTION 'اختار مين يتحمل المرتجع'; END IF;
  IF _fault = 'staff' AND _staff_id IS NULL THEN RAISE EXCEPTION 'اختار الموظف'; END IF;

  SELECT * INTO _r FROM public.order_refunds WHERE id = _refund_id AND company_id = public.current_company_id() FOR UPDATE;
  IF _r.id IS NULL OR _r.status <> 'active' THEN RAISE EXCEPTION 'المرتجع مش موجود'; END IF;
  IF _r.fault IS NOT NULL THEN RAISE EXCEPTION 'المرتجع ده اتحدد مين يتحمله قبل كده'; END IF;
  SELECT * INTO _s FROM public.shifts WHERE id = _r.shift_id;
  IF _s.id IS NULL OR _s.status <> 'open' THEN RAISE EXCEPTION 'الوردية اتقفلت'; END IF;
  IF NOT public.can_access_branch(_s.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;

  UPDATE public.order_refunds SET fault = _fault, blamed_staff_id = CASE WHEN _fault = 'staff' THEN _staff_id END
   WHERE id = _r.id;
  SELECT order_number INTO _number FROM public.orders WHERE id = _r.order_id;
  IF _fault IN ('staff', 'all_staff') THEN
    _n := public._charge_staff(_r.company_id, _r.amount, _fault, _staff_id,
      'مرتجع فاتورة #' || COALESCE(_number, '') || ': ' || COALESCE(_r.reason, ''), _r.order_id, _r.shift_id, 'refund');
  END IF;
  PERFORM public.log_audit('refund.bearer_set', 'pos', 'order_refunds', _r.id, jsonb_build_object('fault', NULL),
    jsonb_build_object('fault', _fault, 'staff_id', _staff_id, 'amount', _r.amount, 'penalties', _n), NULL, _s.branch_id);
  RETURN jsonb_build_object('refund_id', _r.id, 'fault', _fault, 'penalties', _n);
END $$;
REVOKE EXECUTE ON FUNCTION public.set_refund_bearer(uuid, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_refund_bearer(uuid, text, uuid) TO authenticated, service_role;

-- No close (normal, handover or forced) while a refund has no bearer.
SELECT pg_temp.patch_fn('public._finalize_shift_close(uuid, numeric, numeric, text, uuid, text, text, uuid)'::regprocedure,
$o$  IF _s.status = 'closed' THEN RAISE EXCEPTION 'Shift already closed'; END IF;$o$,
$n$  IF _s.status = 'closed' THEN RAISE EXCEPTION 'Shift already closed'; END IF;
  IF EXISTS (SELECT 1 FROM public.order_refunds r WHERE r.shift_id = _s.id AND r.status = 'active' AND r.fault IS NULL) THEN
    RAISE EXCEPTION 'فيه % مرتجع في الوردية دي لسه محتاج تحدد مين يتحمله قبل القفل',
      (SELECT count(*) FROM public.order_refunds r WHERE r.shift_id = _s.id AND r.status = 'active' AND r.fault IS NULL);
  END IF;$n$);
