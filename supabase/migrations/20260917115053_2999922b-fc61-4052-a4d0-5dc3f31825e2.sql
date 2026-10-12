ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS show_on_public_menu boolean NOT NULL DEFAULT false;

UPDATE public.products
SET show_on_public_menu = EXISTS (
  SELECT 1 FROM public.product_recipes pr WHERE pr.product_id = products.id
)
WHERE is_active = true;

CREATE OR REPLACE FUNCTION public.enforce_public_menu_requires_recipe()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.show_on_public_menu
     AND NOT EXISTS (SELECT 1 FROM public.product_recipes pr WHERE pr.product_id = NEW.id) THEN
    RAISE EXCEPTION 'RECIPE_REQUIRED: لا يمكن عرض هذا المنتج للزبون قبل إضافة وصفة مخزنية له';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_products_public_menu_recipe ON public.products;
CREATE TRIGGER trg_products_public_menu_recipe
  BEFORE INSERT OR UPDATE OF show_on_public_menu ON public.products
  FOR EACH ROW EXECUTE FUNCTION public.enforce_public_menu_requires_recipe();

CREATE OR REPLACE FUNCTION public.public_menu(_branch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _company_id uuid;
  _result jsonb;
BEGIN
  SELECT b.company_id INTO _company_id
  FROM public.branches b
  JOIN public.companies c ON c.id = b.company_id
  WHERE b.id = _branch_id AND b.is_active AND c.is_active;

  IF _company_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT jsonb_build_object(
    'company', (
      SELECT jsonb_build_object('name', c.name, 'logo_url', c.logo_url, 'currency', c.currency, 'default_language', c.default_language)
      FROM public.companies c WHERE c.id = _company_id
    ),
    'branch', (
      SELECT jsonb_build_object('id', b.id, 'name', b.name, 'address', b.address, 'phone', b.phone)
      FROM public.branches b WHERE b.id = _branch_id
    ),
    'categories', COALESCE((
      SELECT jsonb_agg(cat ORDER BY cat->>'display_order', cat->>'name')
      FROM (
        SELECT jsonb_build_object(
          'id', cg.id,
          'name', cg.name,
          'name_ar', cg.name_ar,
          'display_order', cg.display_order,
          'products', COALESCE((
            SELECT jsonb_agg(prod ORDER BY prod->>'display_order', prod->>'name')
            FROM (
              SELECT jsonb_build_object(
                'id', p.id,
                'name', p.name,
                'name_ar', p.name_ar,
                'description', p.description,
                'image_url', p.image_url,
                'display_order', p.display_order,
                'price', COALESCE(pbs.price_override, p.base_price),
                'sizes', COALESCE((
                  SELECT jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'name_ar', s.name_ar, 'price_delta', s.price_delta)
                                   ORDER BY s.display_order, s.name)
                  FROM public.product_sizes s
                  WHERE s.product_id = p.id AND s.is_active
                ), '[]'::jsonb)
              ) AS prod
              FROM public.products p
              LEFT JOIN public.product_branch_settings pbs
                ON pbs.product_id = p.id AND pbs.branch_id = _branch_id
              WHERE p.category_id = cg.id
                AND p.is_active AND p.is_available
                AND p.show_on_public_menu
                AND COALESCE(pbs.is_available, true)
                AND EXISTS (SELECT 1 FROM public.product_recipes pr WHERE pr.product_id = p.id)
            ) prods
          ), '[]'::jsonb)
        ) AS cat
        FROM public.categories cg
        WHERE cg.company_id = _company_id AND cg.is_active
      ) cats
      WHERE jsonb_array_length(cat->'products') > 0
    ), '[]'::jsonb)
  ) INTO _result;

  RETURN _result;
END;
$function$;