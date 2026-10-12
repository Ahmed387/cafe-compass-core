CREATE OR REPLACE FUNCTION public.run_payroll(_period_start date, _period_end date)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company uuid := public.current_company_id();
  v_actor uuid := public.current_profile_id();
  v_count integer := 0;
  v_active integer := 0;
  r record;
  v_advances numeric;
  v_payment uuid;
BEGIN
  IF NOT public.has_permission('payroll.manage') THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF _period_start IS NULL OR _period_end IS NULL OR _period_end < _period_start THEN
    RAISE EXCEPTION 'invalid payroll period';
  END IF;

  SELECT count(*) INTO v_active
  FROM public.employee_salaries s
  WHERE s.company_id = v_company AND s.is_active;

  IF v_active = 0 THEN
    RAISE EXCEPTION 'No active employee salaries are defined. Add salaries first.';
  END IF;

  FOR r IN
    SELECT s.user_id, s.base_salary
    FROM public.employee_salaries s
    WHERE s.company_id = v_company
      AND s.is_active
      AND NOT EXISTS (
        SELECT 1 FROM public.salary_payments p
        WHERE p.user_id = s.user_id
          AND p.period_start = _period_start
          AND p.status = 'active'
      )
  LOOP
    SELECT COALESCE(sum(a.amount), 0) INTO v_advances
    FROM public.employee_advances a
    WHERE a.user_id = r.user_id
      AND a.status = 'active'
      AND a.settled_payment_id IS NULL
      AND a.advance_date <= _period_end;

    v_advances := LEAST(v_advances, r.base_salary);

    INSERT INTO public.salary_payments (
      company_id, user_id, period_start, period_end, base_amount, bonus, deduction, created_by
    ) VALUES (
      v_company, r.user_id, _period_start, _period_end, r.base_salary, 0, round(v_advances, 2), v_actor
    ) RETURNING id INTO v_payment;

    IF v_advances > 0 THEN
      UPDATE public.employee_advances
      SET settled_payment_id = v_payment, settled_at = now()
      WHERE user_id = r.user_id
        AND status = 'active'
        AND settled_payment_id IS NULL
        AND advance_date <= _period_end;
    END IF;

    v_count := v_count + 1;
  END LOOP;

  IF v_count = 0 THEN RAISE EXCEPTION 'payroll already generated for this period'; END IF;

  PERFORM public.log_audit('payroll.run', 'payroll', NULL, NULL, NULL,
    jsonb_build_object('period_start', _period_start, 'count', v_count));
  RETURN v_count;
END;
$$;