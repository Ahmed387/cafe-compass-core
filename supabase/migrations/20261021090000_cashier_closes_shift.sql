-- =====================================================================
-- Owner rule (2026-10-20): the cashier closes the shift again, as before
-- 2026-10-16. Whoever closes (cashier, manager or super admin) picks who bears
-- each refund: the cafe, one employee, or the shift team. A manager or the
-- super admin can change that choice afterwards (reassign_refund_bearer).
--   * cashier role gets shifts.close back (not shifts.adjust_cash)
--   * a cashier on the shift roster may close that shift, not only its opener
-- Audited. No sales data is changed.
-- =====================================================================
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

WITH added AS (
  INSERT INTO public.role_permissions (role_id, permission_id)
  SELECT r.id, p.id FROM public.roles r CROSS JOIN public.permissions p
   WHERE r.key = 'cashier' AND r.is_system_role AND p.key = 'shifts.close'
     AND NOT EXISTS (SELECT 1 FROM public.role_permissions x WHERE x.role_id = r.id AND x.permission_id = p.id)
  RETURNING role_id)
INSERT INTO public.audit_logs (company_id, action, module, entity_type, old_values, new_values, reason)
SELECT r.company_id, 'roles.permission_added', 'governance', 'roles', NULL,
       jsonb_build_object('role', 'cashier', 'permission', 'shifts.close'),
       'الكاشير يقدر يقفل الوردية ويحدد مين يتحمل كل مرتجع (قرار صاحب الكافيه 2026-10-20)'
  FROM added a JOIN public.roles r ON r.id = a.role_id;

-- The shift's crew may close it too (the POS already lets a rostered cashier work it).
SELECT pg_temp.patch_fn('public._assert_can_close_shift(uuid)'::regprocedure,
$o$  IF _s.user_id <> _profile AND NOT (public.has_permission('shifts.adjust_cash') OR public.is_super_admin()) THEN$o$,
$n$  IF _s.user_id <> _profile
     AND NOT EXISTS (SELECT 1 FROM public.shift_staff ss WHERE ss.shift_id = _s.id AND ss.staff_id = _profile)
     AND NOT (public.has_permission('shifts.adjust_cash') OR public.is_super_admin()) THEN$n$);

-- Change a refund's bearer after the shift closed (manager / super admin only).
-- Penalties already taken in payroll are never touched: that refund can't be moved.
CREATE OR REPLACE FUNCTION public.reassign_refund_bearer(_refund_id uuid, _fault text, _staff_id uuid DEFAULT NULL, _reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _r public.order_refunds; _s public.shifts; _n int := 0; _number text; _others int;
BEGIN
  IF public.current_profile_id() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('shifts.adjust_cash') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'المدير أو السوبر أدمن بس هما اللي يغيروا مين يتحمل المرتجع';
  END IF;
  _fault := CASE WHEN _fault = 'business' THEN 'venue' ELSE _fault END;
  IF _fault IS NULL OR _fault NOT IN ('venue', 'staff', 'all_staff') THEN RAISE EXCEPTION 'اختار مين يتحمل المرتجع'; END IF;
  IF _fault = 'staff' AND _staff_id IS NULL THEN RAISE EXCEPTION 'اختار الموظف'; END IF;

  SELECT * INTO _r FROM public.order_refunds WHERE id = _refund_id AND company_id = public.current_company_id() FOR UPDATE;
  IF _r.id IS NULL OR _r.status <> 'active' THEN RAISE EXCEPTION 'المرتجع مش موجود'; END IF;
  SELECT * INTO _s FROM public.shifts WHERE id = _r.shift_id;
  IF _s.id IS NOT NULL AND NOT public.can_access_branch(_s.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _r.fault IS NOT DISTINCT FROM _fault AND _r.blamed_staff_id IS NOT DISTINCT FROM (CASE WHEN _fault = 'staff' THEN _staff_id END) THEN
    RETURN jsonb_build_object('refund_id', _r.id, 'fault', _fault, 'changed', false);
  END IF;

  IF _r.fault IN ('staff', 'all_staff') THEN
    -- Penalties carry the order, not the refund: only safe when this is the order's one charged refund.
    SELECT count(*) INTO _others FROM public.order_refunds x
     WHERE x.order_id = _r.order_id AND x.status = 'active' AND x.id <> _r.id AND x.fault IN ('staff', 'all_staff');
    IF _others > 0 THEN RAISE EXCEPTION 'الفاتورة دي عليها أكتر من مرتجع على الموظفين، عدّل الخصم من صفحة الموظفين'; END IF;
    IF EXISTS (SELECT 1 FROM public.staff_penalties WHERE order_id = _r.order_id AND source = 'refund' AND deducted_amount > 0) THEN
      RAISE EXCEPTION 'خصم المرتجع ده اتاخد في المرتب خلاص، مينفعش يتغير';
    END IF;
    DELETE FROM public.staff_penalties WHERE order_id = _r.order_id AND source = 'refund' AND COALESCE(deducted_amount, 0) = 0;
  END IF;

  UPDATE public.order_refunds SET fault = _fault, blamed_staff_id = CASE WHEN _fault = 'staff' THEN _staff_id END
   WHERE id = _r.id;
  SELECT order_number INTO _number FROM public.orders WHERE id = _r.order_id;
  IF _fault IN ('staff', 'all_staff') THEN
    _n := public._charge_staff(_r.company_id, _r.amount, _fault, _staff_id,
      'مرتجع فاتورة #' || COALESCE(_number, '') || ': ' || COALESCE(_r.reason, ''), _r.order_id, _r.shift_id, 'refund');
  END IF;
  PERFORM public.log_audit('refund.bearer_changed', 'pos', 'order_refunds', _r.id,
    jsonb_build_object('fault', _r.fault, 'staff_id', _r.blamed_staff_id),
    jsonb_build_object('fault', _fault, 'staff_id', _staff_id, 'amount', _r.amount, 'penalties', _n), _reason, _s.branch_id);
  RETURN jsonb_build_object('refund_id', _r.id, 'fault', _fault, 'penalties', _n, 'changed', true);
END $$;
REVOKE EXECUTE ON FUNCTION public.reassign_refund_bearer(uuid, text, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reassign_refund_bearer(uuid, text, uuid, text) TO authenticated, service_role;
