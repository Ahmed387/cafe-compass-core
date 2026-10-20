-- =====================================================================
-- Owner rule (2026-10-20): the pay date of a salary is picked by hand when it
-- is paid from Finance or from the partners screen. It defaults to today and
-- is what the treasury and the reports use. Before this, pay_salary always
-- recorded "now".
-- pay_salary gains _paid_on (date, optional). Calls without it behave as before.
-- A future date is refused. No data is changed.
-- =====================================================================
DROP FUNCTION IF EXISTS public.pay_salary(uuid, uuid, text);

CREATE OR REPLACE FUNCTION public.pay_salary(_salary_id uuid, _account_id uuid DEFAULT NULL::uuid,
  _method text DEFAULT 'cash'::text, _paid_on date DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE _profile uuid := public.current_profile_id(); _s public.salary_payments; _acc uuid;
  _today date := public.business_date(now(), public.current_company_id());
  _day date;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('payroll.manage') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  SELECT * INTO _s FROM public.salary_payments WHERE id = _salary_id AND company_id = public.current_company_id();
  IF _s.id IS NULL THEN RAISE EXCEPTION 'Salary record not found'; END IF;
  IF _s.status <> 'active' THEN RAISE EXCEPTION 'This salary record is not active'; END IF;
  IF _s.paid_at IS NOT NULL THEN RAISE EXCEPTION 'This salary is already paid'; END IF;

  _day := COALESCE(_paid_on, _today);
  IF _day > _today THEN RAISE EXCEPTION 'تاريخ الصرف مينفعش يكون بعد النهارده'; END IF;

  _acc := COALESCE(_account_id, public.default_cash_account(_s.company_id, _method));
  IF _acc IS NULL THEN RAISE EXCEPTION 'No cash account available'; END IF;

  -- Noon of the chosen day in the cafe's time zone, so the timestamp never slips a day.
  UPDATE public.salary_payments
     SET paid_at = CASE WHEN _day = _today THEN now()
                        ELSE ((_day + time '12:00') AT TIME ZONE public.company_tz(_s.company_id)) END,
         paid_by = _profile, updated_at = now()
   WHERE id = _salary_id;

  PERFORM public.post_cash_txn(_s.company_id, _acc, 'out', _s.net_amount, 'salary', _method, _day,
    'salary_payment', _salary_id, 'Salary payment', NULL, _method <> 'bank');

  PERFORM public.log_audit('payroll.pay','finance','salary_payments',_salary_id, NULL,
    jsonb_build_object('amount',_s.net_amount,'method',_method,'paid_on',_day), NULL, NULL);
  RETURN _salary_id;
END $$;
REVOKE EXECUTE ON FUNCTION public.pay_salary(uuid, uuid, text, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pay_salary(uuid, uuid, text, date) TO authenticated, service_role;
