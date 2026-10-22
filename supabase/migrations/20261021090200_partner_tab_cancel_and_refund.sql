-- =====================================================================
-- Bug (reported 2026-10-20): cancelling an invoice put on a partner's account
-- left the amount on the partner's account, so it would come off their profit.
-- A partner-tab invoice has no payment rows, and every reversal path only gave
-- back what was paid:
--   * cancel_pos_order refused it (it is "completed" as soon as it is issued)
--   * refund_order_items / refund_order_full saw paid = 0 and said
--     "already fully refunded"
-- Fix:
--   1) cancel_pos_order accepts a completed partner-tab invoice (shift still
--      open, same rules as any cancel) and takes the whole amount off the tab
--   2) refund_order_items treats the tab amount as what was paid, with method
--      'partner_tab'; the existing trg_refund_adjusts_partner_tab trigger then
--      shrinks the tab (or credits the partner when it was already settled).
--      The drawer is never touched: partner_tab is not cash.
-- No existing data is changed.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.patch_fn(_sig regprocedure, _old text, _new text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE _def text := pg_get_functiondef(_sig);
BEGIN
  -- Editors on Windows paste CRLF line ends; function sources use LF.
  _old := replace(_old, E'\r', ''); _new := replace(_new, E'\r', '');
  IF position(_new IN _def) > 0 THEN RAISE NOTICE '% already patched', _sig; RETURN; END IF;
  IF position(_old IN _def) = 0 THEN RAISE EXCEPTION 'Expected text not found in %: %', _sig, left(_old, 60); END IF;
  IF position(_old IN substr(_def, position(_old IN _def) + 1)) > 0 THEN
    RAISE EXCEPTION 'Anchor appears more than once in %', _sig;
  END IF;
  EXECUTE replace(_def, _old, _new);
END $$;

-- 1) cancel: allow a completed tab invoice, then reverse the tab
SELECT pg_temp.patch_fn('public.cancel_pos_order(uuid, text, boolean, text, uuid)'::regprocedure,
$o$  IF _o.status IN ('completed', 'partially_refunded', 'refunded') THEN$o$,
$n$  IF _o.status IN ('completed', 'partially_refunded', 'refunded')
     AND NOT (_o.status = 'completed'
              AND EXISTS (SELECT 1 FROM public.partner_tab_orders t WHERE t.order_id = _o.id)
              AND NOT EXISTS (SELECT 1 FROM public.order_payments p WHERE p.order_id = _o.id)) THEN$n$);

SELECT pg_temp.patch_fn('public.cancel_pos_order(uuid, text, boolean, text, uuid)'::regprocedure,
$o$  IF _o.status NOT IN ('pending', 'open') THEN RAISE EXCEPTION 'لا يمكن إلغاء هذا الطلب في حالته الحالية'; END IF;$o$,
$n$  IF _o.status NOT IN ('pending', 'open')
     AND NOT (_o.status = 'completed' AND EXISTS (SELECT 1 FROM public.partner_tab_orders t WHERE t.order_id = _o.id)) THEN
    RAISE EXCEPTION 'لا يمكن إلغاء هذا الطلب في حالته الحالية';
  END IF;$n$);

-- The tab reversal goes through a refund row so the trigger, the audit trail and
-- the partner's statement all see one event.
SELECT pg_temp.patch_fn('public.cancel_pos_order(uuid, text, boolean, text, uuid)'::regprocedure,
$o$  IF _prepared THEN
    -- Made already$o$,
$n$  IF EXISTS (SELECT 1 FROM public.partner_tab_orders t WHERE t.order_id = _order_id) THEN
    _left := round(_o.total - COALESCE((SELECT SUM(r.amount) FROM public.order_refunds r
                     WHERE r.order_id = _order_id AND r.status = 'active' AND r.method_key = 'partner_tab'), 0), 2);
    IF _left > 0 THEN
      INSERT INTO public.order_refunds (company_id, branch_id, order_id, shift_id, kind, amount, tax_amount,
        method_key, reason, status, origin, fault, created_by)
      VALUES (_o.company_id, _o.branch_id, _o.id, _o.shift_id, 'full', _left, 0,
        'partner_tab', 'إلغاء فاتورة على حساب الشريك: ' || _why, 'active', 'cancel', 'venue', public.current_profile_id());
      _given := _given + _left;
    END IF;
  END IF;

  IF _prepared THEN
    -- Made already$n$);

-- 2) partial / full refund of tab items
SELECT pg_temp.patch_fn('public.refund_order_items(uuid, jsonb, text, text)'::regprocedure,
$o$  IF round(_paid - _already, 2) <= 0 THEN RAISE EXCEPTION 'This order is fully refunded'; END IF;$o$,
$n$  -- A partner-tab invoice is "paid" by the tab: refunds come off the tab, never the drawer.
  IF _paid = 0 AND EXISTS (SELECT 1 FROM public.partner_tab_orders t WHERE t.order_id = _order_id) THEN
    _paid := _o.total;
    _method_key := 'partner_tab';
  END IF;
  IF round(_paid - _already, 2) <= 0 THEN RAISE EXCEPTION 'This order is fully refunded'; END IF;$n$);

CREATE OR REPLACE FUNCTION public._order_paid_total(_order_id uuid)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT CASE
    WHEN EXISTS (SELECT 1 FROM public.order_payments p WHERE p.order_id = _order_id)
      THEN (SELECT COALESCE(SUM(p.amount), 0) FROM public.order_payments p WHERE p.order_id = _order_id)
    WHEN EXISTS (SELECT 1 FROM public.partner_tab_orders t WHERE t.order_id = _order_id)
      THEN (SELECT o.total FROM public.orders o WHERE o.id = _order_id)
    ELSE 0 END
$$;
REVOKE EXECUTE ON FUNCTION public._order_paid_total(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._order_paid_total(uuid) TO service_role;

-- The "fully returned?" checks after a refund read the same paid amount.
SELECT pg_temp.patch_fn('public.refund_order_items_attributed(uuid, jsonb, text, text, text, uuid)'::regprocedure,
$o$  SELECT COALESCE(SUM(amount), 0) INTO _paid FROM public.order_payments WHERE order_id = _order_id;$o$,
$n$  _paid := public._order_paid_total(_order_id);$n$);
SELECT pg_temp.patch_fn('public.refund_order_full(uuid, text, text, text, uuid)'::regprocedure,
$o$  SELECT COALESCE(SUM(amount), 0) INTO _paid FROM public.order_payments WHERE order_id = _order_id;$o$,
$n$  _paid := public._order_paid_total(_order_id);$n$);
