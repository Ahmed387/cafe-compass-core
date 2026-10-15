-- =====================================================================
-- Payroll without the "run payroll" step (client request).
--
-- Before: penalties and advances were only recovered when someone pressed
-- "إصدار رواتب الشهر" (run_payroll) for the whole team, and the salary was
-- then paid separately. Skipping that button meant advances were never
-- deducted ("السلف معمولة بس مش مطبقة").
--
-- Now: each employee's salary is issued AND paid in one action, on the date
-- the manager picks. The same _payroll_lines() math is used, so the preview
-- row is exactly what gets paid. run_payroll stays for compatibility only.
-- =====================================================================

-- Issue one employee's salary line for a month (no payment yet). Recovers
-- penalties then advances, oldest first, only up to what was deducted.
CREATE OR REPLACE FUNCTION public._issue_salary_line(_company uuid, _actor uuid, _user_id uuid,
  _period_start date, _period_end date)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _l record; _pay uuid; _left numeric; _take numeric;
  _rp public.staff_penalties; _ra public.employee_advances;
BEGIN
  SELECT * INTO _l FROM public._payroll_lines(_company, _period_start, _period_end) x WHERE x.user_id = _user_id;
  IF _l.user_id IS NULL THEN RAISE EXCEPTION 'الموظف ده مش في كشف رواتب الشهر'; END IF;
  IF _l.already_generated THEN RAISE EXCEPTION 'مرتب الموظف ده للشهر ده اتصرف قبل كده'; END IF;
  IF _l.prorated_salary <= 0 THEN RAISE EXCEPTION 'الموظف ده ملوش مرتب أساسي محدد'; END IF;

  INSERT INTO public.salary_payments (company_id, user_id, period_start, period_end, base_amount, bonus, deduction,
    absence_deduction, penalty_deduction, advance_deduction, created_by, salary_kind)
  VALUES (_company, _user_id, _period_start, _period_end, _l.prorated_salary, _l.bonuses,
    round(_l.absence_deduction + _l.penalties + _l.advances, 2),
    _l.absence_deduction, _l.penalties, _l.advances, _actor, 'regular')
  RETURNING id INTO _pay;

  _left := _l.penalties;
  FOR _rp IN SELECT sp.* FROM public.staff_penalties sp
             WHERE sp.company_id = _company AND sp.staff_id = _user_id
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

  _left := _l.advances;
  FOR _ra IN SELECT ea.* FROM public.employee_advances ea
             WHERE ea.company_id = _company AND ea.user_id = _user_id
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
   WHERE company_id = _company AND staff_id = _user_id AND NOT is_settled AND payroll_id IS NULL
     AND bonus_date <= _period_end;
  RETURN _pay;
END $$;
REVOKE ALL ON FUNCTION public._issue_salary_line(uuid, uuid, uuid, date, date) FROM PUBLIC, anon, authenticated;

-- One click: issue + pay on the chosen date from the chosen money method.
CREATE OR REPLACE FUNCTION public.pay_employee_salary(_user_id uuid, _period_start date, _period_end date,
  _pay_date date DEFAULT NULL, _method text DEFAULT 'cash')
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _company uuid := public.current_company_id(); _actor uuid := public.current_profile_id();
  _pay uuid; _s public.salary_payments; _acc uuid; _day date;
BEGIN
  IF _actor IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('payroll.manage') OR public.is_super_admin()) THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF _period_start IS NULL OR _period_end IS NULL OR _period_end < _period_start THEN RAISE EXCEPTION 'invalid payroll period'; END IF;
  _day := COALESCE(_pay_date, public.business_today(_company));
  PERFORM pg_advisory_xact_lock(hashtext('payroll:' || _company::text));

  _pay := public._issue_salary_line(_company, _actor, _user_id, _period_start, _period_end);
  SELECT * INTO _s FROM public.salary_payments WHERE id = _pay;

  UPDATE public.salary_payments SET paid_at = (_day::timestamp + time '12:00') AT TIME ZONE 'Africa/Cairo',
    paid_by = _actor, updated_at = now() WHERE id = _pay;

  IF COALESCE(_s.net_amount, 0) > 0 THEN
    _acc := public.default_cash_account(_company, COALESCE(NULLIF(_method, ''), 'cash'));
    IF _acc IS NULL THEN RAISE EXCEPTION 'مفيش خزنة/حساب لطريقة الدفع دي'; END IF;
    PERFORM public.post_cash_txn(_company, _acc, 'out', _s.net_amount, 'salary', COALESCE(NULLIF(_method, ''), 'cash'),
      _day, 'salary_payment', _pay, 'صرف مرتب');
  END IF;

  PERFORM public.log_audit('payroll.pay_employee', 'payroll', 'salary_payments', _pay, NULL,
    jsonb_build_object('user_id', _user_id, 'net', _s.net_amount, 'pay_date', _day, 'method', _method,
                       'period_start', _period_start, 'period_end', _period_end), NULL, NULL);
  RETURN _pay;
END $$;
REVOKE ALL ON FUNCTION public.pay_employee_salary(uuid, date, date, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pay_employee_salary(uuid, date, date, date, text) TO authenticated;
