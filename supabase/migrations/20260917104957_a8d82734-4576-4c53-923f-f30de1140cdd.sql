DROP POLICY IF EXISTS categories_insert ON public.categories;
DROP POLICY IF EXISTS categories_update ON public.categories;

CREATE POLICY categories_insert ON public.categories
  FOR INSERT TO authenticated
  WITH CHECK (company_id = current_company_id() AND is_super_admin());

CREATE POLICY categories_update ON public.categories
  FOR UPDATE TO authenticated
  USING (company_id = current_company_id() AND is_super_admin())
  WITH CHECK (company_id = current_company_id() AND is_super_admin());