-- =====================================================================
-- pay_employee_salary: also pays a salary line that was already issued by the
-- old "run payroll" step but never paid (12 such lines exist for October).
--   * issued + unpaid → pay that exact line (its own numbers, deductions kept)
--   * issued + paid   → refuse ("already paid")
--   * nothing issued  → issue (recover penalties/advances) then pay
-- =====================================================================
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

  -- Any line for this month already paid → never pay twice.
  IF EXISTS (SELECT 1 FROM public.salary_payments sp
              WHERE sp.company_id = _company AND sp.user_id = _user_id AND sp.status = 'active'
                AND sp.salary_kind = 'regular' AND sp.paid_at IS NOT NULL
                AND sp.period_start <= _period_end AND sp.period_end >= _period_start) THEN
    RAISE EXCEPTION 'مرتب الموظف ده للشهر ده اتصرف قبل كده';
  END IF;

  -- An unpaid line already issued for this month (closest start date first).
  SELECT * INTO _s FROM public.salary_payments sp
   WHERE sp.company_id = _company AND sp.user_id = _user_id AND sp.status = 'active' AND sp.salary_kind = 'regular'
     AND sp.paid_at IS NULL AND sp.period_start <= _period_end AND sp.period_end >= _period_start
   ORDER BY abs(sp.period_start - _period_start), sp.created_at
   LIMIT 1 FOR UPDATE;

  IF _s.id IS NOT NULL THEN
    _pay := _s.id;
  ELSE
    _pay := public._issue_salary_line(_company, _actor, _user_id, _period_start, _period_end);
    SELECT * INTO _s FROM public.salary_payments WHERE id = _pay;
  END IF;

  UPDATE public.salary_payments SET paid_at = public.business_day_start(_day, _company) + interval '12 hours',
    paid_by = _actor, updated_at = now() WHERE id = _pay;

  IF COALESCE(_s.net_amount, 0) > 0 THEN
    _acc := public.default_cash_account(_company, COALESCE(NULLIF(_method, ''), 'cash'));
    IF _acc IS NULL THEN RAISE EXCEPTION 'مفيش خزنة/حساب لطريقة الدفع دي'; END IF;
    PERFORM public.post_cash_txn(_company, _acc, 'out', _s.net_amount, 'salary', COALESCE(NULLIF(_method, ''), 'cash'),
      _day, 'salary_payment', _pay, 'صرف مرتب');
  END IF;

  PERFORM public.log_audit('payroll.pay_employee', 'payroll', 'salary_payments', _pay, NULL,
    jsonb_build_object('user_id', _user_id, 'net', _s.net_amount, 'pay_date', _day, 'method', _method,
                       'period_start', _s.period_start, 'period_end', _s.period_end), NULL, NULL);
  RETURN _pay;
END $$;
REVOKE ALL ON FUNCTION public.pay_employee_salary(uuid, date, date, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pay_employee_salary(uuid, date, date, date, text) TO authenticated, service_role;
