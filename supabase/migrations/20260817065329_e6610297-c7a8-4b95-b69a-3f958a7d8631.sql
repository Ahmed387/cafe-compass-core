-- 1. Weekly work schedule
CREATE TABLE public.work_schedules (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  weekday smallint NOT NULL CHECK (weekday BETWEEN 0 AND 6),
  opens_at time NOT NULL DEFAULT '08:00',
  closes_at time NOT NULL DEFAULT '00:00',
  is_closed boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (company_id, weekday)
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.work_schedules TO authenticated;
GRANT ALL ON public.work_schedules TO service_role;
ALTER TABLE public.work_schedules ENABLE ROW LEVEL SECURITY;
CREATE POLICY "work_schedules_select" ON public.work_schedules FOR SELECT TO authenticated
  USING (company_id = public.current_company_id());
CREATE POLICY "work_schedules_write" ON public.work_schedules FOR INSERT TO authenticated
  WITH CHECK (company_id = public.current_company_id()
    AND (public.has_permission('settings.manage') OR public.is_super_admin()));
CREATE POLICY "work_schedules_update" ON public.work_schedules FOR UPDATE TO authenticated
  USING (company_id = public.current_company_id()
    AND (public.has_permission('settings.manage') OR public.is_super_admin()))
  WITH CHECK (company_id = public.current_company_id());
CREATE TRIGGER work_schedules_updated_at BEFORE UPDATE ON public.work_schedules
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- 2. Shift policy
CREATE TABLE public.shift_policies (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  company_id uuid NOT NULL UNIQUE REFERENCES public.companies(id) ON DELETE CASCADE,
  warn_minutes integer NOT NULL DEFAULT 30,
  open_grace_minutes integer NOT NULL DEFAULT 5,
  auto_close boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE ON public.shift_policies TO authenticated;
GRANT ALL ON public.shift_policies TO service_role;
ALTER TABLE public.shift_policies ENABLE ROW LEVEL SECURITY;
CREATE POLICY "shift_policies_select" ON public.shift_policies FOR SELECT TO authenticated
  USING (company_id = public.current_company_id());
CREATE POLICY "shift_policies_insert" ON public.shift_policies FOR INSERT TO authenticated
  WITH CHECK (company_id = public.current_company_id()
    AND (public.has_permission('settings.manage') OR public.is_super_admin()));
CREATE POLICY "shift_policies_update" ON public.shift_policies FOR UPDATE TO authenticated
  USING (company_id = public.current_company_id()
    AND (public.has_permission('settings.manage') OR public.is_super_admin()))
  WITH CHECK (company_id = public.current_company_id());
CREATE TRIGGER shift_policies_updated_at BEFORE UPDATE ON public.shift_policies
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- 3. Employee documents (ID card images etc.)
CREATE TABLE public.user_documents (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('id_front','id_back','other')),
  file_path text NOT NULL,
  mime_type text,
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX user_documents_user_idx ON public.user_documents(user_id);
GRANT SELECT ON public.user_documents TO authenticated;
GRANT ALL ON public.user_documents TO service_role;
ALTER TABLE public.user_documents ENABLE ROW LEVEL SECURITY;
CREATE POLICY "user_documents_select" ON public.user_documents FOR SELECT TO authenticated
  USING (company_id = public.current_company_id()
    AND (user_id = public.current_profile_id()
      OR public.has_permission('users.view') OR public.is_super_admin()));

-- 4. Business-day close timestamp helper
CREATE OR REPLACE FUNCTION public.work_day_close_at(_company_id uuid, _reference timestamptz)
RETURNS timestamptz
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE _tz text; _local timestamp; _day date; _row public.work_schedules;
BEGIN
  SELECT COALESCE(timezone,'UTC') INTO _tz FROM public.companies WHERE id = _company_id;
  IF _tz IS NULL THEN RETURN NULL; END IF;
  _local := _reference AT TIME ZONE _tz;
  _day := _local::date;
  SELECT * INTO _row FROM public.work_schedules
   WHERE company_id = _company_id AND weekday = EXTRACT(DOW FROM _day)::smallint;
  IF _row.id IS NULL OR _row.is_closed THEN RETURN NULL; END IF;
  IF _row.closes_at <= _row.opens_at THEN
    RETURN ((_day + 1)::timestamp + _row.closes_at) AT TIME ZONE _tz;
  END IF;
  RETURN (_day::timestamp + _row.closes_at) AT TIME ZONE _tz;
END $$;

-- 5. Countdown info for the signed-in user
CREATE OR REPLACE FUNCTION public.shift_deadline_info()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE _company uuid := public.current_company_id();
  _profile uuid := public.current_profile_id();
  _policy public.shift_policies; _s public.shifts; _close timestamptz;
  _tz text; _local timestamp; _row public.work_schedules; _open_at timestamptz;
BEGIN
  IF _company IS NULL OR _profile IS NULL THEN RETURN '{}'::jsonb; END IF;
  SELECT * INTO _policy FROM public.shift_policies WHERE company_id = _company;
  SELECT * INTO _s FROM public.shifts WHERE company_id = _company AND status = 'open'
    ORDER BY opened_at LIMIT 1;
  SELECT COALESCE(timezone,'UTC') INTO _tz FROM public.companies WHERE id = _company;
  _local := now() AT TIME ZONE _tz;
  SELECT * INTO _row FROM public.work_schedules
    WHERE company_id = _company AND weekday = EXTRACT(DOW FROM _local::date)::smallint;
  IF _row.id IS NOT NULL AND NOT _row.is_closed THEN
    _open_at := (_local::date::timestamp + _row.opens_at) AT TIME ZONE _tz;
  END IF;

  IF _s.id IS NULL THEN
    RETURN jsonb_build_object(
      'has_open_shift', false,
      'opens_at', _open_at,
      'open_grace_minutes', COALESCE(_policy.open_grace_minutes, 5),
      'late_open', _open_at IS NOT NULL
        AND now() > _open_at + make_interval(mins => COALESCE(_policy.open_grace_minutes,5)),
      'server_now', now()
    );
  END IF;

  _close := public.work_day_close_at(_company, _s.opened_at);
  IF _close IS NOT NULL AND _close <= _s.opened_at THEN
    _close := public.work_day_close_at(_company, _s.opened_at + interval '1 day');
  END IF;

  RETURN jsonb_build_object(
    'has_open_shift', true,
    'shift_id', _s.id,
    'shift_user_id', _s.user_id,
    'is_mine', _s.user_id = _profile,
    'opened_at', _s.opened_at,
    'closes_at', _close,
    'warn_minutes', COALESCE(_policy.warn_minutes, 30),
    'auto_close', COALESCE(_policy.auto_close, true),
    'server_now', now()
  );
END $$;

-- 6. Auto close forgotten shifts (+ warning notification)
CREATE OR REPLACE FUNCTION public.auto_close_due_shifts()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _s public.shifts; _policy public.shift_policies; _close timestamptz;
  _closed integer := 0; _expected numeric; _cash_in numeric; _cash_out numeric;
BEGIN
  FOR _s IN SELECT * FROM public.shifts WHERE status = 'open' LOOP
    SELECT * INTO _policy FROM public.shift_policies WHERE company_id = _s.company_id;
    _close := public.work_day_close_at(_s.company_id, _s.opened_at);
    IF _close IS NOT NULL AND _close <= _s.opened_at THEN
      _close := public.work_day_close_at(_s.company_id, _s.opened_at + interval '1 day');
    END IF;
    IF _close IS NULL THEN CONTINUE; END IF;

    IF now() >= _close - make_interval(mins => COALESCE(_policy.warn_minutes, 30))
       AND now() < _close THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.notifications
        WHERE company_id = _s.company_id AND type = 'shift.closing_soon'
          AND data->>'shift_id' = _s.id::text
      ) THEN
        INSERT INTO public.notifications (company_id, branch_id, user_id, type, severity, title, body, data)
        VALUES (_s.company_id, _s.branch_id, _s.user_id, 'shift.closing_soon', 'warning',
          'Shift closing soon',
          'The open shift will be closed automatically at the end of working hours.',
          jsonb_build_object('shift_id', _s.id, 'closes_at', _close));
        INSERT INTO public.notifications (company_id, branch_id, required_permission, type, severity, title, body, data)
        VALUES (_s.company_id, _s.branch_id, 'shifts.close', 'shift.closing_soon', 'warning',
          'Shift closing soon',
          'An open shift will be closed automatically at the end of working hours.',
          jsonb_build_object('shift_id', _s.id, 'closes_at', _close));
      END IF;
    END IF;

    IF COALESCE(_policy.auto_close, true) AND now() >= _close THEN
      SELECT COALESCE(SUM(p.amount),0) INTO _cash_in
      FROM public.orders o JOIN public.order_payments p ON p.order_id = o.id
      WHERE o.shift_id = _s.id AND o.status <> 'cancelled' AND p.method_key = 'cash';
      SELECT COALESCE(SUM(r.amount),0) INTO _cash_out
      FROM public.order_refunds r
      WHERE r.shift_id = _s.id AND r.status = 'active' AND COALESCE(r.method_key,'cash') = 'cash';
      _expected := _s.opening_cash + _cash_in - _cash_out;

      UPDATE public.shifts SET status = 'closed', closing_cash = _expected, expected_cash = _expected,
        variance = 0, closed_at = now(),
        notes = COALESCE(notes || ' | ', '') || 'Auto-closed at end of working hours'
      WHERE id = _s.id;

      INSERT INTO public.notifications (company_id, branch_id, required_permission, type, severity, title, body, data)
      VALUES (_s.company_id, _s.branch_id, 'shifts.view', 'shift.auto_closed', 'info',
        'Shift auto-closed',
        'The forgotten shift was closed automatically at the end of working hours.',
        jsonb_build_object('shift_id', _s.id, 'expected_cash', _expected));

      INSERT INTO public.audit_logs (company_id, branch_id, action, module, entity_type, entity_id, new_values, reason)
      VALUES (_s.company_id, _s.branch_id, 'shift.auto_close', 'pos', 'shifts', _s.id,
        jsonb_build_object('expected_cash', _expected), 'Automatic end-of-day closure');

      _closed := _closed + 1;
    END IF;
  END LOOP;
  RETURN _closed;
END $$;

-- 7. Role management: who uses a role, delete/reassign
CREATE OR REPLACE FUNCTION public.role_usage(_role_id uuid)
RETURNS TABLE(user_id uuid, display_name text, email text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT up.id, COALESCE(up.display_name, up.first_name), up.email
  FROM public.user_roles ur
  JOIN public.user_profiles up ON up.id = ur.user_id
  JOIN public.roles r ON r.id = ur.role_id
  WHERE ur.role_id = _role_id
    AND r.company_id = public.current_company_id()
    AND (public.has_permission('users.manage_roles') OR public.is_super_admin())
$$;

CREATE OR REPLACE FUNCTION public.delete_role(_role_id uuid, _reassign_role_id uuid DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _r public.roles; _company uuid := public.current_company_id();
BEGIN
  IF NOT (public.has_permission('users.manage_roles') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  SELECT * INTO _r FROM public.roles WHERE id = _role_id AND company_id = _company;
  IF _r.id IS NULL THEN RAISE EXCEPTION 'Role not found'; END IF;
  IF _r.is_system_role THEN RAISE EXCEPTION 'System roles cannot be deleted'; END IF;

  IF _reassign_role_id IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM public.roles WHERE id = _reassign_role_id AND company_id = _company) THEN
      RAISE EXCEPTION 'Target role not found';
    END IF;
    INSERT INTO public.user_roles (user_id, role_id)
    SELECT ur.user_id, _reassign_role_id FROM public.user_roles ur WHERE ur.role_id = _role_id
    ON CONFLICT (user_id, role_id) DO NOTHING;
  END IF;

  DELETE FROM public.user_roles WHERE role_id = _role_id;
  DELETE FROM public.role_permissions WHERE role_id = _role_id;
  DELETE FROM public.roles WHERE id = _role_id;
  PERFORM public.log_audit('role.delete','users','roles',_role_id,
    jsonb_build_object('name',_r.name), jsonb_build_object('reassigned_to',_reassign_role_id), NULL, NULL);
  RETURN _role_id;
END $$;

-- 8. Assign multiple roles to an existing employee
CREATE OR REPLACE FUNCTION public.set_user_roles(_user_id uuid, _role_ids uuid[])
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _company uuid := public.current_company_id();
BEGIN
  IF NOT (public.has_permission('users.manage_roles') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE id = _user_id AND company_id = _company) THEN
    RAISE EXCEPTION 'User not found';
  END IF;
  IF EXISTS (
    SELECT 1 FROM unnest(COALESCE(_role_ids,'{}'::uuid[])) rid
    WHERE NOT EXISTS (SELECT 1 FROM public.roles WHERE id = rid AND company_id = _company)
  ) THEN RAISE EXCEPTION 'Invalid role'; END IF;

  DELETE FROM public.user_roles WHERE user_id = _user_id
    AND role_id <> ALL (COALESCE(_role_ids,'{}'::uuid[]));
  INSERT INTO public.user_roles (user_id, role_id)
  SELECT _user_id, rid FROM unnest(COALESCE(_role_ids,'{}'::uuid[])) rid
  ON CONFLICT (user_id, role_id) DO NOTHING;
  PERFORM public.log_audit('user.roles_change','users','user_profiles',_user_id,NULL,
    jsonb_build_object('role_ids',_role_ids),NULL,NULL);
  RETURN _user_id;
END $$;

-- 9. Seed default working hours and policy for existing companies
INSERT INTO public.work_schedules (company_id, weekday, opens_at, closes_at, is_closed)
SELECT c.id, d.wd, '08:00'::time, '00:00'::time, false
FROM public.companies c CROSS JOIN generate_series(0,6) AS d(wd)
ON CONFLICT (company_id, weekday) DO NOTHING;

INSERT INTO public.shift_policies (company_id)
SELECT c.id FROM public.companies c
ON CONFLICT (company_id) DO NOTHING;

-- 10. Schedule the automatic closure check every 5 minutes
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('auto-close-shifts', '*/5 * * * *', $$SELECT public.auto_close_due_shifts();$$);
