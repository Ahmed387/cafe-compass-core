ALTER TABLE public.attendance
  ADD COLUMN permission_hours numeric(5,2);

ALTER TABLE public.attendance
  DROP CONSTRAINT attendance_status_chk;
ALTER TABLE public.attendance
  ADD CONSTRAINT attendance_status_chk CHECK (status IN ('present','absent','leave','half_day','permission'));
ALTER TABLE public.attendance
  ADD CONSTRAINT attendance_permission_hours_chk CHECK (
    (status = 'permission' AND permission_hours > 0 AND permission_hours <= 8)
    OR (status <> 'permission' AND permission_hours IS NULL)
  );

DROP FUNCTION public.upsert_attendance(uuid,date,text,timestamp with time zone,timestamp with time zone,uuid,text);
CREATE FUNCTION public.upsert_attendance(
  _user_id uuid,
  _work_date date,
  _status text DEFAULT 'present',
  _check_in timestamptz DEFAULT NULL,
  _check_out timestamptz DEFAULT NULL,
  _branch_id uuid DEFAULT NULL,
  _notes text DEFAULT NULL,
  _permission_hours numeric DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_company uuid := public.current_company_id();
  v_actor uuid := public.current_profile_id();
  v_minutes integer := 0;
  v_status text := lower(COALESCE(NULLIF(btrim(_status), ''), 'present'));
  v_permission_hours numeric := CASE WHEN lower(COALESCE(_status,'')) = 'permission' THEN round(COALESCE(_permission_hours,0),2) ELSE NULL END;
  v_id uuid;
BEGIN
  IF NOT public.has_permission('attendance.manage') THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF v_status NOT IN ('present','absent','leave','half_day','permission') THEN RAISE EXCEPTION 'invalid attendance status'; END IF;
  IF v_status = 'permission' AND (v_permission_hours <= 0 OR v_permission_hours > 8) THEN RAISE EXCEPTION 'permission hours must be between 0 and 8'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE id = _user_id AND company_id = v_company) THEN RAISE EXCEPTION 'employee not found'; END IF;
  IF v_status NOT IN ('present','half_day','permission') THEN _check_in := NULL; _check_out := NULL; END IF;
  IF _check_in IS NOT NULL AND _check_out IS NOT NULL THEN
    IF _check_out < _check_in THEN RAISE EXCEPTION 'check-out is before check-in'; END IF;
    v_minutes := GREATEST(0, (EXTRACT(EPOCH FROM (_check_out - _check_in)) / 60)::int);
  END IF;

  INSERT INTO public.attendance (company_id, branch_id, user_id, work_date, status, check_in, check_out, minutes_worked, notes, created_by, permission_hours)
  VALUES (v_company, _branch_id, _user_id, COALESCE(_work_date, current_date), v_status, _check_in, _check_out, v_minutes, NULLIF(btrim(COALESCE(_notes,'')),''), v_actor, v_permission_hours)
  ON CONFLICT (user_id, work_date) DO UPDATE
    SET status = EXCLUDED.status, check_in = EXCLUDED.check_in, check_out = EXCLUDED.check_out,
        minutes_worked = EXCLUDED.minutes_worked, branch_id = COALESCE(EXCLUDED.branch_id, public.attendance.branch_id),
        notes = EXCLUDED.notes, permission_hours = EXCLUDED.permission_hours, updated_at = now()
  RETURNING id INTO v_id;

  PERFORM public.log_audit('attendance.upsert', 'attendance', 'attendance', v_id, NULL,
    jsonb_build_object('user_id', _user_id, 'work_date', _work_date, 'status', v_status, 'minutes', v_minutes, 'permission_hours', v_permission_hours), NULL, _branch_id);
  RETURN v_id;
END;
$function$;
REVOKE ALL ON FUNCTION public.upsert_attendance(uuid,date,text,timestamptz,timestamptz,uuid,text,numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.upsert_attendance(uuid,date,text,timestamptz,timestamptz,uuid,text,numeric) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.attendance_deduction_days(_user_id uuid, _company_id uuid, _start date, _end date)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT COALESCE(sum(CASE
    WHEN status = 'absent' THEN 1
    WHEN status = 'half_day' THEN 0.5
    WHEN status = 'permission' THEN permission_hours / 8.0
    ELSE 0
  END), 0)
  FROM public.attendance
  WHERE user_id = _user_id AND company_id = _company_id AND work_date BETWEEN _start AND _end;
$function$;
REVOKE ALL ON FUNCTION public.attendance_deduction_days(uuid,uuid,date,date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.attendance_deduction_days(uuid,uuid,date,date) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.hr_payroll_preview(_period_start date, _period_end date)
RETURNS TABLE(user_id uuid, employee_name text, job_title text, hire_date date, base_salary numeric, prorated_salary numeric, worked_days integer, worked_hours numeric, shifts_count integer, absent_days integer, absence_deduction numeric, penalties numeric, bonuses numeric, advances numeric, net_pay numeric, already_generated boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_company uuid := public.current_company_id();
BEGIN
  IF NOT (public.has_permission('payroll.view') OR public.is_super_admin()) THEN RAISE EXCEPTION 'not authorized'; END IF;
  RETURN QUERY
  WITH base AS (
    SELECT p.id AS uid, COALESCE(s.base_salary,0) AS bs, p.hire_date AS hd, p.job_title AS jt,
      COALESCE(NULLIF(p.display_name,''), NULLIF(trim(COALESCE(p.first_name,'')||' '||COALESCE(p.last_name,'')),''), p.email) AS nm
    FROM public.user_profiles p
    LEFT JOIN LATERAL (SELECT es.base_salary FROM public.employee_salaries es WHERE es.user_id=p.id AND es.company_id=v_company AND es.is_active ORDER BY es.effective_from DESC NULLS LAST LIMIT 1) s ON true
    WHERE p.company_id = v_company AND p.is_active AND NOT EXISTS (SELECT 1 FROM public.partners pt WHERE pt.company_id=v_company AND pt.user_id=p.id AND pt.status<>'exited' AND NOT pt.is_managing_staff) AND (p.is_managing_staff OR NOT EXISTS (SELECT 1 FROM public.user_roles ur JOIN public.roles r ON r.id=ur.role_id WHERE ur.user_id=p.id AND r.key='super_admin'))
  ), calc AS (
    SELECT b.*, public._prorated_salary(b.bs, b.hd, _period_start, _period_end) AS pr,
      (SELECT count(DISTINCT a.work_date)::int FROM public.attendance a WHERE a.user_id=b.uid AND a.company_id=v_company AND a.work_date BETWEEN _period_start AND _period_end AND a.status IN ('present','half_day','permission')) AS wd,
      (SELECT round(COALESCE(sum(a.minutes_worked),0)/60.0, 2) FROM public.attendance a WHERE a.user_id=b.uid AND a.company_id=v_company AND a.work_date BETWEEN _period_start AND _period_end) AS wh,
      (SELECT count(*)::int FROM public.shifts sh WHERE sh.user_id=b.uid AND sh.opened_at::date BETWEEN _period_start AND _period_end) AS sc,
      (SELECT count(*)::int FROM public.attendance a WHERE a.user_id=b.uid AND a.company_id=v_company AND a.status='absent' AND a.work_date BETWEEN _period_start AND _period_end) AS ad,
      public.attendance_deduction_days(b.uid,v_company,_period_start,_period_end) AS dd,
      (SELECT COALESCE(sum(sp.amount),0) FROM public.staff_penalties sp WHERE sp.company_id=v_company AND sp.staff_id=b.uid AND NOT sp.is_settled AND sp.payroll_id IS NULL AND sp.created_at::date BETWEEN _period_start AND _period_end) AS pen,
      (SELECT COALESCE(sum(sb.amount),0) FROM public.staff_bonuses sb WHERE sb.company_id=v_company AND sb.staff_id=b.uid AND NOT sb.is_settled AND sb.payroll_id IS NULL AND sb.bonus_date BETWEEN _period_start AND _period_end) AS bon,
      (SELECT COALESCE(sum(ea.amount),0) FROM public.employee_advances ea WHERE ea.user_id=b.uid AND ea.status='active' AND ea.settled_payment_id IS NULL AND ea.advance_date <= _period_end) AS adv,
      EXISTS (SELECT 1 FROM public.salary_payments sp2 WHERE sp2.user_id=b.uid AND sp2.period_start=_period_start AND sp2.status='active') AS gen
    FROM base b
  )
  SELECT c.uid, c.nm, c.jt, c.hd, c.bs, c.pr, c.wd, c.wh, c.sc, c.ad,
    round(c.bs/30.0*c.dd, 2), c.pen, c.bon, c.adv,
    GREATEST(round(c.pr + c.bon - LEAST(c.adv + round(c.bs/30.0*c.dd,2) + c.pen, c.pr), 2), 0), c.gen
  FROM calc c ORDER BY c.nm;
END;
$function$;

CREATE OR REPLACE FUNCTION public.run_payroll(_period_start date, _period_end date)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_company uuid := public.current_company_id(); v_actor uuid := public.current_profile_id();
  v_count integer := 0; v_active integer := 0; r record;
  v_advances numeric; v_deduction_days numeric; v_absence numeric; v_penalties numeric; v_bonuses numeric;
  v_base numeric; v_deduction numeric; v_payment uuid;
BEGIN
  IF NOT public.has_permission('payroll.manage') THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF _period_start IS NULL OR _period_end IS NULL OR _period_end < _period_start THEN RAISE EXCEPTION 'invalid payroll period'; END IF;
  SELECT count(*) INTO v_active FROM public.employee_salaries s WHERE s.company_id = v_company AND s.is_active;
  IF v_active = 0 THEN RAISE EXCEPTION 'No active employee salaries are defined. Add salaries first.'; END IF;
  FOR r IN SELECT s.user_id, s.base_salary, p.hire_date FROM public.employee_salaries s JOIN public.user_profiles p ON p.id=s.user_id
    WHERE s.company_id=v_company AND s.is_active AND NOT EXISTS (SELECT 1 FROM public.salary_payments sp WHERE sp.user_id=s.user_id AND sp.period_start=_period_start AND sp.status='active')
  LOOP
    v_base := public._prorated_salary(r.base_salary,r.hire_date,_period_start,_period_end); IF v_base <= 0 THEN CONTINUE; END IF;
    SELECT COALESCE(sum(a.amount),0) INTO v_advances FROM public.employee_advances a WHERE a.user_id=r.user_id AND a.status='active' AND a.settled_payment_id IS NULL AND a.advance_date<=_period_end;
    v_deduction_days := public.attendance_deduction_days(r.user_id,v_company,_period_start,_period_end);
    SELECT COALESCE(sum(sp.amount),0) INTO v_penalties FROM public.staff_penalties sp WHERE sp.company_id=v_company AND sp.staff_id=r.user_id AND NOT sp.is_settled AND sp.payroll_id IS NULL AND sp.created_at::date BETWEEN _period_start AND _period_end;
    SELECT COALESCE(sum(sb.amount),0) INTO v_bonuses FROM public.staff_bonuses sb WHERE sb.company_id=v_company AND sb.staff_id=r.user_id AND NOT sb.is_settled AND sb.payroll_id IS NULL AND sb.bonus_date BETWEEN _period_start AND _period_end;
    v_absence := round(COALESCE(r.base_salary,0)/30.0*v_deduction_days,2); v_advances := LEAST(v_advances,v_base); v_deduction := round(LEAST(v_advances+v_absence+v_penalties,v_base),2);
    INSERT INTO public.salary_payments(company_id,user_id,period_start,period_end,base_amount,bonus,deduction,created_by) VALUES(v_company,r.user_id,_period_start,_period_end,v_base,round(v_bonuses,2),v_deduction,v_actor) RETURNING id INTO v_payment;
    IF v_advances>0 THEN UPDATE public.employee_advances SET settled_payment_id=v_payment,settled_at=now() WHERE user_id=r.user_id AND status='active' AND settled_payment_id IS NULL AND advance_date<=_period_end; END IF;
    IF v_penalties>0 THEN UPDATE public.staff_penalties SET is_settled=true,payroll_id=v_payment WHERE company_id=v_company AND staff_id=r.user_id AND NOT is_settled AND payroll_id IS NULL AND created_at::date BETWEEN _period_start AND _period_end; END IF;
    IF v_bonuses>0 THEN UPDATE public.staff_bonuses SET is_settled=true,payroll_id=v_payment WHERE company_id=v_company AND staff_id=r.user_id AND NOT is_settled AND payroll_id IS NULL AND bonus_date BETWEEN _period_start AND _period_end; END IF;
    v_count := v_count+1;
  END LOOP;
  IF v_count=0 THEN RAISE EXCEPTION 'payroll already generated for this period'; END IF;
  PERFORM public.log_audit('payroll.run','payroll',NULL,NULL,NULL,jsonb_build_object('period_start',_period_start,'count',v_count)); RETURN v_count;
END;
$function$;