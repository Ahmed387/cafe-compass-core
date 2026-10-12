CREATE OR REPLACE FUNCTION public.set_soft_opening_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $function$;

CREATE TABLE public.soft_opening_categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug text NOT NULL UNIQUE,
  name_ar text NOT NULL,
  name_en text NOT NULL,
  display_order integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.soft_opening_categories TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.soft_opening_categories TO authenticated;
GRANT ALL ON public.soft_opening_categories TO service_role;
ALTER TABLE public.soft_opening_categories ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Public can view active soft opening categories" ON public.soft_opening_categories FOR SELECT TO anon USING (is_active);
CREATE POLICY "Staff can view soft opening categories" ON public.soft_opening_categories FOR SELECT TO authenticated USING (true);
CREATE POLICY "Product managers can create soft opening categories" ON public.soft_opening_categories FOR INSERT TO authenticated WITH CHECK (public.is_super_admin() OR public.has_permission('products.create'));
CREATE POLICY "Product managers can update soft opening categories" ON public.soft_opening_categories FOR UPDATE TO authenticated USING (public.is_super_admin() OR public.has_permission('products.update')) WITH CHECK (public.is_super_admin() OR public.has_permission('products.update'));
CREATE POLICY "Product managers can delete soft opening categories" ON public.soft_opening_categories FOR DELETE TO authenticated USING (public.is_super_admin() OR public.has_permission('products.delete'));
CREATE TRIGGER soft_opening_categories_updated_at BEFORE UPDATE ON public.soft_opening_categories FOR EACH ROW EXECUTE FUNCTION public.set_soft_opening_updated_at();

CREATE TABLE public.soft_opening_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  category_id uuid NOT NULL REFERENCES public.soft_opening_categories(id) ON DELETE RESTRICT,
  slug text NOT NULL UNIQUE,
  name_ar text NOT NULL,
  name_en text NOT NULL,
  price numeric(12,2) NOT NULL CHECK (price >= 0),
  image_key text NOT NULL,
  display_order integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.soft_opening_items TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.soft_opening_items TO authenticated;
GRANT ALL ON public.soft_opening_items TO service_role;
ALTER TABLE public.soft_opening_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Public can view active soft opening items" ON public.soft_opening_items FOR SELECT TO anon USING (is_active AND EXISTS (SELECT 1 FROM public.soft_opening_categories c WHERE c.id = category_id AND c.is_active));
CREATE POLICY "Staff can view soft opening items" ON public.soft_opening_items FOR SELECT TO authenticated USING (true);
CREATE POLICY "Product managers can create soft opening items" ON public.soft_opening_items FOR INSERT TO authenticated WITH CHECK (public.is_super_admin() OR public.has_permission('products.create'));
CREATE POLICY "Product managers can update soft opening items" ON public.soft_opening_items FOR UPDATE TO authenticated USING (public.is_super_admin() OR public.has_permission('products.update')) WITH CHECK (public.is_super_admin() OR public.has_permission('products.update'));
CREATE POLICY "Product managers can delete soft opening items" ON public.soft_opening_items FOR DELETE TO authenticated USING (public.is_super_admin() OR public.has_permission('products.delete'));
CREATE INDEX soft_opening_items_category_order_idx ON public.soft_opening_items(category_id, display_order);
CREATE TRIGGER soft_opening_items_updated_at BEFORE UPDATE ON public.soft_opening_items FOR EACH ROW EXECUTE FUNCTION public.set_soft_opening_updated_at();

CREATE TABLE public.soft_opening_item_variants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  item_id uuid NOT NULL REFERENCES public.soft_opening_items(id) ON DELETE CASCADE,
  key text NOT NULL,
  name_ar text NOT NULL,
  name_en text NOT NULL,
  price numeric(12,2) NOT NULL CHECK (price >= 0),
  display_order integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(item_id, key)
);
GRANT SELECT ON public.soft_opening_item_variants TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.soft_opening_item_variants TO authenticated;
GRANT ALL ON public.soft_opening_item_variants TO service_role;
ALTER TABLE public.soft_opening_item_variants ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Public can view active soft opening variants" ON public.soft_opening_item_variants FOR SELECT TO anon USING (is_active AND EXISTS (SELECT 1 FROM public.soft_opening_items i JOIN public.soft_opening_categories c ON c.id=i.category_id WHERE i.id=item_id AND i.is_active AND c.is_active));
CREATE POLICY "Staff can view soft opening variants" ON public.soft_opening_item_variants FOR SELECT TO authenticated USING (true);
CREATE POLICY "Product managers can create soft opening variants" ON public.soft_opening_item_variants FOR INSERT TO authenticated WITH CHECK (public.is_super_admin() OR public.has_permission('products.create'));
CREATE POLICY "Product managers can update soft opening variants" ON public.soft_opening_item_variants FOR UPDATE TO authenticated USING (public.is_super_admin() OR public.has_permission('products.update')) WITH CHECK (public.is_super_admin() OR public.has_permission('products.update'));
CREATE POLICY "Product managers can delete soft opening variants" ON public.soft_opening_item_variants FOR DELETE TO authenticated USING (public.is_super_admin() OR public.has_permission('products.delete'));
CREATE INDEX soft_opening_item_variants_item_order_idx ON public.soft_opening_item_variants(item_id, display_order);
CREATE TRIGGER soft_opening_item_variants_updated_at BEFORE UPDATE ON public.soft_opening_item_variants FOR EACH ROW EXECUTE FUNCTION public.set_soft_opening_updated_at();

INSERT INTO public.soft_opening_categories (slug,name_ar,name_en,display_order) VALUES
('iced-coffee','قهوة مثلجة','Iced Coffee',1),('frappe','فرابيه','Frappe',2),('milkshake','ميلك شيك','Milkshake',3),('smoothies','سموذي فريش','Smoothies',4),('hot-coffee','قهوة ساخنة وإسبريسو بار','Hot Coffee & Espresso',5),('v60','قهوة مقطرة مختصة','V60 Drip',6),('tea-herbs','شاي وأعشاب','Tea & Herbs',7),('fresh-juices','عصائر طبيعية ومكسات','Fresh Juices',8),('mojitos-sodas','موهيتو ومشروبات منعشة','Mojitos & Sodas',9),('ice-cream','آيس كريم بالبولة','Ice Cream Scoops',10),('desserts-waffles','حلويات ووافل','Desserts & Waffles',11);

WITH menu(category_slug,slug,name_ar,name_en,price,image_key,display_order) AS (VALUES
('iced-coffee','iced-americano','آيس أمريكانو','Iced Americano',85,'iced-americano',1),('iced-coffee','iced-latte','آيس لاتيه','Iced Latte',95,'iced-latte',2),('iced-coffee','spanish-latte','سبانش لاتيه','Spanish Latte',110,'spanish-latte',3),('iced-coffee','iced-dark-mocha','دارك موكا','Dark Mocha',100,'iced-dark-mocha',4),('iced-coffee','iced-white-mocha','وايت موكا','White Mocha',95,'iced-white-mocha',5),('iced-coffee','salted-caramel','سولتد كراميل','Salted Caramel',110,'salted-caramel',6),('iced-coffee','iced-pistachio-latte','آيس بستاشيو لاتيه','Pistachio Latte',120,'iced-pistachio-latte',7),('iced-coffee','lotus-latte','لوتس لاتيه','Lotus Latte',115,'lotus-latte',8),('iced-coffee','iced-caramel-macchiato','آيس كراميل ماكياتو','Caramel Macchiato',110,'iced-caramel-macchiato',9),
('frappe','espresso-frappe','إسبريسو فرابيه','Espresso Frappe',120,'espresso-frappe',1),('frappe','vanilla-frappe','فانيليا فرابيه','Vanilla Frappe',110,'vanilla-frappe',2),('frappe','caramel-frappe','كراميل فرابيه','Caramel Frappe',115,'caramel-frappe',3),('frappe','nutella-frappe','نوتيلا فرابيه','Nutella Frappe',125,'nutella-frappe',4),('frappe','pistachio-frappe','بستاشيو فرابيه','Pistachio Frappe',115,'pistachio-frappe',5),('frappe','frappuccino-frappe','فرابتشينو فرابيه','Frappuccino Frappe',130,'frappuccino-frappe',6),
('milkshake','coffee-milkshake','ميلك شيك قهوة','Coffee Milkshake',105,'coffee-milkshake',1),('milkshake','pistachio-milkshake','ميلك شيك بستاشيو','Pistachio Milkshake',115,'pistachio-milkshake',2),('milkshake','caramel-milkshake','ميلك شيك كراميل','Caramel Milkshake',105,'caramel-milkshake',3),('milkshake','oreo-milkshake','ميلك شيك أوريو','Oreo Milkshake',100,'oreo-milkshake',4),('milkshake','chocolate-milkshake','ميلك شيك شوكولاتة','Chocolate Milkshake',120,'chocolate-milkshake',5),('milkshake','strawberry-milkshake','ميلك شيك فراولة','Strawberry Milkshake',105,'strawberry-milkshake',6),
('smoothies','strawberry-smoothie','سموذي فراولة','Strawberry Smoothie',100,'strawberry-smoothie',1),('smoothies','blueberry-smoothie','سموذي توت أزرق','Blueberry Smoothie',105,'blueberry-smoothie',2),('smoothies','passion-fruit-smoothie','سموذي باشن فروت','Passion Fruit Smoothie',100,'passion-fruit-smoothie',3),('smoothies','pina-colada-smoothie','سموذي بينا كولادا','Pina Colada Smoothie',115,'pina-colada-smoothie',4),('smoothies','kiwi-smoothie','سموذي كيوي','Kiwi Smoothie',125,'kiwi-smoothie',5),('smoothies','passion-mango-smoothie','سموذي باشن مانجو','Passion Mango Smoothie',110,'passion-mango-smoothie',6),
('hot-coffee','espresso','إسبريسو','Espresso',50,'espresso',1),('hot-coffee','turkish-coffee','قهوة تركي','Turkish Coffee',40,'turkish-coffee',2),('hot-coffee','hot-americano','أمريكانو ساخن','Hot Americano',70,'hot-americano',3),('hot-coffee','espresso-macchiato','إسبريسو ماكياتو','Espresso Macchiato',55,'espresso-macchiato',4),('hot-coffee','cortado','كورتادو','Cortado',70,'cortado',5),('hot-coffee','flat-white','فلات وايت','Flat White',80,'flat-white',6),('hot-coffee','cappuccino','كابتشينو','Cappuccino',85,'cappuccino',7),('hot-coffee','hot-caramel-macchiato','كراميل ماكياتو ساخن','Hot Caramel Macchiato',100,'hot-caramel-macchiato',8),('hot-coffee','hot-latte','لاتيه ساخن','Hot Latte',85,'hot-latte',9),('hot-coffee','hot-white-mocha','وايت موكا ساخن','White Mocha',85,'hot-white-mocha',10),('hot-coffee','hot-dark-mocha','دارك موكا ساخن','Dark Mocha',90,'hot-dark-mocha',11),('hot-coffee','hot-pistachio-latte','بستاشيو لاتيه ساخن','Pistachio Latte',100,'hot-pistachio-latte',12),('hot-coffee','sweet-espresso','سويت إسبريسو','Sweet Espresso',85,'sweet-espresso',13),('hot-coffee','french-coffee','قهوة فرنساوي','French Coffee',65,'french-coffee',14),('hot-coffee','hazelnut-coffee','قهوة بندق','Hazelnut Coffee',65,'hazelnut-coffee',15),
('v60','v60-ethiopian','V60 إثيوبي','V60 Ethiopian',150,'v60-ethiopian',1),('v60','v60-yemeni','V60 يمني','V60 Yemeni',200,'v60-yemeni',2),('v60','v60-colombian','V60 كولومبي','V60 Colombian',140,'v60-colombian',3),
('tea-herbs','red-tea','شاي أحمر','Red Tea',30,'red-tea',1),('tea-herbs','anise','ينسون','Anise / Yanson',30,'anise',2),('tea-herbs','mint-tea','شاي نعناع','Mint Tea',35,'mint-tea',3),
('fresh-juices','fresh-mango','مانجو فريش','Fresh Mango',90,'fresh-mango',1),('fresh-juices','fresh-avocado','أفوكادو فريش','Fresh Avocado',100,'fresh-avocado',2),('fresh-juices','banana-milk','موز باللبن','Banana with Milk',80,'banana-milk',3),('fresh-juices','fresh-lemon','ليمون فريش','Fresh Lemon',70,'fresh-lemon',4),('fresh-juices','lemon-mint','ليمون نعناع','Lemon Mint',75,'lemon-mint',5),('fresh-juices','guava-mint','جوافة نعناع','Guava Mint',90,'guava-mint',6),('fresh-juices','mango-mint','مانجو نعناع','Mango Mint',95,'mango-mint',7),
('mojitos-sodas','passion-fruit-mojito','موهيتو باشن فروت','Passion Fruit Mojito',100,'passion-fruit-mojito',1),('mojitos-sodas','mineral-water','مياه معدنية','Mineral Water',15,'mineral-water',2),('mojitos-sodas','pepsi','بيبسي','Pepsi',45,'pepsi',3),('mojitos-sodas','seven-up','سفن أب','7Up',45,'seven-up',4),('mojitos-sodas','red-bull','ريد بول','Red Bull',100,'red-bull',5),
('ice-cream','vanilla-scoop','بولة فانيليا','Vanilla Scoop',35,'vanilla-scoop',1),('ice-cream','lotus-scoop','بولة لوتس','Lotus Scoop',45,'lotus-scoop',2),('ice-cream','kinder-scoop','بولة كيندر','Kinder Scoop',45,'kinder-scoop',3),
('desserts-waffles','chocolate-pancake','بان كيك شوكولاتة','Chocolate Pancake',95,'chocolate-pancake',1),('desserts-waffles','cheesecake','تشيز كيك','Cheesecake',100,'cheesecake',2),('desserts-waffles','lotus-waffle','وافل لوتس','Lotus Waffle',95,'lotus-waffle',3),('desserts-waffles','sauce-waffle','وافل صوص','Sauce Waffle',90,'sauce-waffle',4)
)
INSERT INTO public.soft_opening_items(category_id,slug,name_ar,name_en,price,image_key,display_order)
SELECT c.id,m.slug,m.name_ar,m.name_en,m.price,m.image_key,m.display_order FROM menu m JOIN public.soft_opening_categories c ON c.slug=m.category_slug;

WITH variants(item_slug,key,name_ar,name_en,price,display_order) AS (VALUES
('espresso','single','سنجل','Single',50,1),('espresso','double','دبل','Double',65,2),
('turkish-coffee','single','سنجل','Single',40,1),('turkish-coffee','double','دبل','Double',55,2),
('espresso-macchiato','single','سنجل','Single',55,1),('espresso-macchiato','double','دبل','Double',70,2),
('french-coffee','single','سنجل','Single',65,1),('french-coffee','double','دبل','Double',75,2),
('hazelnut-coffee','single','سنجل','Single',65,1),('hazelnut-coffee','double','دبل','Double',75,2)
)
INSERT INTO public.soft_opening_item_variants(item_id,key,name_ar,name_en,price,display_order)
SELECT i.id,v.key,v.name_ar,v.name_en,v.price,v.display_order FROM variants v JOIN public.soft_opening_items i ON i.slug=v.item_slug;

CREATE OR REPLACE FUNCTION public.create_soft_opening_order(
  _branch_id uuid,
  _items jsonb,
  _method_key text DEFAULT 'cash',
  _tendered numeric DEFAULT NULL,
  _notes text DEFAULT NULL,
  _discount_amount numeric DEFAULT 0,
  _discount_reason text DEFAULT NULL
) RETURNS TABLE(out_id uuid, out_number text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  _profile uuid := public.current_profile_id();
  _company uuid := public.current_company_id();
  _shift uuid; _order uuid; _number text; _seq int;
  _entry jsonb; _qty int; _price numeric; _name text; _size_name text; _line numeric;
  _item public.soft_opening_items; _variant public.soft_opening_item_variants;
  _subtotal numeric := 0; _discount numeric := round(GREATEST(COALESCE(_discount_amount,0),0),2); _total numeric;
  _key text := COALESCE(NULLIF(btrim(_method_key), ''), 'cash');
  _pm uuid;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('pos.create_order') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF NOT public.can_access_branch(_branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _items IS NULL OR jsonb_typeof(_items) <> 'array' OR jsonb_array_length(_items) = 0 THEN RAISE EXCEPTION 'Order has no items'; END IF;
  IF _key NOT IN ('cash','card') THEN RAISE EXCEPTION 'Unsupported payment method'; END IF;

  SELECT s.id INTO _shift FROM public.shifts s WHERE s.branch_id=_branch_id AND s.user_id=_profile AND s.status='open' LIMIT 1;
  IF _shift IS NULL THEN RAISE EXCEPTION 'No open shift'; END IF;

  INSERT INTO public.order_counters(branch_id,business_date,last_seq) VALUES(_branch_id,CURRENT_DATE,1)
  ON CONFLICT(branch_id,business_date) DO UPDATE SET last_seq=public.order_counters.last_seq+1 RETURNING last_seq INTO _seq;
  _number := 'SO-' || to_char(CURRENT_DATE,'YYMMDD') || '-' || lpad(_seq::text,4,'0');

  INSERT INTO public.orders(company_id,branch_id,shift_id,order_number,order_type,status,subtotal,discount_amount,discount_reason,tax_amount,total,notes,created_by,completed_at,is_soft_opening)
  VALUES(_company,_branch_id,_shift,_number,'takeaway','completed',0,0,NULL,0,0,_notes,_profile,now(),true) RETURNING id INTO _order;

  FOR _entry IN SELECT * FROM jsonb_array_elements(_items) LOOP
    _qty := COALESCE((_entry->>'quantity')::int,0);
    IF _qty <= 0 OR _qty > 99 THEN RAISE EXCEPTION 'Invalid quantity'; END IF;
    _size_name := NULL;
    IF NULLIF(_entry->>'item_id','') IS NOT NULL THEN
      SELECT * INTO _item FROM public.soft_opening_items WHERE id=(_entry->>'item_id')::uuid AND is_active;
      IF _item.id IS NULL THEN RAISE EXCEPTION 'Soft opening item unavailable'; END IF;
      _name := _item.name_ar || ' / ' || _item.name_en;
      _price := _item.price;
      IF NULLIF(_entry->>'variant_id','') IS NOT NULL THEN
        SELECT * INTO _variant FROM public.soft_opening_item_variants WHERE id=(_entry->>'variant_id')::uuid AND item_id=_item.id AND is_active;
        IF _variant.id IS NULL THEN RAISE EXCEPTION 'Soft opening size unavailable'; END IF;
        _price := _variant.price;
        _size_name := _variant.name_ar || ' / ' || _variant.name_en;
      ELSIF EXISTS (SELECT 1 FROM public.soft_opening_item_variants v WHERE v.item_id=_item.id AND v.is_active) THEN
        RAISE EXCEPTION 'Select a size';
      END IF;
    ELSE
      _name := NULLIF(btrim(COALESCE(_entry->>'name','')), '');
      _price := round(COALESCE((_entry->>'unit_price')::numeric,0),2);
      IF _name IS NULL OR char_length(_name) > 120 THEN RAISE EXCEPTION 'Invalid custom item name'; END IF;
      IF _price <= 0 OR _price > 100000 THEN RAISE EXCEPTION 'Invalid custom item price'; END IF;
    END IF;
    _line := round(_price*_qty,2); _subtotal := _subtotal+_line;
    INSERT INTO public.order_items(order_id,product_id,size_id,product_name,size_name,unit_price,base_price,modifiers_total,quantity,line_total,unit_cost,status)
    VALUES(_order,NULL,NULL,_name,_size_name,_price,_price,0,_qty,_line,0,'active');
  END LOOP;

  IF _subtotal <= 0 THEN RAISE EXCEPTION 'Order total must be positive'; END IF;
  IF _discount > _subtotal THEN RAISE EXCEPTION 'Discount exceeds subtotal'; END IF;
  IF _discount > 0 AND NOT (public.has_permission('pos.apply_discount') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized to discount'; END IF;
  IF _discount > 0 AND NULLIF(btrim(COALESCE(_discount_reason,'')),'') IS NULL THEN RAISE EXCEPTION 'Discount reason required'; END IF;
  _total := round(_subtotal-_discount,2);
  UPDATE public.orders SET subtotal=_subtotal,discount_amount=_discount,discount_reason=NULLIF(btrim(COALESCE(_discount_reason,'')),''),total=_total WHERE id=_order;

  SELECT pm.id INTO _pm FROM public.payment_methods pm WHERE pm.company_id=_company AND pm.key=_key AND pm.is_active LIMIT 1;
  INSERT INTO public.order_payments(order_id,payment_method_id,method_key,amount,created_by) VALUES(_order,_pm,_key,_total,_profile);
  PERFORM public.log_audit('SOFT_OPENING_SALE','pos','orders',_order,NULL,jsonb_build_object('order_id',_order,'order_number',_number,'subtotal',_subtotal,'discount',_discount,'total_amount',_total,'cashier_id',_profile,'method_key',_key,'tendered',_tendered,'items',jsonb_array_length(_items)),_discount_reason,_branch_id);
  RETURN QUERY SELECT _order,_number;
END $function$;
REVOKE ALL ON FUNCTION public.create_soft_opening_order(uuid,jsonb,text,numeric,text,numeric,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_soft_opening_order(uuid,jsonb,text,numeric,text,numeric,text) TO authenticated, service_role;