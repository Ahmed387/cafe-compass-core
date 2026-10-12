CREATE TABLE public.kitchen_stations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  name text NOT NULL,
  name_ar text,
  display_order integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT, UPDATE ON public.kitchen_stations TO authenticated;
GRANT ALL ON public.kitchen_stations TO service_role;

ALTER TABLE public.kitchen_stations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "stations_select" ON public.kitchen_stations
  FOR SELECT TO authenticated
  USING (company_id = public.current_company_id());

CREATE POLICY "stations_insert" ON public.kitchen_stations
  FOR INSERT TO authenticated
  WITH CHECK (company_id = public.current_company_id() AND public.has_permission('products.create'));

CREATE POLICY "stations_update" ON public.kitchen_stations
  FOR UPDATE TO authenticated
  USING (company_id = public.current_company_id() AND public.has_permission('products.edit'))
  WITH CHECK (company_id = public.current_company_id());

CREATE TRIGGER t_kitchen_stations_updated_at
  BEFORE UPDATE ON public.kitchen_stations
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER t_kitchen_stations_no_delete
  BEFORE DELETE ON public.kitchen_stations
  FOR EACH ROW EXECUTE FUNCTION public.forbid_hard_delete();

ALTER TABLE public.products
  ADD COLUMN station_id uuid REFERENCES public.kitchen_stations(id) ON DELETE SET NULL;

ALTER TABLE public.order_items
  ADD COLUMN station_id uuid REFERENCES public.kitchen_stations(id) ON DELETE SET NULL;

CREATE INDEX idx_order_items_station ON public.order_items(station_id);
CREATE INDEX idx_products_station ON public.products(station_id);

CREATE OR REPLACE FUNCTION public.set_order_item_station()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.station_id IS NULL AND NEW.product_id IS NOT NULL THEN
    SELECT p.station_id INTO NEW.station_id FROM public.products p WHERE p.id = NEW.product_id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER t_order_items_station
  BEFORE INSERT ON public.order_items
  FOR EACH ROW EXECUTE FUNCTION public.set_order_item_station();

INSERT INTO public.kitchen_stations (company_id, name, name_ar, display_order)
SELECT c.id, s.name, s.name_ar, s.ord
FROM public.companies c
CROSS JOIN (VALUES
  ('Bar', 'البار', 1),
  ('Hot Kitchen', 'المطبخ الساخن', 2),
  ('Pastry', 'الحلويات', 3)
) AS s(name, name_ar, ord);