INSERT INTO public.permissions (key, name, description, module) VALUES
  ('attendance.view', 'View attendance', 'View staff attendance records', 'attendance'),
  ('attendance.manage', 'Manage attendance', 'Create and edit staff attendance records', 'attendance')
ON CONFLICT (key) DO NOTHING;

INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM public.roles r
CROSS JOIN public.permissions p
WHERE r.key IN ('super_admin', 'manager')
  AND p.key IN ('attendance.view', 'attendance.manage')
ON CONFLICT DO NOTHING;

CREATE TABLE public.attendance (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  branch_id uuid REFERENCES public.branches(id) ON DELETE SET NULL,
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  work_date date NOT NULL DEFAULT current_date,
  check_in timestamptz,
  check_out timestamptz,
  minutes_worked integer NOT NULL DEFAULT 0,
  notes text,
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT attendance_unique_day UNIQUE (user_id, work_date),
  CONSTRAINT attendance_minutes_nonneg CHECK (minutes_worked >= 0)
);

GRANT SELECT ON public.attendance TO authenticated;
GRANT ALL ON public.attendance TO service_role;

ALTER TABLE public.attendance ENABLE ROW LEVEL SECURITY;

CREATE POLICY "attendance_select" ON public.attendance
  FOR SELECT TO authenticated
  USING (
    company_id = public.current_company_id()
    AND (
      user_id = public.current_profile_id()
      OR public.has_permission('attendance.view')
      OR public.has_permission('payroll.view')
    )
  );

CREATE TRIGGER t_attendance_updated_at
  BEFORE UPDATE ON public.attendance
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER t_attendance_no_delete
  BEFORE DELETE ON public.attendance
  FOR EACH ROW EXECUTE FUNCTION public.forbid_hard_delete();

CREATE INDEX idx_attendance_company_date ON public.attendance(company_id, work_date DESC);

CREATE TABLE public.employee_advances (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  amount numeric(14,2) NOT NULL,
  advance_date date NOT NULL DEFAULT current_date,
  reason text,
  status record_status NOT NULL DEFAULT 'active',
  settled_payment_id uuid REFERENCES public.salary_payments(id) ON DELETE SET NULL,
  settled_at timestamptz,
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT advances_amount_positive CHECK (amount > 0)
);

GRANT SELECT ON public.employee_advances TO authenticated;
GRANT ALL ON public.employee_advances TO service_role;

ALTER TABLE public.employee_advances ENABLE ROW LEVEL SECURITY;

CREATE POLICY "advances_select" ON public.employee_advances
  FOR SELECT TO authenticated
  USING (
    company_id = public.current_company_id()
    AND (user_id = public.current_profile_id() OR public.has_permission('payroll.view'))
  );

CREATE TRIGGER t_advances_updated_at
  BEFORE UPDATE ON public.employee_advances
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER t_advances_no_delete
  BEFORE DELETE ON public.employee_advances
  FOR EACH ROW EXECUTE FUNCTION public.forbid_hard_delete();

CREATE INDEX idx_advances_user_status ON public.employee_advances(user_id, status);

CREATE OR REPLACE FUNCTION public.clock_in(_branch_id uuid DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile uuid := public.current_profile_id();
  v_company uuid := public.current_company_id();
  v_id uuid;
BEGIN
  IF v_profile IS NULL THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF _branch_id IS NOT NULL AND NOT public.can_access_branch(_branch_id) THEN
    RAISE EXCEPTION 'branch not allowed';
  END IF;

  INSERT INTO public.attendance (company_id, branch_id, user_id, work_date, check_in, created_by)
  VALUES (v_company, _branch_id, v_profile, current_date, now(), v_profile)
  ON CONFLICT (user_id, work_date) DO UPDATE
    SET check_in = COALESCE(public.attendance.check_in, now()),
        branch_id = COALESCE(public.attendance.branch_id, EXCLUDED.branch_id)
  RETURNING id INTO v_id;

  PERFORM public.log_audit('attendance.clock_in', 'attendance', 'attendance', v_id, NULL, NULL, NULL, _branch_id);
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.clock_out()
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile uuid := public.current_profile_id();
  v_row public.attendance;
BEGIN
  IF v_profile IS NULL THEN RAISE EXCEPTION 'not authorized'; END IF;

  SELECT * INTO v_row FROM public.attendance
  WHERE user_id = v_profile AND work_date = current_date;
  IF v_row.id IS NULL OR v_row.check_in IS NULL THEN
    RAISE EXCEPTION 'no open attendance record for today';
  END IF;

  UPDATE public.attendance
  SET check_out = now(),
      minutes_worked = GREATEST(0, (EXTRACT(EPOCH FROM (now() - v_row.check_in)) / 60)::int)
  WHERE id = v_row.id;

  PERFORM public.log_audit('attendance.clock_out', 'attendance', 'attendance', v_row.id);
  RETURN v_row.id;
END;
$$;

CREATE OR REPLACE FUNCTION public.upsert_attendance(
  _user_id uuid,
  _work_date date,
  _check_in timestamptz DEFAULT NULL,
  _check_out timestamptz DEFAULT NULL,
  _branch_id uuid DEFAULT NULL,
  _notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company uuid := public.current_company_id();
  v_actor uuid := public.current_profile_id();
  v_minutes integer := 0;
  v_id uuid;
BEGIN
  IF NOT public.has_permission('attendance.manage') THEN
    RAISE EXCEPTION 'not authorized';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE id = _user_id AND company_id = v_company) THEN
    RAISE EXCEPTION 'employee not found';
  END IF;
  IF _check_in IS NOT NULL AND _check_out IS NOT NULL THEN
    IF _check_out < _check_in THEN RAISE EXCEPTION 'check-out is before check-in'; END IF;
    v_minutes := GREATEST(0, (EXTRACT(EPOCH FROM (_check_out - _check_in)) / 60)::int);
  END IF;

  INSERT INTO public.attendance (company_id, branch_id, user_id, work_date, check_in, check_out, minutes_worked, notes, created_by)
  VALUES (v_company, _branch_id, _user_id, COALESCE(_work_date, current_date), _check_in, _check_out, v_minutes, _notes, v_actor)
  ON CONFLICT (user_id, work_date) DO UPDATE
    SET check_in = EXCLUDED.check_in,
        check_out = EXCLUDED.check_out,
        minutes_worked = EXCLUDED.minutes_worked,
        branch_id = EXCLUDED.branch_id,
        notes = EXCLUDED.notes
  RETURNING id INTO v_id;

  PERFORM public.log_audit('attendance.upsert', 'attendance', 'attendance', v_id,
    NULL, jsonb_build_object('user_id', _user_id, 'work_date', _work_date, 'minutes', v_minutes), NULL, _branch_id);
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_advance(
  _user_id uuid,
  _amount numeric,
  _advance_date date DEFAULT NULL,
  _reason text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company uuid := public.current_company_id();
  v_actor uuid := public.current_profile_id();
  v_id uuid;
BEGIN
  IF NOT public.has_permission('payroll.manage') THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF _amount IS NULL OR _amount <= 0 THEN RAISE EXCEPTION 'amount must be greater than zero'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE id = _user_id AND company_id = v_company) THEN
    RAISE EXCEPTION 'employee not found';
  END IF;

  INSERT INTO public.employee_advances (company_id, user_id, amount, advance_date, reason, created_by)
  VALUES (v_company, _user_id, round(_amount, 2), COALESCE(_advance_date, current_date), _reason, v_actor)
  RETURNING id INTO v_id;

  PERFORM public.log_audit('payroll.advance_create', 'payroll', 'employee_advances', v_id,
    NULL, jsonb_build_object('user_id', _user_id, 'amount', _amount));
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.cancel_advance(_advance_id uuid, _reason text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.employee_advances;
BEGIN
  IF NOT public.has_permission('payroll.manage') THEN RAISE EXCEPTION 'not authorized'; END IF;
  SELECT * INTO v_row FROM public.employee_advances
  WHERE id = _advance_id AND company_id = public.current_company_id();
  IF v_row.id IS NULL THEN RAISE EXCEPTION 'advance not found'; END IF;
  IF v_row.status <> 'active' THEN RAISE EXCEPTION 'advance already settled or cancelled'; END IF;
  IF v_row.settled_payment_id IS NOT NULL THEN RAISE EXCEPTION 'advance already deducted from payroll'; END IF;

  UPDATE public.employee_advances SET status = 'cancelled' WHERE id = _advance_id;

  PERFORM public.log_audit('payroll.advance_cancel', 'payroll', 'employee_advances', _advance_id,
    to_jsonb(v_row), NULL, _reason);
  RETURN _advance_id;
END;
$$;

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
  r record;
  v_advances numeric;
  v_payment uuid;
BEGIN
  IF NOT public.has_permission('payroll.manage') THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF _period_start IS NULL OR _period_end IS NULL OR _period_end < _period_start THEN
    RAISE EXCEPTION 'invalid payroll period';
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

REVOKE ALL ON FUNCTION public.clock_in(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.clock_out() FROM anon;
REVOKE ALL ON FUNCTION public.upsert_attendance(uuid, date, timestamptz, timestamptz, uuid, text) FROM anon;
REVOKE ALL ON FUNCTION public.create_advance(uuid, numeric, date, text) FROM anon;
REVOKE ALL ON FUNCTION public.cancel_advance(uuid, text) FROM anon;
REVOKE ALL ON FUNCTION public.run_payroll(date, date) FROM anon;