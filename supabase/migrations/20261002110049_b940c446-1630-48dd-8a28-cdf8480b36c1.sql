GRANT SELECT ON public.stock_overrides TO authenticated;
CREATE POLICY "Managers can view stock overrides" ON public.stock_overrides FOR SELECT TO authenticated
USING (company_id = public.current_company_id() AND (public.is_super_admin() OR public.has_permission('audit.view')));