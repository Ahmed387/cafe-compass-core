-- =====================================================================
-- Core re-architecture 3/6 — shift cash & handover
--   * One closing routine for manual, automatic and stuck-shift closures
--   * Treasury receives exactly the cash that leaves the drawer (cash drop)
--   * Changes to the drawer float between shifts are posted to treasury
--   * Editing closing cash recalculates the shortage and its attribution
-- =====================================================================

-- Tag shortage penalties explicitly instead of matching on the Arabic reason text.
ALTER TABLE public.staff_penalties ADD COLUMN IF NOT EXISTS source text;
UPDATE public.staff_penalties SET source = 'shift_shortage'
 WHERE source IS NULL AND shift_id IS NOT NULL AND reason LIKE 'عجز درج الوردية%';
CREATE INDEX IF NOT EXISTS staff_penalties_shift_source_idx ON public.staff_penalties(shift_id, source);

-- Closed shifts stay read-only except through the audited RPCs below,
-- which raise a transaction-local flag before touching the row.
CREATE OR REPLACE FUNCTION public.protect_closed_shift()
RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public' AS $$
BEGIN
  IF OLD.status = 'closed' AND NOT public.is_super_admin()
     AND COALESCE(current_setting('app.shift_rpc_edit', true), '') <> 'on' THEN
    RAISE EXCEPTION 'Closed shifts cannot be modified';
  END IF;
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------
-- Internal: (re)create the penalties for a drawer shortage.
-- Returns the stored resolution ('split' | 'staff' | 'venue').
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._attribute_shift_shortage(
  _s public.shifts, _short numeric, _mode text, _staff_id uuid, _reason text, _actor uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _staff uuid[]; _n int; _each numeric; _amt numeric;
BEGIN
  IF EXISTS (SELECT 1 FROM public.staff_penalties
              WHERE shift_id = _s.id AND source = 'shift_shortage' AND deducted_amount > 0) THEN
    RAISE EXCEPTION 'Shortage deductions were already taken in payroll';
  END IF;
  DELETE FROM public.staff_penalties WHERE shift_id = _s.id AND source = 'shift_shortage';
  IF COALESCE(_short, 0) <= 0 THEN RETURN NULL; END IF;

  IF _mode IS NULL OR _mode NOT IN ('split', 'staff', 'venue') THEN
    RAISE EXCEPTION 'Shortage must be attributed';
  END IF;

  IF _mode = 'venue' THEN
    IF NOT (public.is_super_admin() OR public.has_permission('expenses.approve') OR public.can_absorb_shortage()) THEN
      RAISE EXCEPTION 'Only a manager can approve venue-absorbed shortage';
    END IF;
    IF char_length(btrim(COALESCE(_reason, ''))) < 8
       OR char_length(regexp_replace(COALESCE(_reason, ''), '[^A-Za-zء-ي]', '', 'g')) < 5 THEN
      RAISE EXCEPTION 'A clear written reason is required for venue-absorbed shortage';
    END IF;
  ELSIF _mode = 'staff' THEN
    IF _staff_id IS NULL OR (NOT EXISTS (SELECT 1 FROM public.shift_staff WHERE shift_id = _s.id AND staff_id = _staff_id)
                             AND _staff_id IS DISTINCT FROM _s.user_id) THEN
      RAISE EXCEPTION 'Selected staff member is not on this shift';
    END IF;
    INSERT INTO public.staff_penalties (company_id, staff_id, amount, reason, shift_id, created_by, source)
    VALUES (_s.company_id, _staff_id, round(_short, 2), 'عجز درج الوردية', _s.id, _actor, 'shift_shortage');
  ELSE
    SELECT array_agg(DISTINCT x ORDER BY x) INTO _staff
      FROM (SELECT staff_id AS x FROM public.shift_staff WHERE shift_id = _s.id UNION SELECT _s.user_id) q;
    _n := array_length(_staff, 1);
    _each := floor(_short / _n * 100) / 100;
    FOR i IN 1.._n LOOP
      _amt := CASE WHEN i = _n THEN round(_short - _each * (_n - 1), 2) ELSE _each END;
      IF _amt > 0 THEN
        INSERT INTO public.staff_penalties (company_id, staff_id, amount, reason, shift_id, created_by, source)
        VALUES (_s.company_id, _staff[i], _amt, 'عجز درج الوردية (موزع)', _s.id, _actor, 'shift_shortage');
      END IF;
    END LOOP;
  END IF;
  RETURN _mode;
END $$;
REVOKE ALL ON FUNCTION public._attribute_shift_shortage(public.shifts, numeric, text, uuid, text, uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- Internal: electronic takings (Visa, InstaPay, wallets) go straight to their
-- treasury account when the shift closes, net of electronic refunds. This
-- replaces the old manual "card & wallet settlement" screen. Payments that were
-- already settled through that screen are skipped so nothing posts twice.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._post_shift_electronic(_s public.shifts, _day date)
RETURNS numeric LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _r record; _acc uuid; _posted numeric := 0;
BEGIN
  FOR _r IN
    WITH paid AS (
      SELECT public.tender_key(op.method_key) AS tk, SUM(op.amount) AS amt
        FROM public.orders o JOIN public.order_payments op ON op.order_id = o.id
       WHERE o.shift_id = _s.id AND public.tender_key(op.method_key) IN ('visa', 'instapay', 'wallet')
         AND (to_regclass('public.electronic_payment_settlements') IS NULL
              OR NOT EXISTS (SELECT 1 FROM public.electronic_payment_settlements es WHERE es.payment_id = op.id))
       GROUP BY 1
    ), refunded AS (
      SELECT public.tender_key(r.method_key) AS tk, SUM(r.amount) AS amt
        FROM public.order_refunds r
       WHERE r.shift_id = _s.id AND r.status = 'active' AND public.tender_key(r.method_key) IN ('visa', 'instapay', 'wallet')
       GROUP BY 1
    )
    SELECT COALESCE(p.tk, f.tk) AS tk, round(COALESCE(p.amt, 0) - COALESCE(f.amt, 0), 2) AS net
      FROM paid p FULL JOIN refunded f ON f.tk = p.tk
  LOOP
    CONTINUE WHEN _r.net = 0;
    _acc := public.default_cash_account(_s.company_id, CASE _r.tk WHEN 'visa' THEN 'card' ELSE _r.tk END);
    CONTINUE WHEN _acc IS NULL;
    PERFORM public.post_cash_txn(_s.company_id, _acc, CASE WHEN _r.net > 0 THEN 'in' ELSE 'out' END, abs(_r.net),
      'electronic_settlement', _r.tk, _day, 'shift', _s.id, 'Shift electronic takings (' || _r.tk || ')', NULL, false);
    _posted := _posted + _r.net;
  END LOOP;
  RETURN _posted;
END $$;
REVOKE ALL ON FUNCTION public._post_shift_electronic(public.shifts, date) FROM PUBLIC, anon, authenticated;

-- The manual settlement screen is retired (history in electronic_payment_settlements is kept).
DROP FUNCTION IF EXISTS public.pending_electronic_payments(date, date);
DROP FUNCTION IF EXISTS public.settle_electronic_payments(uuid[], date, text);

-- ---------------------------------------------------------------------
-- Internal: the only routine that closes a shift.
--   _source: 'manual' (handover dialog), 'auto' (end of day), 'force' (stuck shift)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._finalize_shift_close(
  _shift_id uuid, _counted numeric, _retained numeric, _mode text, _staff_id uuid,
  _notes text, _source text, _actor uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _s public.shifts; _cash_in numeric; _cash_out numeric; _exp numeric; _expected numeric;
  _counted_r numeric; _short numeric; _retained_r numeric; _drop numeric; _resolution text;
  _acc uuid; _closed_at timestamptz := now(); _fig jsonb; _name text;
BEGIN
  SELECT * INTO _s FROM public.shifts WHERE id = _shift_id FOR UPDATE;
  IF _s.id IS NULL THEN RAISE EXCEPTION 'Shift not found'; END IF;
  IF _s.status = 'closed' THEN RAISE EXCEPTION 'Shift already closed'; END IF;

  SELECT COALESCE(SUM(p.amount), 0) INTO _cash_in
    FROM public.orders o JOIN public.order_payments p ON p.order_id = o.id
   WHERE o.shift_id = _s.id AND p.method_key = 'cash';  -- all cash received; refunds (incl. cancellations) are subtracted below
  SELECT COALESCE(SUM(r.amount), 0) INTO _cash_out
    FROM public.order_refunds r
   WHERE r.shift_id = _s.id AND r.status = 'active' AND COALESCE(r.method_key, 'cash') = 'cash';
  _exp := public.shift_expense_total(_s.id);
  _expected := round(_s.opening_cash + _cash_in - _cash_out - _exp, 2);

  -- Automatic closures assume the drawer holds exactly the expected cash.
  _counted_r := round(CASE WHEN _source = 'manual' THEN _counted ELSE GREATEST(_expected, 0) END, 2);
  IF _counted_r IS NULL OR _counted_r < 0 THEN RAISE EXCEPTION 'Counted cash is required'; END IF;
  _retained_r := round(CASE WHEN _source = 'manual' THEN _retained ELSE LEAST(_s.opening_cash, _counted_r) END, 2);
  IF _retained_r IS NULL OR _retained_r < 0 OR _retained_r > _counted_r THEN
    RAISE EXCEPTION 'Retained float must be between 0 and the counted cash';
  END IF;

  _short := round(_expected - _counted_r, 2);
  _resolution := public._attribute_shift_shortage(_s, GREATEST(_short, 0), _mode, _staff_id, _notes, _actor);
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

  -- Treasury gets exactly the cash that physically left the drawer.
  _acc := public.default_cash_account(_s.company_id, 'cash');
  IF _acc IS NOT NULL AND _drop > 0 THEN
    PERFORM public.post_cash_txn(_s.company_id, _acc, 'in', _drop, 'shift_deposit', 'cash',
      public.business_date(_closed_at, _s.company_id), 'shift', _s.id, 'Shift cash drop', NULL, false);
  END IF;
  -- Card / InstaPay / wallet takings land in their own accounts.
  PERFORM public._post_shift_electronic(_s, public.business_date(_closed_at, _s.company_id));

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

  RETURN jsonb_build_object('shift_id', _s.id, 'expected', _expected, 'counted', _counted_r,
    'shortage', GREATEST(_short, 0), 'overage', GREATEST(-_short, 0),
    'retained', _retained_r, 'cash_drop', _drop);
END $$;
REVOKE ALL ON FUNCTION public._finalize_shift_close(uuid, numeric, numeric, text, uuid, text, text, uuid) FROM PUBLIC, anon, authenticated;

-- Access rules shared by the manual closing RPCs.
CREATE OR REPLACE FUNCTION public._assert_can_close_shift(_shift_id uuid)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _s public.shifts; _profile uuid := public.current_profile_id();
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO _s FROM public.shifts WHERE id = _shift_id AND company_id = public.current_company_id();
  IF _s.id IS NULL THEN RAISE EXCEPTION 'Shift not found'; END IF;
  IF NOT (public.has_permission('shifts.close') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF NOT public.can_access_branch(_s.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _s.user_id <> _profile AND NOT (public.has_permission('shifts.adjust_cash') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'You can only close your own shift';
  END IF;
END $$;
REVOKE ALL ON FUNCTION public._assert_can_close_shift(uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- Public closing RPCs
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.close_shift_handover(_shift_id uuid, _closing_cash numeric, _retained_float numeric,
  _shortage_mode text DEFAULT NULL, _shortage_staff_id uuid DEFAULT NULL, _notes text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  PERFORM public._assert_can_close_shift(_shift_id);
  RETURN public._finalize_shift_close(_shift_id, _closing_cash, _retained_float, _shortage_mode,
    _shortage_staff_id, _notes, 'manual', public.current_profile_id());
END $$;

-- Legacy signature: keeps the float that opened the shift in the drawer.
CREATE OR REPLACE FUNCTION public.close_shift(_shift_id uuid, _closing_cash numeric, _notes text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _opening numeric;
BEGIN
  PERFORM public._assert_can_close_shift(_shift_id);
  SELECT opening_cash INTO _opening FROM public.shifts WHERE id = _shift_id;
  PERFORM public._finalize_shift_close(_shift_id, _closing_cash, LEAST(_opening, COALESCE(_closing_cash, 0)),
    NULL, NULL, _notes, 'manual', public.current_profile_id());
  RETURN _shift_id;
END $$;

CREATE OR REPLACE FUNCTION public.force_close_stuck_shift(_branch_id uuid, _reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _id uuid; _profile uuid := public.current_profile_id(); _res jsonb;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('shifts.close') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF NOT public.can_access_branch(_branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  SELECT id INTO _id FROM public.shifts WHERE branch_id = _branch_id AND status = 'open' ORDER BY opened_at LIMIT 1;
  IF _id IS NULL THEN RAISE EXCEPTION 'لا توجد وردية مفتوحة على هذا الفرع'; END IF;
  _res := public._finalize_shift_close(_id, NULL, NULL, NULL, NULL,
    'إغلاق وردية عالقة: ' || COALESCE(NULLIF(btrim(_reason), ''), 'بدون سبب محدد'), 'force', _profile);
  RETURN _res || jsonb_build_object('expected_cash', _res->'expected', 'deposited', _res->'cash_drop');
END $$;

CREATE OR REPLACE FUNCTION public.auto_close_due_shifts()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _s public.shifts; _policy public.shift_policies; _close timestamptz; _closed integer := 0;
BEGIN
  FOR _s IN SELECT * FROM public.shifts WHERE status = 'open' LOOP
    SELECT * INTO _policy FROM public.shift_policies WHERE company_id = _s.company_id;
    _close := public.work_day_close_at(_s.company_id, _s.opened_at);
    IF _close IS NOT NULL AND _close <= _s.opened_at THEN
      _close := public.work_day_close_at(_s.company_id, _s.opened_at + interval '1 day');
    END IF;
    CONTINUE WHEN _close IS NULL;

    IF now() >= _close - make_interval(mins => COALESCE(_policy.warn_minutes, 30)) AND now() < _close
       AND NOT EXISTS (SELECT 1 FROM public.notifications
                        WHERE company_id = _s.company_id AND type = 'shift.closing_soon' AND data->>'shift_id' = _s.id::text) THEN
      INSERT INTO public.notifications (company_id, branch_id, user_id, type, severity, title, body, data)
      VALUES (_s.company_id, _s.branch_id, _s.user_id, 'shift.closing_soon', 'warning', 'الوردية هتتقفل قريب',
        'الوردية المفتوحة هتتقفل أوتوماتيك مع نهاية ساعات العمل.', jsonb_build_object('shift_id', _s.id, 'closes_at', _close));
    END IF;

    IF COALESCE(_policy.auto_close, true) AND now() >= _close THEN
      PERFORM public._finalize_shift_close(_s.id, NULL, NULL, NULL, NULL,
        'Auto-closed at end of working hours', 'auto', NULL);
      _closed := _closed + 1;
    END IF;
  END LOOP;
  RETURN _closed;
END $$;

-- ---------------------------------------------------------------------
-- Opening float: if the new float differs from what the last shift left in
-- the drawer, the difference came from (or went back to) the treasury.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.open_shift(_branch_id uuid, _opening_cash numeric DEFAULT 0)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _profile uuid := public.current_profile_id(); _company uuid := public.current_company_id();
  _id uuid; _prev numeric; _diff numeric; _acc uuid; _open numeric := round(COALESCE(_opening_cash, 0), 2); _name text;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('shifts.open') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF NOT public.can_access_branch(_branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _open < 0 THEN RAISE EXCEPTION 'Opening cash cannot be negative'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('shift_open:' || _branch_id::text));
  IF EXISTS (SELECT 1 FROM public.shifts WHERE branch_id = _branch_id AND status = 'open') THEN
    RAISE EXCEPTION 'Another shift is already open on this branch and must be closed first';
  END IF;

  SELECT COALESCE(s.retained_float, s.opening_cash) INTO _prev
    FROM public.shifts s WHERE s.branch_id = _branch_id AND s.status = 'closed'
   ORDER BY s.closed_at DESC NULLS LAST LIMIT 1;

  INSERT INTO public.shifts (company_id, branch_id, user_id, opening_cash)
  VALUES (_company, _branch_id, _profile, _open) RETURNING id INTO _id;

  _diff := round(_open - COALESCE(_prev, 0), 2);
  _acc := public.default_cash_account(_company, 'cash');
  IF _acc IS NOT NULL AND _diff <> 0 THEN
    PERFORM public.post_cash_txn(_company, _acc, CASE WHEN _diff > 0 THEN 'out' ELSE 'in' END, abs(_diff),
      'drawer_float', 'cash', public.business_today(_company), 'shift', _id,
      CASE WHEN _diff > 0 THEN 'Drawer float top-up' ELSE 'Drawer float returned' END, NULL, false);
  END IF;

  PERFORM public.log_audit('shift.open', 'pos', 'shifts', _id, NULL,
    jsonb_build_object('opening_cash', _open, 'previous_float', _prev, 'float_change', _diff), NULL, _branch_id);

  SELECT COALESCE(NULLIF(up.display_name, ''), up.first_name) INTO _name FROM public.user_profiles up WHERE up.id = _profile;
  INSERT INTO public.notifications (company_id, branch_id, user_id, type, severity, title, body, data)
  SELECT _company, _branch_id, tgt.pid, 'shift.open', 'info', 'بدء وردية جديدة',
    COALESCE(_name, 'الكاشير') || ' فتح وردية الساعة ' || to_char(now() AT TIME ZONE public.company_tz(_company), 'HH24:MI') ||
    ' بعهدة ' || to_char(_open, 'FM999999990.00') || ' ج.م',
    jsonb_build_object('shift_id', _id, 'opening_cash', _open)
  FROM (
    SELECT up.id AS pid FROM public.user_profiles up
      JOIN public.user_roles ur ON ur.user_id = up.id JOIN public.roles r ON r.id = ur.role_id
     WHERE up.company_id = _company AND up.is_active AND r.key = 'super_admin'
    UNION
    SELECT pa.user_id FROM public.partners pa WHERE pa.company_id = _company AND pa.status = 'active' AND pa.user_id IS NOT NULL
  ) tgt;
  RETURN _id;
END $$;

-- ---------------------------------------------------------------------
-- Correct a closed shift's counted cash: variance, cash drop, treasury and
-- shortage attribution are all recalculated together.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.update_shift_closing_cash(uuid, numeric, text);
CREATE OR REPLACE FUNCTION public.update_shift_closing_cash(_shift_id uuid, _closing_cash numeric, _reason text,
  _shortage_mode text DEFAULT NULL, _shortage_staff_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
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
  _resolution := public._attribute_shift_shortage(_s, GREATEST(_short, 0), _mode, _staff, _reason, _profile);

  PERFORM set_config('app.shift_rpc_edit', 'on', true);
  UPDATE public.shifts SET closing_cash = _counted, variance = round(_counted - COALESCE(expected_cash, 0), 2),
    retained_float = _retained, cash_drop = _drop, shortage_resolution = _resolution,
    shortage_staff_id = CASE WHEN _resolution = 'staff' THEN _staff END, updated_at = now()
  WHERE id = _s.id;

  _acc := public.default_cash_account(_s.company_id, 'cash');
  IF _acc IS NOT NULL AND _delta <> 0 THEN
    PERFORM public.post_cash_txn(_s.company_id, _acc, CASE WHEN _delta > 0 THEN 'in' ELSE 'out' END, abs(_delta),
      'shift_deposit', 'cash', public.business_today(_s.company_id), 'shift', _s.id,
      'Shift cash drop correction', NULL, false);
  END IF;

  PERFORM public.log_audit('shift.closing_cash_update', 'pos', 'shifts', _s.id,
    jsonb_build_object('closing_cash', _s.closing_cash, 'variance', _s.variance, 'cash_drop', _s.cash_drop, 'mode', _s.shortage_resolution),
    jsonb_build_object('closing_cash', _counted, 'variance', round(_counted - COALESCE(_s.expected_cash, 0), 2),
                       'cash_drop', _drop, 'treasury_delta', _delta, 'mode', _resolution),
    btrim(_reason), _s.branch_id);
  RETURN jsonb_build_object('closing_cash', _counted, 'variance', round(_counted - COALESCE(_s.expected_cash, 0), 2),
    'cash_drop', _drop, 'treasury_delta', _delta, 'shortage', GREATEST(_short, 0));
END $$;

CREATE OR REPLACE FUNCTION public.reassign_shift_shortage(_shift_id uuid, _mode text, _staff_id uuid DEFAULT NULL, _reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _s public.shifts; _profile uuid := public.current_profile_id(); _short numeric; _res text;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.is_super_admin() OR public.has_permission('expenses.approve') OR public.can_absorb_shortage()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF _reason IS NULL OR char_length(btrim(_reason)) < 8
     OR char_length(regexp_replace(_reason, '[^A-Za-zء-ي]', '', 'g')) < 5 THEN
    RAISE EXCEPTION 'A clear written reason is required';
  END IF;
  SELECT * INTO _s FROM public.shifts WHERE id = _shift_id AND company_id = public.current_company_id() FOR UPDATE;
  IF _s.id IS NULL THEN RAISE EXCEPTION 'Shift not found'; END IF;
  IF _s.status <> 'closed' THEN RAISE EXCEPTION 'Shift must be closed'; END IF;
  _short := round(GREATEST(-COALESCE(_s.variance, 0), 0), 2);
  IF _short <= 0 THEN RAISE EXCEPTION 'This shift has no shortage'; END IF;

  _res := public._attribute_shift_shortage(_s, _short, _mode, _staff_id, _reason, _profile);
  PERFORM set_config('app.shift_rpc_edit', 'on', true);
  UPDATE public.shifts SET shortage_resolution = _res,
    shortage_staff_id = CASE WHEN _res = 'staff' THEN _staff_id END, updated_at = now()
  WHERE id = _s.id;
  PERFORM public.log_audit('shift.shortage_reassign', 'pos', 'shifts', _s.id,
    jsonb_build_object('mode', _s.shortage_resolution, 'staff', _s.shortage_staff_id),
    jsonb_build_object('mode', _res, 'staff', _staff_id, 'amount', _short), btrim(_reason), _s.branch_id);
  RETURN jsonb_build_object('shortage', _short, 'mode', _res);
END $$;

REVOKE ALL ON FUNCTION public.close_shift_handover(uuid, numeric, numeric, text, uuid, text),
  public.close_shift(uuid, numeric, text), public.force_close_stuck_shift(uuid, text),
  public.open_shift(uuid, numeric), public.update_shift_closing_cash(uuid, numeric, text, text, uuid),
  public.reassign_shift_shortage(uuid, text, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.close_shift_handover(uuid, numeric, numeric, text, uuid, text),
  public.close_shift(uuid, numeric, text), public.force_close_stuck_shift(uuid, text),
  public.open_shift(uuid, numeric), public.update_shift_closing_cash(uuid, numeric, text, text, uuid),
  public.reassign_shift_shortage(uuid, text, uuid, text) TO authenticated;
REVOKE ALL ON FUNCTION public.auto_close_due_shifts() FROM PUBLIC, anon, authenticated;
