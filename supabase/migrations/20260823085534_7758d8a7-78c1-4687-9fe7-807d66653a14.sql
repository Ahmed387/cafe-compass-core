DROP POLICY IF EXISTS order_items_select ON public.order_items;
CREATE POLICY order_items_select ON public.order_items
FOR SELECT TO authenticated
USING (EXISTS (
  SELECT 1 FROM public.orders o
  WHERE o.id = order_items.order_id
    AND o.company_id = public.current_company_id()
    AND public.can_access_branch(o.branch_id)
    AND (public.has_permission('pos.view') OR public.has_permission('reports.sales') OR public.has_permission('kitchen.view'))
));

DROP POLICY IF EXISTS order_payments_select ON public.order_payments;
CREATE POLICY order_payments_select ON public.order_payments
FOR SELECT TO authenticated
USING (EXISTS (
  SELECT 1 FROM public.orders o
  WHERE o.id = order_payments.order_id
    AND o.company_id = public.current_company_id()
    AND public.can_access_branch(o.branch_id)
    AND (public.has_permission('pos.view') OR public.has_permission('reports.sales') OR public.is_super_admin())
));

DROP POLICY IF EXISTS oim_select ON public.order_item_modifiers;
CREATE POLICY oim_select ON public.order_item_modifiers
FOR SELECT TO authenticated
USING (EXISTS (
  SELECT 1 FROM public.order_items i
  JOIN public.orders o ON o.id = i.order_id
  WHERE i.id = order_item_modifiers.order_item_id
    AND o.company_id = public.current_company_id()
    AND public.can_access_branch(o.branch_id)
    AND (public.has_permission('pos.view') OR public.has_permission('reports.sales') OR public.has_permission('kitchen.view'))
));