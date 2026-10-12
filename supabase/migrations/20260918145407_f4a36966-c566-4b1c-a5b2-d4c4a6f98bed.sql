REVOKE EXECUTE ON FUNCTION public.offers_enabled(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.set_offers_enabled(boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.offer_price_preview(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.save_product_offer(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.set_offer_active(uuid, boolean, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.offers_performance(date, date) FROM PUBLIC;

DROP POLICY IF EXISTS "offer_images_read" ON storage.objects;
CREATE POLICY "offer_images_read" ON storage.objects
  FOR SELECT TO anon, authenticated
  USING (bucket_id = 'offer-images');

DROP POLICY IF EXISTS "offer_images_write" ON storage.objects;
CREATE POLICY "offer_images_write" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'offer-images'
    AND (public.has_permission('products.update') OR public.is_super_admin()));

DROP POLICY IF EXISTS "offer_images_update" ON storage.objects;
CREATE POLICY "offer_images_update" ON storage.objects
  FOR UPDATE TO authenticated
  USING (bucket_id = 'offer-images'
    AND (public.has_permission('products.update') OR public.is_super_admin()));

DROP POLICY IF EXISTS "offer_images_delete" ON storage.objects;
CREATE POLICY "offer_images_delete" ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'offer-images'
    AND (public.has_permission('products.update') OR public.is_super_admin()));