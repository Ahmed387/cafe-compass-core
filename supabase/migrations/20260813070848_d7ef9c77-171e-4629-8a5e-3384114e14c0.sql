-- CATEGORIES
CREATE TABLE public.categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  name text NOT NULL,
  name_ar text,
  display_order integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE ON public.categories TO authenticated;
GRANT ALL ON public.categories TO service_role;
ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;
CREATE POLICY "categories_select" ON public.categories FOR SELECT TO authenticated USING (company_id = public.current_company_id());
CREATE POLICY "categories_insert" ON public.categories FOR INSERT TO authenticated WITH CHECK (company_id = public.current_company_id() AND public.has_permission('products.create'));
CREATE POLICY "categories_update" ON public.categories FOR UPDATE TO authenticated USING (company_id = public.current_company_id() AND public.has_permission('products.update'));
CREATE TRIGGER t_categories_upd BEFORE UPDATE ON public.categories FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- PRODUCTS
CREATE TABLE public.products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  category_id uuid REFERENCES public.categories(id),
  name text NOT NULL,
  name_ar text,
  description text,
  image_url text,
  sku text,
  base_price numeric(12,2) NOT NULL DEFAULT 0,
  cost numeric(12,2) NOT NULL DEFAULT 0,
  is_taxable boolean NOT NULL DEFAULT false,
  is_available boolean NOT NULL DEFAULT true,
  is_active boolean NOT NULL DEFAULT true,
  display_order integer NOT NULL DEFAULT 0,
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_products_company_category ON public.products(company_id, category_id);
GRANT SELECT, INSERT, UPDATE ON public.products TO authenticated;
GRANT ALL ON public.products TO service_role;
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
CREATE POLICY "products_select" ON public.products FOR SELECT TO authenticated USING (company_id = public.current_company_id());
CREATE POLICY "products_insert" ON public.products FOR INSERT TO authenticated WITH CHECK (company_id = public.current_company_id() AND public.has_permission('products.create'));
CREATE POLICY "products_update" ON public.products FOR UPDATE TO authenticated USING (company_id = public.current_company_id() AND public.has_permission('products.update'));
CREATE TRIGGER t_products_upd BEFORE UPDATE ON public.products FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- PRODUCT SIZES
CREATE TABLE public.product_sizes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  name text NOT NULL,
  name_ar text,
  price_delta numeric(12,2) NOT NULL DEFAULT 0,
  is_default boolean NOT NULL DEFAULT false,
  is_active boolean NOT NULL DEFAULT true,
  display_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.product_sizes TO authenticated;
GRANT ALL ON public.product_sizes TO service_role;
ALTER TABLE public.product_sizes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "product_sizes_select" ON public.product_sizes FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.products p WHERE p.id = product_id AND p.company_id = public.current_company_id()));
CREATE POLICY "product_sizes_write" ON public.product_sizes FOR ALL TO authenticated USING (EXISTS (SELECT 1 FROM public.products p WHERE p.id = product_id AND p.company_id = public.current_company_id()) AND public.has_permission('products.update')) WITH CHECK (EXISTS (SELECT 1 FROM public.products p WHERE p.id = product_id AND p.company_id = public.current_company_id()) AND public.has_permission('products.update'));
CREATE TRIGGER t_product_sizes_upd BEFORE UPDATE ON public.product_sizes FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- MODIFIER GROUPS
CREATE TABLE public.modifier_groups (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  name text NOT NULL,
  name_ar text,
  min_select integer NOT NULL DEFAULT 0,
  max_select integer NOT NULL DEFAULT 1,
  is_active boolean NOT NULL DEFAULT true,
  display_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE ON public.modifier_groups TO authenticated;
GRANT ALL ON public.modifier_groups TO service_role;
ALTER TABLE public.modifier_groups ENABLE ROW LEVEL SECURITY;
CREATE POLICY "modifier_groups_select" ON public.modifier_groups FOR SELECT TO authenticated USING (company_id = public.current_company_id());
CREATE POLICY "modifier_groups_insert" ON public.modifier_groups FOR INSERT TO authenticated WITH CHECK (company_id = public.current_company_id() AND public.has_permission('products.create'));
CREATE POLICY "modifier_groups_update" ON public.modifier_groups FOR UPDATE TO authenticated USING (company_id = public.current_company_id() AND public.has_permission('products.update'));
CREATE TRIGGER t_modifier_groups_upd BEFORE UPDATE ON public.modifier_groups FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- MODIFIER OPTIONS
CREATE TABLE public.modifier_options (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id uuid NOT NULL REFERENCES public.modifier_groups(id) ON DELETE CASCADE,
  name text NOT NULL,
  name_ar text,
  price_delta numeric(12,2) NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  display_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.modifier_options TO authenticated;
GRANT ALL ON public.modifier_options TO service_role;
ALTER TABLE public.modifier_options ENABLE ROW LEVEL SECURITY;
CREATE POLICY "modifier_options_select" ON public.modifier_options FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.modifier_groups g WHERE g.id = group_id AND g.company_id = public.current_company_id()));
CREATE POLICY "modifier_options_write" ON public.modifier_options FOR ALL TO authenticated USING (EXISTS (SELECT 1 FROM public.modifier_groups g WHERE g.id = group_id AND g.company_id = public.current_company_id()) AND public.has_permission('products.update')) WITH CHECK (EXISTS (SELECT 1 FROM public.modifier_groups g WHERE g.id = group_id AND g.company_id = public.current_company_id()) AND public.has_permission('products.update'));
CREATE TRIGGER t_modifier_options_upd BEFORE UPDATE ON public.modifier_options FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- PRODUCT <-> MODIFIER GROUP
CREATE TABLE public.product_modifier_groups (
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  group_id uuid NOT NULL REFERENCES public.modifier_groups(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (product_id, group_id)
);
GRANT SELECT, INSERT, DELETE ON public.product_modifier_groups TO authenticated;
GRANT ALL ON public.product_modifier_groups TO service_role;
ALTER TABLE public.product_modifier_groups ENABLE ROW LEVEL SECURITY;
CREATE POLICY "pmg_select" ON public.product_modifier_groups FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.products p WHERE p.id = product_id AND p.company_id = public.current_company_id()));
CREATE POLICY "pmg_insert" ON public.product_modifier_groups FOR INSERT TO authenticated WITH CHECK (EXISTS (SELECT 1 FROM public.products p WHERE p.id = product_id AND p.company_id = public.current_company_id()) AND public.has_permission('products.update'));
CREATE POLICY "pmg_delete" ON public.product_modifier_groups FOR DELETE TO authenticated USING (EXISTS (SELECT 1 FROM public.products p WHERE p.id = product_id AND p.company_id = public.current_company_id()) AND public.has_permission('products.update'));

-- BRANCH AVAILABILITY / PRICE OVERRIDE
CREATE TABLE public.product_branch_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  branch_id uuid NOT NULL REFERENCES public.branches(id),
  is_available boolean NOT NULL DEFAULT true,
  price_override numeric(12,2),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (product_id, branch_id)
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.product_branch_settings TO authenticated;
GRANT ALL ON public.product_branch_settings TO service_role;
ALTER TABLE public.product_branch_settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "pbs_select" ON public.product_branch_settings FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.products p WHERE p.id = product_id AND p.company_id = public.current_company_id()) AND public.can_access_branch(branch_id));
CREATE POLICY "pbs_write" ON public.product_branch_settings FOR ALL TO authenticated USING (EXISTS (SELECT 1 FROM public.products p WHERE p.id = product_id AND p.company_id = public.current_company_id()) AND public.can_access_branch(branch_id) AND public.has_permission('products.update')) WITH CHECK (EXISTS (SELECT 1 FROM public.products p WHERE p.id = product_id AND p.company_id = public.current_company_id()) AND public.can_access_branch(branch_id) AND public.has_permission('products.update'));
CREATE TRIGGER t_pbs_upd BEFORE UPDATE ON public.product_branch_settings FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- SEED MENU
INSERT INTO public.categories (id, company_id, name, name_ar, display_order) VALUES
  ('22222222-0000-4000-8000-000000000001','11111111-1111-1111-1111-111111111111','Hot Coffee','قهوة ساخنة',1),
  ('22222222-0000-4000-8000-000000000002','11111111-1111-1111-1111-111111111111','Iced Coffee','قهوة مثلجة',2),
  ('22222222-0000-4000-8000-000000000003','11111111-1111-1111-1111-111111111111','Tea & Others','شاي ومشروبات أخرى',3),
  ('22222222-0000-4000-8000-000000000004','11111111-1111-1111-1111-111111111111','Bakery','مخبوزات',4);

INSERT INTO public.products (id, company_id, category_id, name, name_ar, base_price, cost, display_order) VALUES
  ('33333333-0000-4000-8000-000000000001','11111111-1111-1111-1111-111111111111','22222222-0000-4000-8000-000000000001','Espresso','إسبريسو',35,10,1),
  ('33333333-0000-4000-8000-000000000002','11111111-1111-1111-1111-111111111111','22222222-0000-4000-8000-000000000001','Cappuccino','كابتشينو',55,16,2),
  ('33333333-0000-4000-8000-000000000003','11111111-1111-1111-1111-111111111111','22222222-0000-4000-8000-000000000002','Iced Latte','لاتيه مثلج',65,20,1),
  ('33333333-0000-4000-8000-000000000004','11111111-1111-1111-1111-111111111111','22222222-0000-4000-8000-000000000003','Green Tea','شاي أخضر',30,7,1),
  ('33333333-0000-4000-8000-000000000005','11111111-1111-1111-1111-111111111111','22222222-0000-4000-8000-000000000004','Butter Croissant','كرواسون بالزبدة',45,18,1);

INSERT INTO public.product_sizes (product_id, name, name_ar, price_delta, is_default, display_order) VALUES
  ('33333333-0000-4000-8000-000000000002','Small','صغير',0,true,1),
  ('33333333-0000-4000-8000-000000000002','Medium','وسط',10,false,2),
  ('33333333-0000-4000-8000-000000000002','Large','كبير',20,false,3),
  ('33333333-0000-4000-8000-000000000003','Medium','وسط',0,true,1),
  ('33333333-0000-4000-8000-000000000003','Large','كبير',15,false,2);

INSERT INTO public.modifier_groups (id, company_id, name, name_ar, min_select, max_select, display_order) VALUES
  ('44444444-0000-4000-8000-000000000001','11111111-1111-1111-1111-111111111111','Milk Type','نوع الحليب',0,1,1),
  ('44444444-0000-4000-8000-000000000002','11111111-1111-1111-1111-111111111111','Extras','إضافات',0,3,2);

INSERT INTO public.modifier_options (group_id, name, name_ar, price_delta, display_order) VALUES
  ('44444444-0000-4000-8000-000000000001','Whole Milk','حليب كامل',0,1),
  ('44444444-0000-4000-8000-000000000001','Oat Milk','حليب شوفان',10,2),
  ('44444444-0000-4000-8000-000000000002','Extra Shot','شوت إضافي',12,1),
  ('44444444-0000-4000-8000-000000000002','Vanilla Syrup','فانيليا',8,2),
  ('44444444-0000-4000-8000-000000000002','Caramel Syrup','كراميل',8,3);

INSERT INTO public.product_modifier_groups (product_id, group_id) VALUES
  ('33333333-0000-4000-8000-000000000002','44444444-0000-4000-8000-000000000001'),
  ('33333333-0000-4000-8000-000000000002','44444444-0000-4000-8000-000000000002'),
  ('33333333-0000-4000-8000-000000000003','44444444-0000-4000-8000-000000000001'),
  ('33333333-0000-4000-8000-000000000003','44444444-0000-4000-8000-000000000002');