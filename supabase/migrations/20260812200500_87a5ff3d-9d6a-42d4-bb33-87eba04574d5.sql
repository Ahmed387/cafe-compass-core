
REVOKE EXECUTE ON FUNCTION public.current_profile_id(), public.current_company_id(), public.current_partner_id(), public.has_permission(text), public.is_super_admin(), public.can_access_branch(uuid) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.current_profile_id(), public.current_company_id(), public.current_partner_id(), public.has_permission(text), public.is_super_admin(), public.can_access_branch(uuid) TO authenticated;

-- Record an audit entry as the current user (append-only)
CREATE OR REPLACE FUNCTION public.log_audit(
  _action text, _module text, _entity_type text DEFAULT NULL, _entity_id uuid DEFAULT NULL,
  _old_values jsonb DEFAULT NULL, _new_values jsonb DEFAULT NULL, _reason text DEFAULT NULL,
  _branch_id uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _profile public.user_profiles; _id uuid;
BEGIN
  SELECT * INTO _profile FROM public.user_profiles WHERE auth_user_id = auth.uid();
  IF _profile.id IS NULL THEN RETURN NULL; END IF;
  INSERT INTO public.audit_logs (company_id, branch_id, user_id, action, module, entity_type, entity_id, old_values, new_values, reason)
  VALUES (_profile.company_id, _branch_id, _profile.id, _action, _module, _entity_type, _entity_id, _old_values, _new_values, _reason)
  RETURNING id INTO _id;
  RETURN _id;
END $$;
REVOKE EXECUTE ON FUNCTION public.log_audit(text,text,text,uuid,jsonb,jsonb,text,uuid) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.log_audit(text,text,text,uuid,jsonb,jsonb,text,uuid) TO authenticated;

-- First-login provisioning: link auth user to a company profile.
-- The very first provisioned user of a company becomes Super Admin.
CREATE OR REPLACE FUNCTION public.bootstrap_current_user(_first_name text DEFAULT NULL, _last_name text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  _uid uuid := auth.uid();
  _email text;
  _company uuid;
  _profile uuid;
  _role uuid;
  _is_first boolean;
BEGIN
  IF _uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;

  SELECT id INTO _profile FROM public.user_profiles WHERE auth_user_id = _uid;
  IF _profile IS NOT NULL THEN RETURN _profile; END IF;

  SELECT email INTO _email FROM auth.users WHERE id = _uid;
  SELECT id INTO _company FROM public.companies WHERE is_active ORDER BY created_at LIMIT 1;
  IF _company IS NULL THEN RAISE EXCEPTION 'No company configured'; END IF;

  SELECT NOT EXISTS (
    SELECT 1 FROM public.user_roles ur JOIN public.roles r ON r.id = ur.role_id
    WHERE r.company_id = _company AND r.key = 'super_admin'
  ) INTO _is_first;

  INSERT INTO public.user_profiles (auth_user_id, company_id, first_name, last_name, display_name, email)
  VALUES (_uid, _company, COALESCE(NULLIF(_first_name,''), split_part(_email,'@',1)), _last_name,
          NULLIF(TRIM(COALESCE(_first_name,'') || ' ' || COALESCE(_last_name,'')), ''), _email)
  RETURNING id INTO _profile;

  IF _is_first THEN
    SELECT id INTO _role FROM public.roles WHERE company_id = _company AND key = 'super_admin';
    IF _role IS NOT NULL THEN
      INSERT INTO public.user_roles (user_id, role_id) VALUES (_profile, _role);
      INSERT INTO public.user_branches (user_id, branch_id, is_default)
      SELECT _profile, b.id, row_number() OVER (ORDER BY b.created_at) = 1
      FROM public.branches b WHERE b.company_id = _company;
    END IF;
  END IF;

  INSERT INTO public.audit_logs (company_id, user_id, action, module, entity_type, entity_id)
  VALUES (_company, _profile, CASE WHEN _is_first THEN 'user.bootstrap_super_admin' ELSE 'user.bootstrap' END,
          'users', 'user_profiles', _profile);

  RETURN _profile;
END $$;
REVOKE EXECUTE ON FUNCTION public.bootstrap_current_user(text,text) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.bootstrap_current_user(text,text) TO authenticated;
