DROP POLICY IF EXISTS orders_select ON public.orders;
CREATE POLICY orders_select ON public.orders FOR SELECT TO authenticated
USING (
  company_id = public.current_company_id()
  AND public.can_access_branch(branch_id)
  AND (
    public.has_permission('pos.view')
    OR public.has_permission('reports.sales')
    OR public.has_permission('kitchen.view')
  )
);