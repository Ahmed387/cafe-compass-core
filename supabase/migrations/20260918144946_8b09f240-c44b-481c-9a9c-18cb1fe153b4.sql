-- 1) Order-level promotional tracking
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS promotional_discount NUMERIC NOT NULL DEFAULT 0;

ALTER TABLE public.order_items
  ADD COLUMN IF NOT EXISTS base_price NUMERIC NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS offer_id UUID NULL REFERENCES public.product_offers(id),
  ADD COLUMN IF NOT EXISTS bundle_key TEXT NULL;

CREATE INDEX IF NOT EXISTS order_items_offer_id_idx ON public.order_items(offer_id);

-- Backfill base_price for history so refund math never divides by zero
UPDATE public.order_items SET base_price = unit_price WHERE base_price = 0;

-- 2) product_offers: bundles + media
ALTER TABLE public.product_offers
  ADD COLUMN IF NOT EXISTS offer_type TEXT NOT NULL DEFAULT 'single',
  ADD COLUMN IF NOT EXISTS image_path TEXT NULL;

ALTER TABLE public.product_offers ALTER COLUMN product_id DROP NOT NULL;

DO $$ BEGIN
  ALTER TABLE public.product_offers
    ADD CONSTRAINT product_offers_type_check CHECK (offer_type IN ('single','bundle'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE public.product_offers
    ADD CONSTRAINT product_offers_shape_check CHECK (
      (offer_type = 'single' AND product_id IS NOT NULL)
      OR (offer_type = 'bundle' AND product_id IS NULL)
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- 3) bundle items
CREATE TABLE IF NOT EXISTS public.offer_bundle_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  offer_id UUID NOT NULL REFERENCES public.product_offers(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  size_id UUID NULL REFERENCES public.product_sizes(id) ON DELETE SET NULL,
  quantity INTEGER NOT NULL DEFAULT 1 CHECK (quantity > 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS offer_bundle_items_offer_idx ON public.offer_bundle_items(offer_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.offer_bundle_items TO authenticated;
GRANT ALL ON public.offer_bundle_items TO service_role;

ALTER TABLE public.offer_bundle_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "offer_bundle_items_select" ON public.offer_bundle_items;
CREATE POLICY "offer_bundle_items_select" ON public.offer_bundle_items
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.product_offers po
    WHERE po.id = offer_id AND po.company_id = public.current_company_id()
  ));

DROP POLICY IF EXISTS "offer_bundle_items_manage" ON public.offer_bundle_items;
CREATE POLICY "offer_bundle_items_manage" ON public.offer_bundle_items
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.product_offers po
    WHERE po.id = offer_id AND po.company_id = public.current_company_id()
  ) AND (public.has_permission('products.update') OR public.is_super_admin()))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.product_offers po
    WHERE po.id = offer_id AND po.company_id = public.current_company_id()
  ) AND (public.has_permission('products.update') OR public.is_super_admin()));

-- 4) app_settings uniqueness + offers master toggle
CREATE UNIQUE INDEX IF NOT EXISTS app_settings_company_scope_key_uidx
  ON public.app_settings (company_id, scope, key, COALESCE(branch_id, '00000000-0000-0000-0000-000000000000'::uuid));

INSERT INTO public.app_settings (company_id, scope, key, value)
SELECT c.id, 'company', 'offers', jsonb_build_object('enabled', true)
FROM public.companies c
WHERE NOT EXISTS (
  SELECT 1 FROM public.app_settings s
  WHERE s.company_id = c.id AND s.scope = 'company' AND s.key = 'offers' AND s.branch_id IS NULL
);