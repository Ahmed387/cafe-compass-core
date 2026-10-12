-- =====================================================================
-- Core re-architecture 4/6 — payroll
--   * One calculation (_payroll_lines) feeds both the preview and the run,
--     so what managers see is exactly what gets generated
--   * Deduction order: absence → penalties → advances, capped at what the
--     employee earns; anything left over carries to next month (never wiped)
--   * A month can't be generated twice, even with shifted dates
--   * Dates use the café's business day (Cairo time)
-- =====================================================================

-- Payroll month an advance starts being deducted (existing advances: their own month).
ALTER TABLE public.employee_advances ADD COLUMN IF NOT EXISTS deduct_from date;
UPDATE public.employee_advances SET deduct_from = date_trunc('month', advance_date)::date WHERE deduct_from IS NULL;

-- Outstanding (not yet recovered) amounts.
CREATE OR REPLACE FUNCTION public.penalty_outstanding(_p public.staff_penalties)
RETURNS numeric LANGUAGE sql IMMUTABLE SET search_path TO 'public' AS $$
  SELECT CASE WHEN _p.is_settled THEN 0 ELSE GREATEST(round(_p.amount - COALESCE(_p.deducted_amount, 0), 2), 0) END
$$;
CREATE OR REPLACE FUNCTION public.advance_outstanding(_a public.employee_advances)
RETURNS numeric LANGUAGE sql IMMUTABLE SET search_path TO 'public' AS $$
  SELECT CASE WHEN _a.status <> 'active' THEN 0 ELSE GREATEST(round(_a.amount - COALESCE(_a.deducted_amount, 0), 2), 0) END
$$;

-- ---------------------------------------------------------------------
-- The single payroll calculation.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._payroll_lines(_company uuid, _start date, _end date)
RETURNS TABLE(user_id uuid, employee_name text, job_title text, hire_date date, base_salary numeric,
  prorated_salary numeric, worked_days integer, worked_hours numeric, shifts_count integer, absent_days integer,
  deduction_days numeric, absence_deduction numeric, bonuses numeric, penalties_due numeric, penalties numeric,
  advances_due numeric, advances numeric, carried_forward numeric, net_pay numeric, already_generated boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  WITH staff AS (
    SELECT p.id AS uid, p.hire_date AS hd, p.job_title AS jt, COALESCE(s.base_salary, 0) AS bs,
      COALESCE(NULLIF(p.display_name, ''), NULLIF(btrim(COALESCE(p.first_name, '') || ' ' || COALESCE(p.last_name, '')), ''), p.email) AS nm
    FROM public.user_profiles p
    LEFT JOIN LATERAL (
      SELECT es.base_salary FROM public.employee_salaries es
       WHERE es.user_id = p.id AND es.company_id = _company AND es.is_active
       ORDER BY es.effective_from DESC NULLS LAST, es.created_at DESC LIMIT 1) s ON true
    WHERE p.company_id = _company AND p.is_active
      -- Silent partners are paid through profit, not payroll.
      AND NOT EXISTS (SELECT 1 FROM public.partners pt WHERE pt.company_id = _company AND pt.user_id = p.id
                        AND pt.status <> 'exited' AND NOT pt.is_managing_staff)
      -- Super admins are owners unless they also work as managing staff.
      AND (p.is_managing_staff OR NOT EXISTS (
            SELECT 1 FROM public.user_roles ur JOIN public.roles r ON r.id = ur.role_id
             WHERE ur.user_id = p.id AND r.key = 'super_admin'))
  ), calc AS (
    SELECT st.*,
      public._prorated_salary(st.bs, st.hd, _start, _end) AS pr,
      (SELECT count(DISTINCT a.work_date)::int FROM public.attendance a
        WHERE a.user_id = st.uid AND a.company_id = _company AND a.work_date BETWEEN _start AND _end
          AND a.status IN ('present', 'half_day', 'permission')) AS wd,
      (SELECT round(COALESCE(sum(a.minutes_worked), 0) / 60.0, 2) FROM public.attendance a
        WHERE a.user_id = st.uid AND a.company_id = _company AND a.work_date BETWEEN _start AND _end) AS wh,
      (SELECT count(*)::int FROM public.shifts sh
        WHERE sh.user_id = st.uid AND sh.opened_at >= public.business_day_start(_start, _company)
          AND sh.opened_at < public.business_day_start(_end + 1, _company)) AS sc,
      (SELECT count(*)::int FROM public.attendance a
        WHERE a.user_id = st.uid AND a.company_id = _company AND a.status = 'absent'
          AND a.work_date BETWEEN _start AND _end) AS ad,
      public.attendance_deduction_days(st.uid, _company, _start, _end) AS dd,
      (SELECT COALESCE(sum(sb.amount), 0) FROM public.staff_bonuses sb
        WHERE sb.company_id = _company AND sb.staff_id = st.uid AND NOT sb.is_settled AND sb.payroll_id IS NULL
          -- Unsettled bonuses up to the end of the month (one added after its month
          -- was paid rolls into the next payroll).
          AND sb.bonus_date <= _end) AS bon,
      -- Every unrecovered penalty up to the end of the month (older ones carry forward).
      (SELECT COALESCE(sum(public.penalty_outstanding(sp)), 0) FROM public.staff_penalties sp
        WHERE sp.company_id = _company AND sp.staff_id = st.uid
          AND public.business_date(sp.created_at, _company) <= _end) AS pen_due,
      (SELECT COALESCE(sum(public.advance_outstanding(ea)), 0) FROM public.employee_advances ea
        WHERE ea.company_id = _company AND ea.user_id = st.uid AND COALESCE(ea.deduct_from, ea.advance_date) <= _end) AS adv_due,
      EXISTS (SELECT 1 FROM public.salary_payments sp2
               WHERE sp2.user_id = st.uid AND sp2.status = 'active' AND sp2.salary_kind = 'regular'
                 AND sp2.period_start <= _end AND sp2.period_end >= _start) AS gen
    FROM staff st
  ), capped AS (
    SELECT c.*,
      LEAST(round(c.bs / 30.0 * c.dd, 2), c.pr + c.bon) AS abs_d
    FROM calc c
  ), steps AS (
    SELECT c.*,
      LEAST(c.pen_due, GREATEST(c.pr + c.bon - c.abs_d, 0)) AS pen_d
    FROM capped c
  ), final AS (
    SELECT s.*,
      LEAST(s.adv_due, GREATEST(s.pr + s.bon - s.abs_d - s.pen_d, 0)) AS adv_d
    FROM steps s
  )
  SELECT f.uid, f.nm, f.jt, f.hd, f.bs, f.pr, f.wd, f.wh, f.sc, f.ad, f.dd,
    f.abs_d, round(f.bon, 2), round(f.pen_due, 2), round(f.pen_d, 2), round(f.adv_due, 2), round(f.adv_d, 2),
    round((f.pen_due - f.pen_d) + (f.adv_due - f.adv_d), 2),
    round(f.pr + f.bon - f.abs_d - f.pen_d - f.adv_d, 2), f.gen
  FROM final f
  ORDER BY f.nm;
$$;
REVOKE ALL ON FUNCTION public._payroll_lines(uuid, date, date) FROM PUBLIC, anon, authenticated;

DROP FUNCTION IF EXISTS public.hr_payroll_preview(date, date);
CREATE FUNCTION public.hr_payroll_preview(_period_start date, _period_end date)
RETURNS TABLE(user_id uuid, employee_name text, job_title text, hire_date date, base_salary numeric,
  prorated_salary numeric, worked_days integer, worked_hours numeric, shifts_count integer, absent_days integer,
  deduction_days numeric, absence_deduction numeric, bonuses numeric, penalties_due numeric, penalties numeric,
  advances_due numeric, advances numeric, carried_forward numeric, net_pay numeric, already_generated boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NOT (public.has_permission('payroll.view') OR public.is_super_admin()) THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF _period_start IS NULL OR _period_end IS NULL OR _period_end < _period_start THEN RAISE EXCEPTION 'invalid payroll period'; END IF;
  RETURN QUERY SELECT * FROM public._payroll_lines(public.current_company_id(), _period_start, _period_end);
END $$;
REVOKE ALL ON FUNCTION public.hr_payroll_preview(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.hr_payroll_preview(date, date) TO authenticated;

-- ---------------------------------------------------------------------
-- Generate the month. Recovers penalties (oldest first) then advances,
-- each only up to the amount actually deducted; the rest stays open.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.run_payroll(_period_start date, _period_end date)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _company uuid := public.current_company_id(); _actor uuid := public.current_profile_id();
  _l record; _pay uuid; _left numeric; _take numeric;
  _rp public.staff_penalties; _ra public.employee_advances; _count integer := 0;
BEGIN
  IF _actor IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('payroll.manage') OR public.is_super_admin()) THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF _period_start IS NULL OR _period_end IS NULL OR _period_end < _period_start THEN RAISE EXCEPTION 'invalid payroll period'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('payroll:' || _company::text));

  FOR _l IN SELECT * FROM public._payroll_lines(_company, _period_start, _period_end) x
             WHERE NOT x.already_generated AND x.prorated_salary > 0 LOOP
    INSERT INTO public.salary_payments (company_id, user_id, period_start, period_end, base_amount, bonus, deduction,
      absence_deduction, penalty_deduction, advance_deduction, created_by, salary_kind)
    VALUES (_company, _l.user_id, _period_start, _period_end, _l.prorated_salary, _l.bonuses,
      round(_l.absence_deduction + _l.penalties + _l.advances, 2),
      _l.absence_deduction, _l.penalties, _l.advances, _actor, 'regular')
    RETURNING id INTO _pay;

    -- Penalties, oldest first.
    _left := _l.penalties;
    FOR _rp IN SELECT sp.* FROM public.staff_penalties sp
               WHERE sp.company_id = _company AND sp.staff_id = _l.user_id
                 AND public.penalty_outstanding(sp) > 0
                 AND public.business_date(sp.created_at, _company) <= _period_end
               ORDER BY sp.created_at, sp.id FOR UPDATE LOOP
      EXIT WHEN _left <= 0;
      _take := LEAST(public.penalty_outstanding(_rp), _left);
      UPDATE public.staff_penalties SET deducted_amount = round(deducted_amount + _take, 2),
        is_settled = (round(deducted_amount + _take, 2) >= amount), payroll_id = _pay
       WHERE id = _rp.id;
      INSERT INTO public.payroll_deductions (company_id, salary_payment_id, source_type, source_id, amount)
      VALUES (_company, _pay, 'penalty', _rp.id, _take);
      _left := round(_left - _take, 2);
    END LOOP;

    -- Advances, oldest first.
    _left := _l.advances;
    FOR _ra IN SELECT ea.* FROM public.employee_advances ea
               WHERE ea.company_id = _company AND ea.user_id = _l.user_id
                 AND public.advance_outstanding(ea) > 0 AND COALESCE(ea.deduct_from, ea.advance_date) <= _period_end
               ORDER BY COALESCE(ea.deduct_from, ea.advance_date), ea.advance_date, ea.created_at, ea.id FOR UPDATE LOOP
      EXIT WHEN _left <= 0;
      _take := LEAST(public.advance_outstanding(_ra), _left);
      UPDATE public.employee_advances SET deducted_amount = round(deducted_amount + _take, 2),
        settled_payment_id = CASE WHEN round(deducted_amount + _take, 2) >= amount THEN _pay ELSE settled_payment_id END,
        settled_at = CASE WHEN round(deducted_amount + _take, 2) >= amount THEN now() ELSE settled_at END
       WHERE id = _ra.id;
      INSERT INTO public.payroll_deductions (company_id, salary_payment_id, source_type, source_id, amount)
      VALUES (_company, _pay, 'advance', _ra.id, _take);
      _left := round(_left - _take, 2);
    END LOOP;

    UPDATE public.staff_bonuses SET is_settled = true, payroll_id = _pay
     WHERE company_id = _company AND staff_id = _l.user_id AND NOT is_settled AND payroll_id IS NULL
       AND bonus_date <= _period_end;
    _count := _count + 1;
  END LOOP;

  IF _count = 0 THEN RAISE EXCEPTION 'payroll already generated for this period'; END IF;
  PERFORM public.log_audit('payroll.run', 'payroll', NULL, NULL, NULL,
    jsonb_build_object('period_start', _period_start, 'period_end', _period_end, 'count', _count), NULL, NULL);
  RETURN _count;
END $$;
REVOKE ALL ON FUNCTION public.run_payroll(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.run_payroll(date, date) TO authenticated;

-- Advances can't be cancelled once any part was recovered.
CREATE OR REPLACE FUNCTION public.cancel_advance(_advance_id uuid, _reason text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_row public.employee_advances;
BEGIN
  IF NOT (public.has_permission('payroll.manage') OR public.is_super_admin()) THEN RAISE EXCEPTION 'not authorized'; END IF;
  SELECT * INTO v_row FROM public.employee_advances
   WHERE id = _advance_id AND company_id = public.current_company_id() FOR UPDATE;
  IF v_row.id IS NULL THEN RAISE EXCEPTION 'advance not found'; END IF;
  IF v_row.status <> 'active' THEN RAISE EXCEPTION 'advance already settled or cancelled'; END IF;
  IF COALESCE(v_row.deducted_amount, 0) > 0 THEN RAISE EXCEPTION 'advance already deducted from payroll'; END IF;
  UPDATE public.employee_advances SET status = 'cancelled', updated_at = now() WHERE id = _advance_id;
  PERFORM public.log_audit('payroll.advance_cancel', 'payroll', 'employee_advances', _advance_id, to_jsonb(v_row), NULL, _reason);
  RETURN _advance_id;
END $$;

-- Forgive the remaining part of a penalty (instead of silently flagging it settled).
CREATE OR REPLACE FUNCTION public.waive_staff_penalty(_penalty_id uuid, _reason text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _p public.staff_penalties;
BEGIN
  IF NOT (public.has_permission('payroll.manage') OR public.is_super_admin()) THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF char_length(btrim(COALESCE(_reason, ''))) < 3 THEN RAISE EXCEPTION 'A reason is required'; END IF;
  SELECT * INTO _p FROM public.staff_penalties WHERE id = _penalty_id AND company_id = public.current_company_id() FOR UPDATE;
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Penalty not found'; END IF;
  IF _p.is_settled THEN RAISE EXCEPTION 'Penalty is already settled'; END IF;
  UPDATE public.staff_penalties SET is_settled = true WHERE id = _p.id;
  PERFORM public.log_audit('payroll.penalty_waive', 'payroll', 'staff_penalties', _p.id, to_jsonb(_p),
    jsonb_build_object('waived', public.penalty_outstanding(_p)), btrim(_reason), NULL);
  RETURN _p.id;
END $$;

REVOKE ALL ON FUNCTION public.cancel_advance(uuid, text), public.waive_staff_penalty(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_advance(uuid, text), public.waive_staff_penalty(uuid, text) TO authenticated;

-- Staff may no longer write penalties directly; RPCs above and hr_add_penalty do it with an audit trail.
REVOKE INSERT, UPDATE, DELETE ON public.staff_penalties FROM authenticated;

-- ---------------------------------------------------------------------
-- Staff advances: scheduled deduction month + Super Admin editing.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.create_advance(uuid, numeric, date, text);
CREATE OR REPLACE FUNCTION public.create_advance(_user_id uuid, _amount numeric, _advance_date date DEFAULT NULL,
  _reason text DEFAULT NULL, _deduct_month date DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_company uuid := public.current_company_id(); v_actor uuid := public.current_profile_id(); v_id uuid;
  v_day date; v_from date;
BEGIN
  IF NOT (public.has_permission('payroll.manage') OR public.is_super_admin()) THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF _amount IS NULL OR _amount <= 0 THEN RAISE EXCEPTION 'amount must be greater than zero'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE id = _user_id AND company_id = v_company) THEN
    RAISE EXCEPTION 'employee not found';
  END IF;
  v_day := COALESCE(_advance_date, public.business_today(v_company));
  -- Deduction starts with the chosen payroll month (never before the advance month).
  v_from := GREATEST(date_trunc('month', COALESCE(_deduct_month, v_day))::date, date_trunc('month', v_day)::date);
  INSERT INTO public.employee_advances (company_id, user_id, amount, advance_date, deduct_from, reason, created_by)
  VALUES (v_company, _user_id, round(_amount, 2), v_day, v_from, NULLIF(btrim(COALESCE(_reason, '')), ''), v_actor)
  RETURNING id INTO v_id;
  PERFORM public.log_audit('payroll.advance_create', 'payroll', 'employee_advances', v_id, NULL,
    jsonb_build_object('user_id', _user_id, 'amount', round(_amount, 2), 'deduct_from', v_from), _reason, NULL);
  RETURN v_id;
END $$;

-- Super Admin edits an advance that isn't fully recovered yet.
CREATE OR REPLACE FUNCTION public.update_employee_advance(_advance_id uuid, _amount numeric, _deduct_month date,
  _reason text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_row public.employee_advances; v_from date;
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only the Super Admin can edit an advance'; END IF;
  SELECT * INTO v_row FROM public.employee_advances
   WHERE id = _advance_id AND company_id = public.current_company_id() FOR UPDATE;
  IF v_row.id IS NULL THEN RAISE EXCEPTION 'advance not found'; END IF;
  IF v_row.status <> 'active' THEN RAISE EXCEPTION 'advance already settled or cancelled'; END IF;
  IF v_row.deducted_amount >= v_row.amount THEN RAISE EXCEPTION 'This advance was already fully deducted in payroll'; END IF;
  IF _amount IS NULL OR _amount <= 0 THEN RAISE EXCEPTION 'amount must be greater than zero'; END IF;
  IF round(_amount, 2) < v_row.deducted_amount THEN
    RAISE EXCEPTION 'Amount cannot be less than what was already deducted (%)', v_row.deducted_amount;
  END IF;
  v_from := GREATEST(date_trunc('month', COALESCE(_deduct_month, v_row.deduct_from, v_row.advance_date))::date,
                     date_trunc('month', v_row.advance_date)::date);
  UPDATE public.employee_advances
     SET amount = round(_amount, 2), deduct_from = v_from,
         reason = COALESCE(NULLIF(btrim(COALESCE(_reason, '')), ''), reason),
         settled_payment_id = CASE WHEN round(_amount, 2) <= deducted_amount THEN settled_payment_id ELSE NULL END,
         settled_at = CASE WHEN round(_amount, 2) <= deducted_amount THEN settled_at ELSE NULL END,
         updated_at = now()
   WHERE id = v_row.id;
  PERFORM public.log_audit('payroll.advance_update', 'payroll', 'employee_advances', v_row.id,
    jsonb_build_object('amount', v_row.amount, 'deduct_from', v_row.deduct_from, 'reason', v_row.reason),
    jsonb_build_object('amount', round(_amount, 2), 'deduct_from', v_from, 'reason', _reason), _reason, NULL);
  RETURN v_row.id;
END $$;

REVOKE ALL ON FUNCTION public.create_advance(uuid, numeric, date, text, date), public.update_employee_advance(uuid, numeric, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_advance(uuid, numeric, date, text, date), public.update_employee_advance(uuid, numeric, date, text) TO authenticated;
