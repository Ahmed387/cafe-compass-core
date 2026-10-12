ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS hire_date date;

CREATE TABLE public.staff_bonuses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  staff_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE RESTRICT,
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  reason text NOT NULL,
  bonus_date date NOT NULL DEFAULT CURRENT_DATE,
  is_settled boolean NOT NULL DEFAULT false,
  payroll_id uuid REFERENCES public.salary_payments(id) ON DELETE SET NULL,
  created_by uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.staff_bonuses TO authenticated;
GRANT ALL ON public.staff_bonuses TO service_role;
ALTER TABLE public.staff_bonuses ENABLE ROW LEVEL SECURITY;
CREATE POLICY "staff_bonuses_select" ON public.staff_bonuses FOR SELECT TO authenticated
  USING (company_id = public.current_company_id()
    AND (public.has_permission('payroll.view') OR public.is_super_admin() OR staff_id = public.current_profile_id()));

CREATE OR REPLACE FUNCTION public.add_staff_bonus(_staff_id uuid, _amount numeric, _reason text, _bonus_date date DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_company uuid := public.current_company_id(); v_id uuid;
BEGIN
  IF NOT (public.has_permission('payroll.manage') OR public.is_super_admin()) THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF _amount IS NULL OR _amount <= 0 THEN RAISE EXCEPTION 'invalid amount'; END IF;
  IF length(trim(coalesce(_reason,''))) < 3 THEN RAISE EXCEPTION 'reason required'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE id=_staff_id AND company_id=v_company) THEN RAISE EXCEPTION 'employee not found'; END IF;
  INSERT INTO public.staff_bonuses(company_id, staff_id, amount, reason, bonus_date, created_by)
  VALUES (v_company, _staff_id, round(_amount,2), trim(_reason), COALESCE(_bonus_date, CURRENT_DATE), public.current_profile_id())
  RETURNING id INTO v_id;
  PERFORM public.log_audit('payroll.bonus', 'staff_bonuses', v_id, NULL, NULL, jsonb_build_object('staff_id',_staff_id,'amount',_amount));
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION public.set_employee_hire_date(_user_id uuid, _hire_date date)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT (public.has_permission('payroll.manage') OR public.is_super_admin()) THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF _hire_date IS NOT NULL AND _hire_date > CURRENT_DATE + 365 THEN RAISE EXCEPTION 'invalid hire date'; END IF;
  UPDATE public.user_profiles SET hire_date = _hire_date WHERE id = _user_id AND company_id = public.current_company_id();
  IF NOT FOUND THEN RAISE EXCEPTION 'employee not found'; END IF;
  PERFORM public.log_audit('payroll.hire_date', 'user_profiles', _user_id, NULL, NULL, jsonb_build_object('hire_date',_hire_date));
END $$;

CREATE OR REPLACE FUNCTION public._prorated_salary(_base numeric, _hire date, _start date, _end date)
RETURNS numeric LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT CASE
    WHEN _hire IS NULL OR _hire <= _start THEN round(_base, 2)
    WHEN _hire > _end THEN 0
    ELSE round(_base * ((_end - _hire + 1)::numeric / (_end - _start + 1)), 2)
  END
$$;

CREATE OR REPLACE FUNCTION public.hr_payroll_preview(_period_start date, _period_end date)
RETURNS TABLE(user_id uuid, employee_name text, hire_date date, base_salary numeric, prorated_salary numeric,
  worked_days integer, worked_hours numeric, absent_days integer, absence_deduction numeric,
  penalties numeric, bonuses numeric, advances numeric, net_pay numeric, already_generated boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_company uuid := public.current_company_id();
BEGIN
  IF NOT (public.has_permission('payroll.view') OR public.is_super_admin()) THEN RAISE EXCEPTION 'not authorized'; END IF;
  RETURN QUERY
  WITH base AS (
    SELECT s.user_id AS uid, s.base_salary AS bs, p.hire_date AS hd,
      COALESCE(NULLIF(p.display_name,''), trim(p.first_name||' '||COALESCE(p.last_name,''))) AS nm
    FROM public.employee_salaries s JOIN public.user_profiles p ON p.id = s.user_id
    WHERE s.company_id = v_company AND s.is_active AND p.is_active
  ), calc AS (
    SELECT b.*, public._prorated_salary(b.bs, b.hd, _period_start, _period_end) AS pr,
      (SELECT count(DISTINCT a.work_date)::int FROM public.attendance a WHERE a.user_id=b.uid AND a.company_id=v_company AND a.work_date BETWEEN _period_start AND _period_end AND COALESCE(a.status,'') <> 'absent') AS wd,
      (SELECT round(COALESCE(sum(a.minutes_worked),0)/60.0, 2) FROM public.attendance a WHERE a.user_id=b.uid AND a.company_id=v_company AND a.work_date BETWEEN _period_start AND _period_end) AS wh,
      (SELECT count(*)::int FROM public.attendance a WHERE a.user_id=b.uid AND a.company_id=v_company AND a.status='absent' AND a.work_date BETWEEN _period_start AND _period_end) AS ad,
      (SELECT COALESCE(sum(sp.amount),0) FROM public.staff_penalties sp WHERE sp.company_id=v_company AND sp.staff_id=b.uid AND NOT sp.is_settled AND sp.payroll_id IS NULL AND sp.created_at::date BETWEEN _period_start AND _period_end) AS pen,
      (SELECT COALESCE(sum(sb.amount),0) FROM public.staff_bonuses sb WHERE sb.company_id=v_company AND sb.staff_id=b.uid AND NOT sb.is_settled AND sb.payroll_id IS NULL AND sb.bonus_date BETWEEN _period_start AND _period_end) AS bon,
      (SELECT COALESCE(sum(ea.amount),0) FROM public.employee_advances ea WHERE ea.user_id=b.uid AND ea.status='active' AND ea.settled_payment_id IS NULL AND ea.advance_date <= _period_end) AS adv,
      EXISTS (SELECT 1 FROM public.salary_payments sp2 WHERE sp2.user_id=b.uid AND sp2.period_start=_period_start AND sp2.status='active') AS gen
    FROM base b
  )
  SELECT c.uid, c.nm, c.hd, c.bs, c.pr, c.wd, c.wh, c.ad,
    round(c.bs/30.0*c.ad, 2),
    c.pen, c.bon, c.adv,
    GREATEST(round(c.pr + c.bon - LEAST(c.adv + round(c.bs/30.0*c.ad,2) + c.pen, c.pr), 2), 0),
    c.gen
  FROM calc c ORDER BY c.nm;
END $$;

CREATE OR REPLACE FUNCTION public.run_payroll(_period_start date, _period_end date)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_company uuid := public.current_company_id();
  v_actor uuid := public.current_profile_id();
  v_count integer := 0; v_active integer := 0; r record;
  v_advances numeric; v_absent integer; v_absence numeric; v_penalties numeric; v_bonuses numeric;
  v_base numeric; v_deduction numeric; v_payment uuid;
BEGIN
  IF NOT public.has_permission('payroll.manage') THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF _period_start IS NULL OR _period_end IS NULL OR _period_end < _period_start THEN RAISE EXCEPTION 'invalid payroll period'; END IF;
  SELECT count(*) INTO v_active FROM public.employee_salaries s WHERE s.company_id = v_company AND s.is_active;
  IF v_active = 0 THEN RAISE EXCEPTION 'No active employee salaries are defined. Add salaries first.'; END IF;

  FOR r IN
    SELECT s.user_id, s.base_salary, p.hire_date
    FROM public.employee_salaries s JOIN public.user_profiles p ON p.id = s.user_id
    WHERE s.company_id = v_company AND s.is_active
      AND NOT EXISTS (SELECT 1 FROM public.salary_payments sp WHERE sp.user_id = s.user_id AND sp.period_start = _period_start AND sp.status = 'active')
  LOOP
    v_base := public._prorated_salary(r.base_salary, r.hire_date, _period_start, _period_end);
    IF v_base <= 0 THEN CONTINUE; END IF;

    SELECT COALESCE(sum(a.amount),0) INTO v_advances FROM public.employee_advances a
    WHERE a.user_id = r.user_id AND a.status = 'active' AND a.settled_payment_id IS NULL AND a.advance_date <= _period_end;
    SELECT count(*) INTO v_absent FROM public.attendance at
    WHERE at.user_id = r.user_id AND at.company_id = v_company AND at.status = 'absent' AND at.work_date BETWEEN _period_start AND _period_end;
    SELECT COALESCE(sum(sp.amount),0) INTO v_penalties FROM public.staff_penalties sp
    WHERE sp.company_id = v_company AND sp.staff_id = r.user_id AND sp.is_settled = false AND sp.payroll_id IS NULL AND sp.created_at::date BETWEEN _period_start AND _period_end;
    SELECT COALESCE(sum(sb.amount),0) INTO v_bonuses FROM public.staff_bonuses sb
    WHERE sb.company_id = v_company AND sb.staff_id = r.user_id AND sb.is_settled = false AND sb.payroll_id IS NULL AND sb.bonus_date BETWEEN _period_start AND _period_end;

    v_absence := round(COALESCE(r.base_salary,0) / 30.0 * COALESCE(v_absent,0), 2);
    v_advances := LEAST(v_advances, v_base);
    v_deduction := round(LEAST(v_advances + v_absence + v_penalties, v_base), 2);

    INSERT INTO public.salary_payments (company_id, user_id, period_start, period_end, base_amount, bonus, deduction, created_by)
    VALUES (v_company, r.user_id, _period_start, _period_end, v_base, round(v_bonuses,2), v_deduction, v_actor)
    RETURNING id INTO v_payment;

    IF v_advances > 0 THEN
      UPDATE public.employee_advances SET settled_payment_id = v_payment, settled_at = now()
      WHERE user_id = r.user_id AND status = 'active' AND settled_payment_id IS NULL AND advance_date <= _period_end;
    END IF;
    IF v_penalties > 0 THEN
      UPDATE public.staff_penalties SET is_settled = true, payroll_id = v_payment
      WHERE company_id = v_company AND staff_id = r.user_id AND is_settled = false AND payroll_id IS NULL AND created_at::date BETWEEN _period_start AND _period_end;
    END IF;
    IF v_bonuses > 0 THEN
      UPDATE public.staff_bonuses SET is_settled = true, payroll_id = v_payment
      WHERE company_id = v_company AND staff_id = r.user_id AND is_settled = false AND payroll_id IS NULL AND bonus_date BETWEEN _period_start AND _period_end;
    END IF;
    v_count := v_count + 1;
  END LOOP;

  IF v_count = 0 THEN RAISE EXCEPTION 'payroll already generated for this period'; END IF;
  PERFORM public.log_audit('payroll.run', 'payroll', NULL, NULL, NULL, jsonb_build_object('period_start', _period_start, 'count', v_count));
  RETURN v_count;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.add_staff_bonus(uuid,numeric,text,date) FROM anon, public;
REVOKE EXECUTE ON FUNCTION public.set_employee_hire_date(uuid,date) FROM anon, public;
REVOKE EXECUTE ON FUNCTION public.hr_payroll_preview(date,date) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.add_staff_bonus(uuid,numeric,text,date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_employee_hire_date(uuid,date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.hr_payroll_preview(date,date) TO authenticated;