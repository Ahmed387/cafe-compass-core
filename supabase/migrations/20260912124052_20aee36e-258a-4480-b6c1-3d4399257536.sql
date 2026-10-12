CREATE UNIQUE INDEX IF NOT EXISTS products_company_sku_unique_idx
  ON public.products (company_id, lower(sku))
  WHERE sku IS NOT NULL AND sku <> '';

CREATE UNIQUE INDEX IF NOT EXISTS products_company_name_unique_idx
  ON public.products (company_id, lower(name));

CREATE UNIQUE INDEX IF NOT EXISTS categories_company_name_unique_idx
  ON public.categories (company_id, lower(name));