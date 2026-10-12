-- 1) POS orders are closed immediately: no kitchen handover step
ALTER TABLE public.orders ALTER COLUMN kitchen_status SET DEFAULT 'served'::kitchen_status;

-- 2) Purge unused operational roles (kitchen / stock / accountant)
DELETE FROM public.role_permissions
WHERE role_id IN (SELECT id FROM public.roles WHERE key IN ('kitchen_staff','inventory_staff','accountant'));
DELETE FROM public.user_roles
WHERE role_id IN (SELECT id FROM public.roles WHERE key IN ('kitchen_staff','inventory_staff','accountant'));
DELETE FROM public.roles WHERE key IN ('kitchen_staff','inventory_staff','accountant');

-- 3) Daily attendance status (manager checklist)
ALTER TABLE public.attendance
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'present';
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'attendance_status_chk') THEN
    ALTER TABLE public.attendance
      ADD CONSTRAINT attendance_status_chk CHECK (status IN ('present','absent','leave'));
  END IF;
END $$;

DROP FUNCTION IF EXISTS public.upsert_attendance(uuid, date, timestamptz, timestamptz, uuid, text);

CREATE OR REPLACE FUNCTION public.upsert_attendance(
  _user_id uuid,
  _work_date date,
  _status text DEFAULT 'present',
  _check_in timestamptz DEFAULT NULL,
  _check_out timestamptz DEFAULT NULL,
  _branch_id uuid DEFAULT NULL,
  _notes text DEFAULT NULL
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
  v_id uuid;
BEGIN
  IF NOT public.has_permission('attendance.manage') THEN
    RAISE EXCEPTION 'not authorized';
  END IF;
  IF v_status NOT IN ('present','absent','leave') THEN
    RAISE EXCEPTION 'invalid attendance status';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE id = _user_id AND company_id = v_company) THEN
    RAISE EXCEPTION 'employee not found';
  END IF;
  IF v_status <> 'present' THEN
    _check_in := NULL;
    _check_out := NULL;
  END IF;
  IF _check_in IS NOT NULL AND _check_out IS NOT NULL THEN
    IF _check_out < _check_in THEN RAISE EXCEPTION 'check-out is before check-in'; END IF;
    v_minutes := GREATEST(0, (EXTRACT(EPOCH FROM (_check_out - _check_in)) / 60)::int);
  END IF;

  INSERT INTO public.attendance (company_id, branch_id, user_id, work_date, status, check_in, check_out, minutes_worked, notes, created_by)
  VALUES (v_company, _branch_id, _user_id, COALESCE(_work_date, current_date), v_status, _check_in, _check_out, v_minutes, _notes, v_actor)
  ON CONFLICT (user_id, work_date) DO UPDATE
    SET status = EXCLUDED.status,
        check_in = EXCLUDED.check_in,
        check_out = EXCLUDED.check_out,
        minutes_worked = EXCLUDED.minutes_worked,
        branch_id = COALESCE(EXCLUDED.branch_id, public.attendance.branch_id),
        notes = EXCLUDED.notes
  RETURNING id INTO v_id;

  PERFORM public.log_audit('attendance.upsert', 'attendance', 'attendance', v_id,
    NULL, jsonb_build_object('user_id', _user_id, 'work_date', _work_date, 'status', v_status, 'minutes', v_minutes), NULL, _branch_id);
  RETURN v_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.upsert_attendance(uuid, date, text, timestamptz, timestamptz, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.upsert_attendance(uuid, date, text, timestamptz, timestamptz, uuid, text) TO authenticated, service_role;

-- 4) Payroll: deduct unexcused absences alongside advances
CREATE OR REPLACE FUNCTION public.run_payroll(_period_start date, _period_end date)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_company uuid := public.current_company_id();
  v_actor uuid := public.current_profile_id();
  v_count integer := 0;
  v_active integer := 0;
  r record;
  v_advances numeric;
  v_absent integer;
  v_absence numeric;
  v_deduction numeric;
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

    SELECT count(*) INTO v_absent
    FROM public.attendance at
    WHERE at.user_id = r.user_id
      AND at.company_id = v_company
      AND at.status = 'absent'
      AND at.work_date BETWEEN _period_start AND _period_end;

    v_absence := round(COALESCE(r.base_salary, 0) / 30.0 * COALESCE(v_absent, 0), 2);
    v_advances := LEAST(v_advances, r.base_salary);
    v_deduction := round(LEAST(v_advances + v_absence, r.base_salary), 2);

    INSERT INTO public.salary_payments (
      company_id, user_id, period_start, period_end, base_amount, bonus, deduction, created_by
    ) VALUES (
      v_company, r.user_id, _period_start, _period_end, r.base_salary, 0, v_deduction, v_actor
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
$function$;

-- 5) Staff who never sign in are HR-only records: no auth account, no email required
ALTER TABLE public.user_profiles ALTER COLUMN auth_user_id DROP NOT NULL;
ALTER TABLE public.user_profiles ALTER COLUMN email DROP NOT NULL;