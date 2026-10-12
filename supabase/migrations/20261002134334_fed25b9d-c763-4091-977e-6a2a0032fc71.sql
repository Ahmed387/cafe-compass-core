ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS archived_at timestamptz;

CREATE OR REPLACE FUNCTION public.guard_profile_self_update()
RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public'
AS $$
BEGIN
  IF COALESCE(auth.role(),'') = 'service_role' OR public.is_super_admin()
     OR public.has_permission('users.update') THEN RETURN NEW; END IF;
  -- users.disable may change activation only
  IF public.has_permission('users.disable')
     AND NEW.company_id IS NOT DISTINCT FROM OLD.company_id
     AND NEW.auth_user_id IS NOT DISTINCT FROM OLD.auth_user_id
     AND NEW.email IS NOT DISTINCT FROM OLD.email
     AND NEW.employee_code IS NOT DISTINCT FROM OLD.employee_code
     AND NEW.is_managing_staff IS NOT DISTINCT FROM OLD.is_managing_staff THEN RETURN NEW; END IF;
  IF NEW.company_id IS DISTINCT FROM OLD.company_id
     OR NEW.auth_user_id IS DISTINCT FROM OLD.auth_user_id
     OR NEW.is_active IS DISTINCT FROM OLD.is_active
     OR NEW.archived_at IS DISTINCT FROM OLD.archived_at
     OR NEW.email IS DISTINCT FROM OLD.email
     OR NEW.employee_code IS DISTINCT FROM OLD.employee_code
     OR NEW.is_managing_staff IS DISTINCT FROM OLD.is_managing_staff THEN
    RAISE EXCEPTION 'You cannot change these profile fields';
  END IF;
  RETURN NEW;
END $$;

-- Deletes users with no history; archives (deactivates, strips roles/branches) users with history.
CREATE OR REPLACE FUNCTION public.remove_user_by_admin(p_target_user_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE v_actor uuid; v_company uuid; v_target public.user_profiles; v_auth uuid;
BEGIN
  BEGIN
    v_auth := public.delete_user_by_admin(p_target_user_id);
    RETURN jsonb_build_object('mode','deleted','auth_user_id',v_auth);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%operational records%' THEN RAISE; END IF;
  END;
  SELECT id, company_id INTO v_actor, v_company FROM public.user_profiles WHERE auth_user_id=auth.uid() AND is_active LIMIT 1;
  SELECT * INTO v_target FROM public.user_profiles WHERE id=p_target_user_id AND company_id=v_company;
  IF v_target.id IS NULL THEN RAISE EXCEPTION 'User not found'; END IF;
  UPDATE public.user_profiles SET is_active=false, archived_at=now(), updated_at=now() WHERE id=v_target.id;
  DELETE FROM public.user_roles WHERE user_id=v_target.id;
  DELETE FROM public.user_branches WHERE user_id=v_target.id;
  UPDATE public.employee_salaries SET is_active=false WHERE user_id=v_target.id;
  PERFORM public.log_audit('user.archive','users','user_profiles',v_target.id,
    jsonb_build_object('email',v_target.email,'is_active',v_target.is_active),
    jsonb_build_object('archived',true), 'User has operational history — archived instead of deleted', NULL);
  RETURN jsonb_build_object('mode','archived','auth_user_id',v_target.auth_user_id);
END $$;
REVOKE EXECUTE ON FUNCTION public.remove_user_by_admin(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.remove_user_by_admin(uuid) TO authenticated;