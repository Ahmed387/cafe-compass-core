CREATE OR REPLACE FUNCTION public.is_cashier_only()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_roles ur JOIN public.roles r ON r.id=ur.role_id
                  WHERE ur.user_id=public.current_profile_id() AND r.key='cashier')
     AND NOT EXISTS (SELECT 1 FROM public.user_roles ur JOIN public.roles r ON r.id=ur.role_id
                  WHERE ur.user_id=public.current_profile_id() AND r.key IN ('super_admin','manager','partner'));
$$;
REVOKE EXECUTE ON FUNCTION public.is_cashier_only() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_cashier_only() TO authenticated;

CREATE OR REPLACE FUNCTION public.cashier_can_see_shift(_shift_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT EXISTS (SELECT 1 FROM public.shifts s WHERE s.id=_shift_id AND s.status='open'
    AND (s.user_id=public.current_profile_id()
         OR EXISTS (SELECT 1 FROM public.shift_staff ss WHERE ss.shift_id=s.id AND ss.staff_id=public.current_profile_id())));
$$;
REVOKE EXECUTE ON FUNCTION public.cashier_can_see_shift(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cashier_can_see_shift(uuid) TO authenticated;

DROP POLICY IF EXISTS shifts_select ON public.shifts;
CREATE POLICY shifts_select ON public.shifts FOR SELECT TO authenticated USING (
  company_id = current_company_id() AND can_access_branch(branch_id)
  AND (has_permission('shifts.view') OR user_id = current_profile_id())
  AND (NOT public.is_cashier_only() OR public.cashier_can_see_shift(id))
);

DROP POLICY IF EXISTS orders_select ON public.orders;
CREATE POLICY orders_select ON public.orders FOR SELECT TO authenticated USING (
  company_id = current_company_id() AND can_access_branch(branch_id)
  AND (has_permission('pos.view') OR has_permission('reports.sales') OR has_permission('kitchen.view'))
  AND (NOT public.is_cashier_only() OR shift_id IS NULL AND status IN ('open','pending') OR public.cashier_can_see_shift(shift_id))
);