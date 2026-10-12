CREATE TABLE public.product_offers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  title text NOT NULL,
  offer_price numeric(12,2) NOT NULL CHECK (offer_price >= 0),
  base_price_snapshot numeric(12,2) NOT NULL DEFAULT 0,
  unit_cost_snapshot numeric(12,2) NOT NULL DEFAULT 0,
  double_points boolean NOT NULL DEFAULT false,
  starts_at date NOT NULL DEFAULT CURRENT_DATE,
  ends_at date,
  is_active boolean NOT NULL DEFAULT true,
  notes text,
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX product_offers_company_idx ON public.product_offers(company_id, is_active);
CREATE INDEX product_offers_product_idx ON public.product_offers(product_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.product_offers TO authenticated;
GRANT ALL ON public.product_offers TO service_role;

ALTER TABLE public.product_offers ENABLE ROW LEVEL SECURITY;

CREATE POLICY "offers_select" ON public.product_offers
  FOR SELECT TO authenticated
  USING (company_id = public.current_company_id());

CREATE POLICY "offers_insert" ON public.product_offers
  FOR INSERT TO authenticated
  WITH CHECK (company_id = public.current_company_id() AND public.has_permission('products.manage'));

CREATE POLICY "offers_update" ON public.product_offers
  FOR UPDATE TO authenticated
  USING (company_id = public.current_company_id() AND public.has_permission('products.manage'))
  WITH CHECK (company_id = public.current_company_id());

CREATE POLICY "offers_delete" ON public.product_offers
  FOR DELETE TO authenticated
  USING (company_id = public.current_company_id() AND public.has_permission('products.manage'));

CREATE TRIGGER product_offers_updated_at
  BEFORE UPDATE ON public.product_offers
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE OR REPLACE FUNCTION public.offer_candidates(_from date DEFAULT (CURRENT_DATE - 30), _to date DEFAULT CURRENT_DATE)
RETURNS TABLE(
  product_id uuid,
  name text,
  name_ar text,
  image_url text,
  base_price numeric,
  unit_cost numeric,
  qty numeric,
  revenue numeric,
  margin numeric,
  safe_floor numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT d.product_id,
         d.name,
         d.name_ar,
         d.image_url,
         d.base_price,
         d.unit_cost,
         d.qty,
         d.revenue,
         d.margin,
         ROUND(COALESCE(d.unit_cost, 0) * 1.25, 2) AS safe_floor
  FROM public.product_demand(_from, _to) d
$$;

GRANT EXECUTE ON FUNCTION public.offer_candidates(date, date) TO authenticated;