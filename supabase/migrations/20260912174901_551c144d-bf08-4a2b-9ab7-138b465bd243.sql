CREATE OR REPLACE FUNCTION public.delete_user_by_admin(p_target_user_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_actor uuid;
  v_company uuid;
  v_target public.user_profiles;
  v_auth_user uuid;
  v_blocked boolean;
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'غير مصرح / Not authorized';
  END IF;

  SELECT id, company_id INTO v_actor, v_company
  FROM public.user_profiles
  WHERE auth_user_id = auth.uid() AND is_active
  LIMIT 1;

  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'غير مصرح / Not authorized';
  END IF;

  SELECT * INTO v_target FROM public.user_profiles WHERE id = p_target_user_id;
  IF v_target.id IS NULL OR v_target.company_id <> v_company THEN
    RAISE EXCEPTION 'المستخدم غير موجود / User not found';
  END IF;

  IF v_target.id = v_actor OR v_target.auth_user_id = auth.uid() THEN
    RAISE EXCEPTION 'لا يمكن حذف حسابك الشخصي / Cannot delete your own account';
  END IF;

  IF lower(coalesce(v_target.email, '')) = 'assemsalah19@icloud.com' THEN
    RAISE EXCEPTION 'لا يمكن حذف حساب المالك الأساسي / Cannot delete the primary owner account';
  END IF;

  SELECT EXISTS (SELECT 1 FROM public.orders WHERE created_by = v_target.id)
      OR EXISTS (SELECT 1 FROM public.cash_transactions WHERE created_by = v_target.id)
      OR EXISTS (SELECT 1 FROM public.shifts WHERE user_id = v_target.id OR closed_by = v_target.id)
      OR EXISTS (SELECT 1 FROM public.audit_logs WHERE user_id = v_target.id)
      OR EXISTS (SELECT 1 FROM public.purchases WHERE created_by = v_target.id OR received_by = v_target.id)
      OR EXISTS (SELECT 1 FROM public.expenses WHERE created_by = v_target.id OR approved_by = v_target.id)
      OR EXISTS (SELECT 1 FROM public.salary_payments WHERE user_id = v_target.id OR created_by = v_target.id OR paid_by = v_target.id)
      OR EXISTS (SELECT 1 FROM public.stock_movements WHERE created_by = v_target.id)
      OR EXISTS (SELECT 1 FROM public.order_payments WHERE created_by = v_target.id)
      OR EXISTS (SELECT 1 FROM public.partners WHERE user_id = v_target.id OR created_by = v_target.id)
    INTO v_blocked;

  IF v_blocked THEN
    RAISE EXCEPTION 'لا يمكن حذف مستخدم لديه سجلات أو حركات مالية مرتبطة بالنظام / Cannot delete user with operational records';
  END IF;

  v_auth_user := v_target.auth_user_id;

  DELETE FROM public.user_roles WHERE user_id = v_target.id;
  DELETE FROM public.user_branches WHERE user_id = v_target.id;
  DELETE FROM public.user_documents WHERE user_id = v_target.id;
  DELETE FROM public.attendance WHERE user_id = v_target.id;
  DELETE FROM public.notifications WHERE user_id = v_target.id;
  DELETE FROM public.employee_advances WHERE user_id = v_target.id;
  DELETE FROM public.employee_salaries WHERE user_id = v_target.id;

  INSERT INTO public.audit_logs (company_id, user_id, action, module, entity_type, entity_id, old_values)
  VALUES (v_company, v_actor, 'user.delete', 'users', 'user_profiles', v_target.id,
          jsonb_build_object('email', v_target.email, 'display_name', v_target.display_name));

  DELETE FROM public.user_profiles WHERE id = v_target.id;

  RETURN v_auth_user;
END;
$$;

REVOKE ALL ON FUNCTION public.delete_user_by_admin(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_user_by_admin(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.delete_user_by_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_user_by_admin(uuid) TO service_role;