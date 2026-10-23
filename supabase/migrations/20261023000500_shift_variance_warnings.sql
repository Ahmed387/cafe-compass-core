-- Drawer differences stay on their shift (the day it opened). A shortage is no
-- longer charged by whoever closes: unless a super admin decides at close, it is
-- left "pending" and the super admins get a warning to choose who bears it (the
-- venue, one team member or the whole team). An overage posts normally with a
-- warning.

-- The super admin settles (or later changes) who bears a closed shift's shortage.
CREATE OR REPLACE FUNCTION public.reassign_shift_shortage(_shift_id uuid, _mode text, _staff_id uuid DEFAULT NULL::uuid, _reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _s public.shifts; _profile uuid := public.current_profile_id(); _short numeric; _res text;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  SELECT * INTO _s FROM public.shifts WHERE id = _shift_id AND company_id = public.current_company_id() FOR UPDATE;
  IF _s.id IS NULL THEN RAISE EXCEPTION 'Shift not found'; END IF;
  IF _s.status <> 'closed' THEN RAISE EXCEPTION 'Shift must be closed'; END IF;
  -- Changing an earlier decision needs a reason; the first decision only for the venue.
  IF _s.shortage_resolution IS DISTINCT FROM 'pending'
     AND (_reason IS NULL OR char_length(btrim(_reason)) < 8
          OR char_length(regexp_replace(_reason, '[^A-Za-zء-ي]', '', 'g')) < 5) THEN
    RAISE EXCEPTION 'A clear written reason is required';
  END IF;
  _short := round(GREATEST(-COALESCE(_s.variance, 0), 0), 2);
  IF _short <= 0 THEN RAISE EXCEPTION 'This shift has no shortage'; END IF;
  IF COALESCE(_mode, 'pending') = 'pending' THEN RAISE EXCEPTION 'Shortage must be attributed'; END IF;

  _res := public._attribute_shift_shortage(_s, _short, _mode, _staff_id, _reason, _profile);
  PERFORM set_config('app.shift_rpc_edit', 'on', true);
  UPDATE public.shifts SET shortage_resolution = _res,
    shortage_staff_id = CASE WHEN _res = 'staff' THEN _staff_id END, updated_at = now()
  WHERE id = _s.id;
  -- The warning about this shortage has been dealt with.
  UPDATE public.notifications SET read_at = COALESCE(read_at, now())
   WHERE type = 'shift.shortage' AND data->>'shift_id' = _s.id::text;
  PERFORM public.log_audit('shift.shortage_reassign', 'pos', 'shifts', _s.id,
    jsonb_build_object('mode', _s.shortage_resolution, 'staff', _s.shortage_staff_id),
    jsonb_build_object('mode', _res, 'staff', _staff_id, 'amount', _short), NULLIF(btrim(COALESCE(_reason, '')), ''), _s.branch_id);
  RETURN jsonb_build_object('shortage', _short, 'mode', _res);
END $function$;

-- Shortages still waiting for the super admin's decision.
CREATE OR REPLACE FUNCTION public.pending_shift_shortages()
 RETURNS TABLE(shift_id uuid, business_date date, opened_at timestamptz, closed_at timestamptz, cashier text, shortage numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT s.id, s.business_date, s.opened_at, s.closed_at,
         COALESCE(NULLIF(up.display_name, ''), up.first_name), round(-s.variance, 2)
    FROM public.shifts s LEFT JOIN public.user_profiles up ON up.id = s.user_id
   WHERE public.is_super_admin() AND s.company_id = public.current_company_id()
     AND s.status = 'closed' AND s.shortage_resolution = 'pending' AND s.variance < 0
   ORDER BY s.closed_at DESC
$function$;
REVOKE ALL ON FUNCTION public.pending_shift_shortages() FROM anon;

CREATE OR REPLACE FUNCTION public._finalize_shift_close(_shift_id uuid, _counted numeric, _retained numeric, _mode text, _staff_id uuid, _notes text, _source text, _actor uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _s public.shifts; _cash_in numeric; _cash_out numeric; _exp numeric; _expected numeric;
  _counted_r numeric; _short numeric; _retained_r numeric; _drop numeric; _resolution text;
  _acc uuid; _closed_at timestamptz := now(); _fig jsonb; _name text;
BEGIN
  SELECT * INTO _s FROM public.shifts WHERE id = _shift_id FOR UPDATE;
  IF _s.id IS NULL THEN RAISE EXCEPTION 'Shift not found'; END IF;
  IF _s.status = 'closed' THEN RAISE EXCEPTION 'Shift already closed'; END IF;
  IF EXISTS (SELECT 1 FROM public.order_refunds r WHERE r.shift_id = _s.id AND r.status = 'active' AND r.fault IS NULL) THEN
    RAISE EXCEPTION 'فيه % مرتجع في الوردية دي لسه محتاج تحدد مين يتحمله قبل القفل',
      (SELECT count(*) FROM public.order_refunds r WHERE r.shift_id = _s.id AND r.status = 'active' AND r.fault IS NULL);
  END IF;

  -- The drawer has one definition: _shift_drawer.
  _fig := public._shift_drawer(_s);
  _cash_in := (_fig->>'cash_in')::numeric; _cash_out := (_fig->>'cash_refunds')::numeric;
  _exp := (_fig->>'expenses')::numeric; _expected := (_fig->>'expected')::numeric;

  -- Automatic closures assume the drawer holds exactly the expected cash.
  _counted_r := round(CASE WHEN _source = 'manual' THEN _counted ELSE GREATEST(_expected, 0) END, 2);
  IF _counted_r IS NULL OR _counted_r < 0 THEN RAISE EXCEPTION 'Counted cash is required'; END IF;
  _retained_r := round(CASE WHEN _source = 'manual' THEN _retained ELSE LEAST(_s.opening_cash, _counted_r) END, 2);
  IF _retained_r IS NULL OR _retained_r < 0 OR _retained_r > _counted_r THEN
    RAISE EXCEPTION 'Retained float must be between 0 and the counted cash';
  END IF;

  _short := round(_expected - _counted_r, 2);
  -- Only a super admin decides who bears a shortage; until then it waits.
  IF _short > 0 AND (COALESCE(_mode, 'pending') = 'pending' OR NOT public.is_super_admin()) THEN
    _resolution := 'pending';
  ELSE
    _resolution := public._attribute_shift_shortage(_s, GREATEST(_short, 0), _mode, _staff_id, _notes, _actor);
  END IF;
  _drop := round(_counted_r - _retained_r, 2);

  UPDATE public.shifts SET
    status = 'closed', closing_cash = _counted_r, expected_cash = _expected,
    variance = round(_counted_r - _expected, 2), shift_expenses = _exp,
    retained_float = _retained_r, cash_drop = _drop,
    shortage_resolution = _resolution,
    shortage_staff_id = CASE WHEN _resolution = 'staff' THEN _staff_id END,
    notes = CASE WHEN _source = 'manual' THEN _notes
                 ELSE COALESCE(NULLIF(notes, '') || ' | ', '') || COALESCE(_notes, '') END,
    closed_at = _closed_at, closed_by = _actor, updated_at = now()
  WHERE id = _s.id;

  -- Paid orders still "pending" when the shift ends were served: complete them so
  -- they can be refunded later and don't look unfinished.
  UPDATE public.orders o SET status = 'completed', completed_at = COALESCE(o.completed_at, _closed_at), updated_at = now()
   WHERE o.shift_id = _s.id AND o.status = 'pending'
     AND COALESCE((SELECT SUM(p.amount) FROM public.order_payments p WHERE p.order_id = o.id), 0) >= o.total;

  -- Treasury gets exactly the cash that physically left the drawer.
  _acc := public.default_cash_account(_s.company_id, 'cash');
  IF _acc IS NOT NULL AND _drop > 0 THEN
    PERFORM public.post_cash_txn(_s.company_id, _acc, 'in', _drop, 'shift_deposit', 'cash',
      _s.business_date, 'shift', _s.id, 'Shift cash drop', NULL, false);
  END IF;
  -- Card / InstaPay / wallet takings land in their own accounts.
  PERFORM public._post_shift_electronic(_s, _s.business_date);

  PERFORM public.log_audit('shift.close', 'pos', 'shifts', _s.id, NULL,
    jsonb_build_object('source', _source, 'expected', _expected, 'counted', _counted_r,
      'retained', _retained_r, 'cash_drop', _drop, 'drawer_expenses', _exp,
      'shortage', GREATEST(_short, 0), 'overage', GREATEST(-_short, 0), 'mode', _resolution),
    _notes, _s.branch_id);

  -- Close-out summary for super admins and partners, from the shared shift figures.
  SELECT * INTO _s FROM public.shifts WHERE id = _shift_id;
  _fig := public._shift_figures(_s);
  SELECT COALESCE(NULLIF(up.display_name, ''), up.first_name) INTO _name FROM public.user_profiles up WHERE up.id = _s.user_id;
  INSERT INTO public.notifications (company_id, branch_id, user_id, type, severity, title, body, data)
  SELECT _s.company_id, _s.branch_id, tgt.pid, 'shift.close', 'info', 'تقرير تقفيل وردية',
    'اتقفلت وردية ' || COALESCE(_name, 'الكاشير') || ' (' ||
      to_char(_s.opened_at AT TIME ZONE public.company_tz(_s.company_id), 'HH24:MI') || ' ← ' ||
      to_char(_closed_at AT TIME ZONE public.company_tz(_s.company_id), 'HH24:MI') || '). صافي المبيعات: ' ||
      to_char((_fig->>'netSales')::numeric, 'FM999999990.00') || ' ج.م، مجمل الربح: ' ||
      to_char((_fig->>'grossMargin')::numeric, 'FM999999990.00') || ' ج.م، نزل للخزنة: ' ||
      to_char(_drop, 'FM999999990.00') || ' ج.م.',
    jsonb_build_object('shift_id', _s.id, 'net_sales', _fig->'netSales', 'gross_margin', _fig->'grossMargin',
      'cash_drop', _drop, 'variance', _s.variance, 'source', _source)
  FROM (
    SELECT up.id AS pid FROM public.user_profiles up
      JOIN public.user_roles ur ON ur.user_id = up.id JOIN public.roles r ON r.id = ur.role_id
     WHERE up.company_id = _s.company_id AND up.is_active AND r.key = 'super_admin'
    UNION
    SELECT pa.user_id FROM public.partners pa
     WHERE pa.company_id = _s.company_id AND pa.status = 'active' AND pa.user_id IS NOT NULL
  ) tgt;

  -- Drawer difference: it stays on this shift (its business day) and the super
  -- admins get a warning. A shortage nobody was charged for waits for their call.
  IF COALESCE(_s.variance, 0) <> 0 THEN
    INSERT INTO public.notifications (company_id, branch_id, user_id, type, severity, title, body, data)
    SELECT _s.company_id, _s.branch_id, tgt.pid,
      CASE WHEN _s.variance < 0 THEN 'shift.shortage' ELSE 'shift.overage' END, 'warning',
      CASE WHEN _s.variance < 0 THEN 'خلي بالك: عجز في وردية' ELSE 'خلي بالك: زيادة في وردية' END,
      CASE WHEN _s.variance < 0 THEN
        'عجز ' || to_char(-_s.variance, 'FM999999990.00') || ' ج.م في وردية ' || COALESCE(_name, 'الكاشير') ||
        ' اللي اتفتحت يوم ' || to_char(_s.business_date, 'DD/MM/YYYY') ||
        CASE WHEN _s.shortage_resolution = 'pending'
             THEN '. اختار مين يتحمله: المكان، أو حد من التيم، أو التيم كله.'
             ELSE '. اتحدد مين يتحمله وقت القفل، وتقدر تغيره.' END
      ELSE
        'زيادة ' || to_char(_s.variance, 'FM999999990.00') || ' ج.م في وردية ' || COALESCE(_name, 'الكاشير') ||
        ' اللي اتفتحت يوم ' || to_char(_s.business_date, 'DD/MM/YYYY') || '. نزلت الخزنة مع الوردية، راجعها.'
      END,
      jsonb_build_object('shift_id', _s.id, 'variance', _s.variance, 'business_date', _s.business_date,
        'resolution', _s.shortage_resolution)
    FROM (
      SELECT DISTINCT up.id AS pid FROM public.user_profiles up
        JOIN public.user_roles ur ON ur.user_id = up.id JOIN public.roles r ON r.id = ur.role_id
       WHERE up.company_id = _s.company_id AND up.is_active AND r.key = 'super_admin'
    ) tgt;
  END IF;

  RETURN jsonb_build_object('shift_id', _s.id, 'expected', _expected, 'counted', _counted_r,
    'shortage', GREATEST(_short, 0), 'overage', GREATEST(-_short, 0),
    'retained', _retained_r, 'cash_drop', _drop);
END $function$;

-- Correcting a closed shift's cash keeps the treasury entry on the shift's day.
CREATE OR REPLACE FUNCTION public.update_shift_closing_cash(_shift_id uuid, _closing_cash numeric, _reason text, _shortage_mode text DEFAULT NULL::text, _shortage_staff_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _s public.shifts; _profile uuid := public.current_profile_id(); _counted numeric := round(_closing_cash, 2);
  _retained numeric; _drop numeric; _delta numeric; _short numeric; _mode text; _staff uuid; _resolution text; _acc uuid;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.is_super_admin() OR public.has_permission('shifts.adjust_cash')) THEN
    RAISE EXCEPTION 'غير مصرح بتعديل النقدية الختامية';
  END IF;
  IF _counted IS NULL OR _counted < 0 THEN RAISE EXCEPTION 'قيمة غير صالحة'; END IF;
  IF char_length(btrim(COALESCE(_reason, ''))) < 3 THEN RAISE EXCEPTION 'يجب كتابة سبب التعديل'; END IF;
  SELECT * INTO _s FROM public.shifts WHERE id = _shift_id AND company_id = public.current_company_id() FOR UPDATE;
  IF _s.id IS NULL THEN RAISE EXCEPTION 'الوردية غير موجودة'; END IF;
  IF _s.status <> 'closed' THEN RAISE EXCEPTION 'الوردية لم تُغلق بعد'; END IF;

  _retained := LEAST(COALESCE(_s.retained_float, _s.opening_cash), _counted);
  _drop := round(_counted - _retained, 2);
  _delta := round(_drop - COALESCE(_s.cash_drop, COALESCE(_s.closing_cash, 0) - _s.opening_cash), 2);
  _short := round(COALESCE(_s.expected_cash, 0) - _counted, 2);
  _mode := COALESCE(_shortage_mode, _s.shortage_resolution);
  _staff := COALESCE(_shortage_staff_id, _s.shortage_staff_id);
  IF _short > 0 AND (COALESCE(_mode, 'pending') = 'pending' OR NOT public.is_super_admin()) THEN
    -- Any earlier charge is cleared; the super admin decides again.
    PERFORM public._attribute_shift_shortage(_s, 0, NULL, NULL, _reason, _profile);
    _resolution := 'pending';
  ELSE
    _resolution := public._attribute_shift_shortage(_s, GREATEST(_short, 0), _mode, _staff, _reason, _profile);
  END IF;

  PERFORM set_config('app.shift_rpc_edit', 'on', true);
  UPDATE public.shifts SET closing_cash = _counted, variance = round(_counted - COALESCE(expected_cash, 0), 2),
    retained_float = _retained, cash_drop = _drop, shortage_resolution = _resolution,
    shortage_staff_id = CASE WHEN _resolution = 'staff' THEN _staff END, updated_at = now()
  WHERE id = _s.id;

  _acc := public.default_cash_account(_s.company_id, 'cash');
  IF _acc IS NOT NULL AND _delta <> 0 THEN
    PERFORM public.post_cash_txn(_s.company_id, _acc, CASE WHEN _delta > 0 THEN 'in' ELSE 'out' END, abs(_delta),
      'shift_deposit', 'cash', _s.business_date, 'shift', _s.id,
      'Shift cash drop correction', NULL, false);
  END IF;

  PERFORM public.log_audit('shift.closing_cash_update', 'pos', 'shifts', _s.id,
    jsonb_build_object('closing_cash', _s.closing_cash, 'variance', _s.variance, 'cash_drop', _s.cash_drop, 'mode', _s.shortage_resolution),
    jsonb_build_object('closing_cash', _counted, 'variance', round(_counted - COALESCE(_s.expected_cash, 0), 2),
                       'cash_drop', _drop, 'treasury_delta', _delta, 'mode', _resolution),
    btrim(_reason), _s.branch_id);
  RETURN jsonb_build_object('closing_cash', _counted, 'variance', round(_counted - COALESCE(_s.expected_cash, 0), 2),
    'cash_drop', _drop, 'treasury_delta', _delta, 'shortage', GREATEST(_short, 0));
END $function$;
