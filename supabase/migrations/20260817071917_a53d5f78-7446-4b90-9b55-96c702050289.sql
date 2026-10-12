CREATE POLICY "product images readable by staff"
ON storage.objects FOR SELECT TO authenticated
USING (bucket_id = 'product-images');

CREATE POLICY "product images insert by product managers"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (bucket_id = 'product-images' AND (public.has_permission('products.create') OR public.has_permission('products.update')));

CREATE POLICY "product images update by product managers"
ON storage.objects FOR UPDATE TO authenticated
USING (bucket_id = 'product-images' AND public.has_permission('products.update'))
WITH CHECK (bucket_id = 'product-images' AND public.has_permission('products.update'));

CREATE POLICY "product images delete by product managers"
ON storage.objects FOR DELETE TO authenticated
USING (bucket_id = 'product-images' AND public.has_permission('products.update'));