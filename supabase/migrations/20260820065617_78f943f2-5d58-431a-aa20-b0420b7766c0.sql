DROP POLICY IF EXISTS "offers_insert" ON public.product_offers;
DROP POLICY IF EXISTS "offers_update" ON public.product_offers;
DROP POLICY IF EXISTS "offers_delete" ON public.product_offers;

CREATE POLICY "offers_insert" ON public.product_offers
  FOR INSERT TO authenticated
  WITH CHECK (
    company_id = public.current_company_id()
    AND (public.has_permission('products.create') OR public.has_permission('products.update'))
  );

CREATE POLICY "offers_update" ON public.product_offers
  FOR UPDATE TO authenticated
  USING (company_id = public.current_company_id() AND public.has_permission('products.update'))
  WITH CHECK (company_id = public.current_company_id());

CREATE POLICY "offers_delete" ON public.product_offers
  FOR DELETE TO authenticated
  USING (company_id = public.current_company_id() AND public.has_permission('products.delete'));