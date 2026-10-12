ALTER TABLE public.soft_opening_items ADD COLUMN IF NOT EXISTS is_available boolean NOT NULL DEFAULT true;

UPDATE public.soft_opening_items s SET is_available = p.is_available
FROM public.products p WHERE p.sku = 'SO-' || s.slug;

INSERT INTO public.payment_methods (company_id, key, name, kind, is_active)
SELECT c.id, 'card', 'Visa / Card', 'card', true FROM public.companies c
WHERE NOT EXISTS (SELECT 1 FROM public.payment_methods pm WHERE pm.company_id = c.id AND pm.key = 'card');

CREATE OR REPLACE FUNCTION public.set_product_availability(_product_id uuid, _available boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _p record;
BEGIN
  IF NOT (public.is_super_admin() OR public.has_permission('pos.view') OR public.has_permission('products.update')) THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;
  SELECT id, sku, is_available, company_id INTO _p FROM public.products
  WHERE id = _product_id AND company_id = public.current_company_id();
  IF NOT FOUND THEN RAISE EXCEPTION 'Product not found'; END IF;
  UPDATE public.products SET is_available = _available, updated_at = now() WHERE id = _product_id;
  IF _p.sku LIKE 'SO-%' THEN
    UPDATE public.soft_opening_items SET is_available = _available, updated_at = now()
    WHERE 'SO-' || slug = _p.sku;
  END IF;
  PERFORM public.log_audit(CASE WHEN _available THEN 'product_back_in_stock' ELSE 'product_sold_out' END,
    'products', 'product', _product_id,
    jsonb_build_object('is_available', _p.is_available), jsonb_build_object('is_available', _available));
END $$;

REVOKE ALL ON FUNCTION public.set_product_availability(uuid, boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.set_product_availability(uuid, boolean) TO authenticated;