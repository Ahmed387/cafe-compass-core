-- =====================================================================
-- Owner rules (2026-10-24):
--   1) A cancelled item (or order) is not a refund. It is as if it was never
--      sold: its money does not count in the takings or the drawer, and nobody
--      bears it at shift close. Only NEW cancellations work this way; an old
--      auto-refund can be switched by hand, with its effect shown first.
--   2) Removing an item from a partner-tab invoice takes its amount off the
--      partner's account (before, only paid money came back, and a tab has no
--      payment rows, so the partner kept owing the cancelled item).
--
-- How:
--   * order_refunds.is_cancellation: set on insert for origin 'void' / 'cancel'
--     (the rows void_order_item and cancel_pos_order write). The row stays: the
--     money really went back to the customer, so the drawer math is unchanged.
--   * Cancellations never need a bearer (shift_refunds_to_decide, shift close,
--     set_refund_bearer, reassign_refund_bearer) and come off the payment
--     method takings in orders_period_summary.
--   * refund_reclassify_preview / reclassify_refund: super admin switches one
--     old auto-refund (origin void / cancel) between refund and cancellation.
--   * void_order_item treats a tab invoice as paid by the tab (method
--     partner_tab); trg_refund_adjusts_partner_tab then shrinks the tab.
--   * Data fix: the one tab still owing a removed item (261024-0002, 120) gets
--     the missing partner_tab row. Nothing is deleted.
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

-- Same, for an anchor that is meant to change everywhere it appears (_times = how many).
CREATE OR REPLACE FUNCTION pg_temp.patch_all(_sig regprocedure, _old text, _new text, _times int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE _def text := pg_get_functiondef(_sig); _n int;
BEGIN
  IF position(_new IN _def) > 0 THEN RAISE NOTICE '% already patched', _sig; RETURN; END IF;
  _n := (length(_def) - length(replace(_def, _old, ''))) / length(_old);
  IF _n <> _times THEN RAISE EXCEPTION 'Expected % copies of the anchor in %, found %', _times, _sig, _n; END IF;
  EXECUTE replace(_def, _old, _new);
END $$;

-- ---------------------------------------------------------------------
-- 1) The flag
-- ---------------------------------------------------------------------
ALTER TABLE public.order_refunds
  ADD COLUMN IF NOT EXISTS is_cancellation boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS reclassified_at timestamptz,
  ADD COLUMN IF NOT EXISTS reclassified_by uuid REFERENCES public.user_profiles(id),
  ADD COLUMN IF NOT EXISTS reclassify_note text;

COMMENT ON COLUMN public.order_refunds.is_cancellation IS
  'Money given back for a cancelled item/order (not a refund): no bearer, not in refund totals, off the payment-method takings.';

CREATE OR REPLACE FUNCTION public.trg_refund_mark_cancellation()
RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public' AS $$
BEGIN
  IF NEW.origin IN ('void', 'cancel') THEN NEW.is_cancellation := true; END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE TRIGGER t_refund_mark_cancellation BEFORE INSERT ON public.order_refunds
  FOR EACH ROW EXECUTE FUNCTION public.trg_refund_mark_cancellation();

-- ---------------------------------------------------------------------
-- 2) Nobody bears a cancellation
-- ---------------------------------------------------------------------
SELECT pg_temp.patch_fn('public.shift_refunds_to_decide(uuid)'::regprocedure,
$o$r.status = 'active' AND r.fault IS NULL$o$,
$n$r.status = 'active' AND r.fault IS NULL AND NOT r.is_cancellation$n$);

SELECT pg_temp.patch_all('public._finalize_shift_close(uuid, numeric, numeric, text, uuid, text, text, uuid)'::regprocedure,
$o$r.status = 'active' AND r.fault IS NULL$o$,
$n$r.status = 'active' AND r.fault IS NULL AND NOT r.is_cancellation$n$, 2);

SELECT pg_temp.patch_fn('public.set_refund_bearer(uuid, text, uuid)'::regprocedure,
$o$  IF _r.id IS NULL OR _r.status <> 'active' THEN RAISE EXCEPTION 'المرتجع مش موجود'; END IF;$o$,
$n$  IF _r.id IS NULL OR _r.status <> 'active' THEN RAISE EXCEPTION 'المرتجع مش موجود'; END IF;
  IF _r.is_cancellation THEN RAISE EXCEPTION 'ده صنف ملغي مش مرتجع، مفيش حد بيتحمله'; END IF;$n$);

SELECT pg_temp.patch_fn('public.reassign_refund_bearer(uuid, text, uuid, text)'::regprocedure,
$o$  IF _r.id IS NULL OR _r.status <> 'active' THEN RAISE EXCEPTION 'المرتجع مش موجود'; END IF;$o$,
$n$  IF _r.id IS NULL OR _r.status <> 'active' THEN RAISE EXCEPTION 'المرتجع مش موجود'; END IF;
  IF _r.is_cancellation THEN RAISE EXCEPTION 'ده صنف ملغي مش مرتجع، مفيش حد بيتحمله'; END IF;$n$);

-- ---------------------------------------------------------------------
-- 3) Takings per payment method: a cancellation comes off its method
--    (115 cash paid, 85 cancelled -> cash card shows 30).
-- ---------------------------------------------------------------------
SELECT pg_temp.patch_fn('public.orders_period_summary(uuid, date, date, text, text, text, uuid, text)'::regprocedure,
$o$    SELECT public.tender_key(p.method_key) AS k, SUM(p.amount) AS amt, COUNT(*) AS cnt
    FROM f JOIN order_payments p ON p.order_id = f.id
    WHERE f.status <> 'cancelled' GROUP BY 1$o$,
$n$    SELECT x.k, SUM(x.amt) AS amt, COUNT(*) FILTER (WHERE x.is_payment) AS cnt FROM (
      SELECT public.tender_key(p.method_key) AS k, p.amount AS amt, true AS is_payment
      FROM f JOIN order_payments p ON p.order_id = f.id
      WHERE f.status <> 'cancelled'
      UNION ALL
      -- Cancelled items after payment: as if never sold.
      SELECT public.tender_key(r.method_key), -r.amount, false
      FROM f JOIN order_refunds r ON r.order_id = f.id
      WHERE f.status <> 'cancelled' AND r.status = 'active' AND r.is_cancellation
        AND public.tender_key(r.method_key) <> 'partner_tab'
    ) x GROUP BY 1$n$);

-- ---------------------------------------------------------------------
-- 4) Removing an item from a partner-tab invoice comes off the tab
-- ---------------------------------------------------------------------
SELECT pg_temp.patch_fn('public.void_order_item(uuid, text, boolean, text, uuid)'::regprocedure,
$o$  SELECT COALESCE(SUM(amount), 0) INTO _already FROM public.order_refunds WHERE order_id = _oi.order_id AND status = 'active';$o$,
$n$  SELECT COALESCE(SUM(amount), 0) INTO _already FROM public.order_refunds WHERE order_id = _oi.order_id AND status = 'active';
  -- A partner-tab invoice is paid by the tab: what it cost before this line, plus
  -- what earlier removals already took off the tab.
  IF _paid = 0 AND EXISTS (SELECT 1 FROM public.partner_tab_orders t WHERE t.order_id = _oi.order_id) THEN
    _paid := round(COALESCE(_before, 0) + _already, 2);
    _method := 'partner_tab';
  END IF;$n$);

SELECT pg_temp.patch_fn('public.void_order_item(uuid, text, boolean, text, uuid)'::regprocedure,
$o$    _method := COALESCE((SELECT p.method_key FROM public.order_payments p WHERE p.order_id = _o.id ORDER BY p.amount DESC LIMIT 1), 'cash');$o$,
$n$    _method := COALESCE(_method, (SELECT p.method_key FROM public.order_payments p WHERE p.order_id = _o.id ORDER BY p.amount DESC LIMIT 1), 'cash');$n$);

-- ---------------------------------------------------------------------
-- 5) Switching an old auto-refund by hand, with its effect shown first
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.refund_reclassify_preview(_refund_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _r public.order_refunds; _o public.orders; _s public.shifts; _to boolean; _pen jsonb;
  _pen_open numeric; _pen_taken numeric; _blocker text; _effects jsonb := '[]'::jsonb; _method text;
BEGIN
  IF public.current_profile_id() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'السوبر أدمن بس هو اللي يغيّر نوع المرتجع'; END IF;
  SELECT * INTO _r FROM public.order_refunds WHERE id = _refund_id AND company_id = public.current_company_id();
  IF _r.id IS NULL OR _r.status <> 'active' THEN RAISE EXCEPTION 'المرتجع مش موجود'; END IF;
  SELECT * INTO _o FROM public.orders WHERE id = _r.order_id;
  SELECT * INTO _s FROM public.shifts WHERE id = _r.shift_id;
  _to := NOT _r.is_cancellation;
  _method := public.tender_key(COALESCE(_r.method_key, 'cash'));

  SELECT COALESCE(jsonb_agg(jsonb_build_object('staff', COALESCE(NULLIF(up.display_name, ''), up.first_name),
           'amount', sp.amount, 'deducted', sp.deducted_amount)), '[]'::jsonb),
         COALESCE(SUM(sp.amount - sp.deducted_amount), 0), COALESCE(SUM(sp.deducted_amount), 0)
    INTO _pen, _pen_open, _pen_taken
    FROM public.staff_penalties sp LEFT JOIN public.user_profiles up ON up.id = sp.staff_id
   WHERE sp.order_id = _r.order_id AND sp.source = 'refund' AND _r.fault IN ('staff', 'all_staff');

  IF COALESCE(_r.origin, 'manual') NOT IN ('void', 'cancel') THEN
    _blocker := 'ده مرتجع حقيقي اتعمل من زرار المرتجع، مش إلغاء صنف، فمينفعش يتحول';
  ELSIF _to AND _r.fault IN ('staff', 'all_staff') THEN
    _blocker := 'المرتجع ده متحمّل على موظفين. غيّر المتحمّل للكافيه الأول من صفحة الورديات، وبعدين حوّله لإلغاء';
  END IF;

  IF _to THEN
    _effects := jsonb_build_array(
      'هيختفي من إجمالي المرتجعات في صفحة المرتجعات (−' || _r.amount || ')',
      'هيتطرح من كارت ' || _method || ' في صفحة الطلبات (−' || _r.amount || ')',
      'مش هيظهر في قائمة "مين يتحمل" في قفل الوردية',
      'الدرج والخزنة وصافي الربح وتوزيع الأرباح مش هيتغيروا: الفلوس رجعت للعميل فعلًا، والصنف الملغي كان متشال من المبيعات قبل كده');
  ELSE
    _effects := jsonb_build_array(
      'هيرجع يظهر كمرتجع في صفحة المرتجعات (+' || _r.amount || ')',
      'هيرجع كارت ' || _method || ' في صفحة الطلبات يعرض المبلغ قبل الإلغاء (+' || _r.amount || ')',
      CASE WHEN _s.status = 'open' AND _r.fault IS NULL
           THEN 'الوردية لسه مفتوحة: هيظهر في قفل الوردية ولازم حد يحدد مين يتحمله'
           ELSE 'الوردية مقفولة: المتحمّل هيفضل زي ما هو، وتقدر تغيّره من صفحة الورديات' END,
      'الدرج والخزنة وصافي الربح وتوزيع الأرباح مش هيتغيروا');
  END IF;

  RETURN jsonb_build_object(
    'refund_id', _r.id, 'order_number', _o.order_number, 'amount', _r.amount, 'method', _method,
    'origin', _r.origin, 'reason', _r.reason, 'business_date', _r.business_date,
    'shift_status', _s.status, 'fault', _r.fault,
    'is_cancellation', _r.is_cancellation, 'to_cancellation', _to,
    'penalties', _pen, 'penalties_open', _pen_open, 'penalties_taken', _pen_taken,
    'can_change', _blocker IS NULL, 'blocker', _blocker, 'effects', _effects,
    'reclassified_at', _r.reclassified_at, 'reclassify_note', _r.reclassify_note);
END $$;

CREATE OR REPLACE FUNCTION public.reclassify_refund(_refund_id uuid, _as_cancellation boolean, _note text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _r public.order_refunds; _pv jsonb; _s public.shifts;
BEGIN
  IF public.current_profile_id() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'السوبر أدمن بس هو اللي يغيّر نوع المرتجع'; END IF;
  IF _note IS NULL OR length(btrim(_note)) < 3 THEN RAISE EXCEPTION 'اكتب سبب التغيير'; END IF;
  SELECT * INTO _r FROM public.order_refunds WHERE id = _refund_id AND company_id = public.current_company_id() FOR UPDATE;
  IF _r.id IS NULL OR _r.status <> 'active' THEN RAISE EXCEPTION 'المرتجع مش موجود'; END IF;
  IF _r.is_cancellation = COALESCE(_as_cancellation, false) THEN
    RETURN jsonb_build_object('refund_id', _r.id, 'is_cancellation', _r.is_cancellation, 'changed', false);
  END IF;
  _pv := public.refund_reclassify_preview(_refund_id);
  IF NOT (_pv->>'can_change')::boolean THEN RAISE EXCEPTION '%', _pv->>'blocker'; END IF;

  UPDATE public.order_refunds
     SET is_cancellation = _as_cancellation, reclassified_at = now(),
         reclassified_by = public.current_profile_id(), reclassify_note = btrim(_note)
   WHERE id = _r.id;
  SELECT * INTO _s FROM public.shifts WHERE id = _r.shift_id;
  PERFORM public.log_audit('refund.reclassified', 'pos', 'order_refunds', _r.id,
    jsonb_build_object('is_cancellation', _r.is_cancellation),
    jsonb_build_object('is_cancellation', _as_cancellation, 'amount', _r.amount, 'effects', _pv->'effects'),
    btrim(_note), _s.branch_id);
  RETURN jsonb_build_object('refund_id', _r.id, 'is_cancellation', _as_cancellation, 'changed', true, 'effects', _pv->'effects');
END $$;

REVOKE ALL ON FUNCTION public.refund_reclassify_preview(uuid), public.reclassify_refund(uuid, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.refund_reclassify_preview(uuid), public.reclassify_refund(uuid, boolean, text) TO authenticated;

-- ---------------------------------------------------------------------
-- 6) Data fix: tabs that still owe items removed before this fix.
--    (2026-10-24: only 261024-0002, Frappe 120.) A partner_tab row is added;
--    the trigger takes it off the tab. No row is changed by hand or deleted.
-- ---------------------------------------------------------------------
INSERT INTO public.order_refunds (company_id, branch_id, order_id, shift_id, kind, amount, tax_amount,
  method_key, reason, status, origin, fault, created_by)
SELECT o.company_id, o.branch_id, o.id, o.shift_id,
       CASE WHEN o.status = 'cancelled' THEN 'full' ELSE 'partial' END,
       round(t.total_amount - o.total, 2), 0, 'partner_tab',
       'تصحيح: صنف ملغي كان لسه على حساب الشريك', 'active', 'void', 'venue', o.created_by
  FROM public.partner_tab_orders t JOIN public.orders o ON o.id = t.order_id
 WHERE NOT t.is_settled
   AND round(t.total_amount - o.total, 2) > 0
   AND EXISTS (SELECT 1 FROM public.order_items i WHERE i.order_id = o.id AND i.status = 'voided')
   AND NOT EXISTS (SELECT 1 FROM public.order_refunds r WHERE r.order_id = o.id AND r.status = 'active'
                    AND public.tender_key(r.method_key) = 'partner_tab');
