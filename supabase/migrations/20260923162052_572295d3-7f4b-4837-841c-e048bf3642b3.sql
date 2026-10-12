ALTER TABLE public.soft_opening_items ADD COLUMN IF NOT EXISTS serve_type text NOT NULL DEFAULT 'none' CHECK (serve_type IN ('cold','hot','none'));

CREATE TABLE public.soft_opening_item_addons (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  item_id uuid NOT NULL REFERENCES public.soft_opening_items(id) ON DELETE CASCADE,
  key text NOT NULL,
  name_ar text NOT NULL,
  name_en text NOT NULL,
  price numeric(10,2) NOT NULL DEFAULT 0 CHECK (price >= 0),
  display_order int NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(item_id, key)
);
GRANT SELECT ON public.soft_opening_item_addons TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.soft_opening_item_addons TO authenticated;
GRANT ALL ON public.soft_opening_item_addons TO service_role;
ALTER TABLE public.soft_opening_item_addons ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Public can view active addons" ON public.soft_opening_item_addons FOR SELECT TO anon USING (is_active);
CREATE POLICY "Staff can view addons" ON public.soft_opening_item_addons FOR SELECT TO authenticated USING (true);
CREATE POLICY "Product managers can create addons" ON public.soft_opening_item_addons FOR INSERT TO authenticated WITH CHECK (public.is_super_admin() OR public.has_permission('products.create'));
CREATE POLICY "Product managers can update addons" ON public.soft_opening_item_addons FOR UPDATE TO authenticated USING (public.is_super_admin() OR public.has_permission('products.update')) WITH CHECK (public.is_super_admin() OR public.has_permission('products.update'));
CREATE POLICY "Product managers can delete addons" ON public.soft_opening_item_addons FOR DELETE TO authenticated USING (public.is_super_admin() OR public.has_permission('products.delete'));
CREATE TRIGGER soft_opening_item_addons_updated_at BEFORE UPDATE ON public.soft_opening_item_addons FOR EACH ROW EXECUTE FUNCTION public.set_soft_opening_updated_at();

INSERT INTO public.soft_opening_categories(slug,name_ar,name_en,display_order,is_active)
VALUES ('matcha','ماتشا','Matcha',12,true) ON CONFLICT (slug) DO NOTHING;
UPDATE public.soft_opening_categories SET name_ar='بار القهوة المختصة', name_en='Specialty Coffee Bar' WHERE slug='v60';
UPDATE public.soft_opening_categories SET name_ar='قهوة ساخنة وإسبريسو بار', name_en='Hot Coffee & Espresso Bar' WHERE slug='hot-coffee';
UPDATE public.soft_opening_categories SET name_ar='فرابيه وفرابتشينو', name_en='Frappe & Frappuccino' WHERE slug='frappe';
UPDATE public.soft_opening_categories SET name_ar='حلويات ووافل وبان كيك', name_en='Desserts, Waffles & Pancakes' WHERE slug='desserts-waffles';
UPDATE public.soft_opening_categories SET name_ar='سموذي', name_en='Smoothies' WHERE slug='smoothies';

WITH v(cat,slug,name_en,name_ar,price,serve,ord) AS (VALUES
 ('desserts-waffles','nutella-waffle','Nutella Waffle','وافل نوتيلا',130,'none',101),
 ('desserts-waffles','lotus-waffle','Lotus Waffle','وافل لوتس',165,'none',102),
 ('desserts-waffles','pistachio-waffle','Pistachio Waffle','وافل بستاشيو',175,'none',103),
 ('desserts-waffles','choose-your-waffle','Choose Your Waffle','وافل على ذوقك',160,'none',104),
 ('desserts-waffles','mini-pancakes','Mini Pancakes (12 pcs)','ميني بان كيك (12 قطعة)',100,'none',105),
 ('desserts-waffles','red-velvet','Red Velvet','ريد فيلفيت',100,'none',106),
 ('desserts-waffles','cheesecake','Cheesecake','تشيز كيك',100,'none',107),
 ('desserts-waffles','nutella-molten-cake','Nutella Molten Cake','مولتن كيك نوتيلا',105,'none',108),
 ('desserts-waffles','cookies','Cookies','كوكيز',40,'none',109),
 ('desserts-waffles','lotus-molten-cake','Lotus Molten Cake','مولتن كيك لوتس',110,'none',110),
 ('hot-coffee','espresso-affogato','Espresso Affogato','إسبريسو أفوجاتو',100,'none',101),
 ('hot-coffee','caramel-macchiato-double','Caramel Macchiato (Double)','كراميل ماكياتو دبل',120,'hot',102),
 ('hot-coffee','piccolo','Piccolo','بيكولو',85,'hot',103),
 ('iced-coffee','dirty-espresso','Dirty Espresso','ديرتي إسبريسو',125,'cold',101),
 ('iced-coffee','iced-latte-vanilla-cold-foam','Iced Latte Vanilla Cold Foam','آيس لاتيه فانيليا كولد فوم',120,'cold',102),
 ('iced-coffee','iced-latte-salted-caramel-cold-foam','Iced Latte Salted Caramel Cold Foam','آيس لاتيه سولتد كراميل كولد فوم',120,'cold',103),
 ('iced-coffee','blackberry-cold-foam','Blackberry Cold Foam','بلاك بيري كولد فوم',130,'cold',104),
 ('iced-coffee','coconut-cold-foam','Coconut Cold Foam','كوكونت كولد فوم',125,'cold',105),
 ('frappe','classic-frappe','Classic Frappe','كلاسيك فرابيه',120,'cold',101),
 ('frappe','salted-caramel-frappe','Salted Caramel Frappe','سولتد كراميل فرابيه',120,'cold',102),
 ('frappe','cookies-frappe','Cookies Frappe','كوكيز فرابيه',130,'cold',103),
 ('frappe','coconut-frappe','Coconut Frappe','كوكونت فرابيه',120,'cold',104),
 ('frappe','classic-frappuccino','Classic Frappuccino','كلاسيك فرابتشينو',130,'cold',105),
 ('frappe','salted-caramel-frappuccino','Salted Caramel Frappuccino','سولتد كراميل فرابتشينو',130,'cold',106),
 ('frappe','cookies-frappuccino','Cookies Frappuccino','كوكيز فرابتشينو',140,'cold',107),
 ('frappe','coconut-frappuccino','Coconut Frappuccino','كوكونت فرابتشينو',130,'cold',108),
 ('milkshake','lotus-milkshake','Lotus Milkshake','ميلك شيك لوتس',120,'cold',101),
 ('milkshake','vanilla-milkshake','Vanilla Milkshake','ميلك شيك فانيليا',110,'cold',102),
 ('milkshake','chocolate-milkshake','Chocolate Milkshake','ميلك شيك شوكولاتة',120,'cold',103),
 ('milkshake','oreo-milkshake','Oreo Milkshake','ميلك شيك أوريو',100,'cold',104),
 ('milkshake','pistachio-milkshake','Pistachio Milkshake','ميلك شيك بستاشيو',115,'cold',105),
 ('milkshake','caramel-milkshake','Caramel Milkshake','ميلك شيك كراميل',105,'cold',106),
 ('smoothies','watermelon-smoothie','Watermelon Smoothie','سموذي بطيخ',95,'cold',101),
 ('smoothies','cantaloupe-smoothie','Cantaloupe Smoothie','سموذي كانتالوب',80,'cold',102),
 ('smoothies','peach-smoothie','Peach Smoothie','سموذي خوخ',100,'cold',103),
 ('smoothies','strawberry-smoothie','Strawberry Smoothie','سموذي فراولة',100,'cold',104),
 ('smoothies','blueberry-smoothie','Blueberry Smoothie','سموذي توت أزرق',105,'cold',105),
 ('smoothies','passion-fruit-smoothie','Passion Fruit Smoothie','سموذي باشن فروت',100,'cold',106),
 ('smoothies','pina-colada-smoothie','Pina Colada Smoothie','سموذي بينا كولادا',115,'cold',107),
 ('smoothies','kiwi-smoothie','Kiwi Smoothie','سموذي كيوي',125,'cold',108),
 ('fresh-juices','cantaloupe-juice','Cantaloupe Juice','عصير كانتالوب',65,'cold',101),
 ('fresh-juices','guava-juice','Guava Juice','عصير جوافة',85,'cold',102),
 ('fresh-juices','watermelon-juice','Watermelon Juice','عصير بطيخ',85,'cold',103),
 ('fresh-juices','strawberry-juice','Strawberry Juice','عصير فراولة',85,'cold',104),
 ('fresh-juices','orange-juice','Orange Juice','عصير برتقال',85,'cold',105),
 ('fresh-juices','banana-milk','Banana Milk','موز باللبن',85,'cold',106),
 ('fresh-juices','kiwi-juice','Kiwi Juice','عصير كيوي',100,'cold',107),
 ('fresh-juices','pineapple-juice','Pineapple Juice','عصير أناناس',100,'cold',108),
 ('fresh-juices','peach-juice','Peach Juice','عصير خوخ',90,'cold',109),
 ('fresh-juices','fresh-lemon','Lemon Juice','عصير ليمون',65,'cold',110),
 ('fresh-juices','lemon-mint','Lemon Mint','ليمون نعناع',65,'cold',111),
 ('fresh-juices','fresh-avocado','Avocado Juice','عصير أفوكادو',120,'cold',112),
 ('mojitos-sodas','classic-mojito','Classic Mojito','موهيتو كلاسيك',90,'cold',101),
 ('mojitos-sodas','blue-mojito','Blue Mojito','بلو موهيتو',90,'cold',102),
 ('mojitos-sodas','blueberry-mojito','Blueberry Mojito','موهيتو توت أزرق',110,'cold',103),
 ('mojitos-sodas','passion-fruit-mojito','Passion Mojito','موهيتو باشن',110,'cold',104),
 ('mojitos-sodas','strawberry-mojito','Strawberry Mojito','موهيتو فراولة',110,'cold',105),
 ('mojitos-sodas','pineapple-mojito','Pineapple Mojito','موهيتو أناناس',110,'cold',106),
 ('mojitos-sodas','pineapple-kiwi-mojito','Pineapple Kiwi Mojito','موهيتو أناناس كيوي',120,'cold',107),
 ('mojitos-sodas','passion-kiwi-mojito','Passion Kiwi Mojito','موهيتو باشن كيوي',120,'cold',108),
 ('mojitos-sodas','red-bull-mojito','Red Bull Mojito','موهيتو ريد بول',125,'cold',109),
 ('matcha','classic-matcha','Classic Matcha','ماتشا كلاسيك',110,'cold',1),
 ('matcha','pistachio-matcha','Pistachio Matcha','ماتشا بستاشيو',150,'cold',2),
 ('matcha','spanish-matcha','Spanish Matcha','سبانش ماتشا',120,'cold',3),
 ('matcha','vanilla-heavy-cream-matcha','Vanilla Heavy Cream Matcha','ماتشا فانيليا هيفي كريم',140,'cold',4),
 ('matcha','strawberry-matcha','Strawberry Matcha','ماتشا فراولة',130,'cold',5),
 ('matcha','coconut-matcha','Coconut Matcha','ماتشا كوكونت',130,'cold',6),
 ('matcha','blueberry-matcha','Blueberry Matcha','ماتشا توت أزرق',130,'cold',7),
 ('matcha','hot-matcha','Hot Matcha','ماتشا ساخن',110,'hot',8),
 ('v60','v60-chemex','V60 / Chemex','V60 / كيمكس',140,'hot',101),
 ('v60','sweet-v60-chemex','Sweet V60 / Chemex','سويت V60 / كيمكس',180,'hot',102),
 ('v60','cold-brew','Cold Brew','كولد برو',110,'cold',103)
)
INSERT INTO public.soft_opening_items(category_id,slug,name_ar,name_en,price,image_key,display_order,is_active,serve_type)
SELECT c.id,v.slug,v.name_ar,v.name_en,v.price,v.slug,v.ord,true,v.serve FROM v JOIN public.soft_opening_categories c ON c.slug=v.cat
ON CONFLICT (slug) DO UPDATE SET category_id=EXCLUDED.category_id,name_ar=EXCLUDED.name_ar,name_en=EXCLUDED.name_en,price=EXCLUDED.price,serve_type=EXCLUDED.serve_type,is_active=true;

UPDATE public.soft_opening_items i SET serve_type='cold' FROM public.soft_opening_categories c WHERE c.id=i.category_id AND i.serve_type='none' AND c.slug IN ('iced-coffee','frappe','milkshake','smoothies','fresh-juices','mojitos-sodas');
UPDATE public.soft_opening_items i SET serve_type='hot' FROM public.soft_opening_categories c WHERE c.id=i.category_id AND i.serve_type='none' AND c.slug IN ('hot-coffee','tea-herbs') AND i.slug <> 'espresso-affogato';
UPDATE public.soft_opening_items SET serve_type='none' WHERE slug IN ('mineral-water','pepsi','seven-up','red-bull');
UPDATE public.soft_opening_items SET is_active=false WHERE slug IN ('v60-ethiopian','v60-yemeni','v60-colombian');

WITH v(item,key,name_ar,name_en,price,ord) AS (VALUES
 ('v60-chemex','colombian','كولومبي','Colombian',140,1),('v60-chemex','ethiopian','إثيوبي','Ethiopian',160,2),('v60-chemex','yemeni','يمني','Yemeni',200,3),
 ('sweet-v60-chemex','passion','باشن','Passion',180,1),('sweet-v60-chemex','blackberry','بلاك بيري','Blackberry',180,2),('sweet-v60-chemex','coconut','كوكونت','Coconut',180,3),('sweet-v60-chemex','hazelnut','بندق','Hazelnut',180,4),
 ('cold-brew','vanilla','فانيليا','Vanilla',110,1),('cold-brew','salted-caramel','سولتد كراميل','Salted Caramel',110,2),('cold-brew','caramel','كراميل','Caramel',110,3),('cold-brew','coconut','كوكونت','Coconut',110,4),('cold-brew','brown-sugar','براون شوجر','Brown Sugar',110,5)
)
INSERT INTO public.soft_opening_item_variants(item_id,key,name_ar,name_en,price,display_order)
SELECT i.id,v.key,v.name_ar,v.name_en,v.price,v.ord FROM v JOIN public.soft_opening_items i ON i.slug=v.item
ON CONFLICT (item_id,key) DO UPDATE SET name_ar=EXCLUDED.name_ar,name_en=EXCLUDED.name_en,price=EXCLUDED.price,is_active=true;

WITH v(item,key,name_ar,name_en,price) AS (VALUES
 ('v60-chemex','cream-top','كريمة على الوجه','Cream Top',25),('sweet-v60-chemex','cream-top','كريمة على الوجه','Cream Top',25),
 ('cold-brew','cold-foam','كولد فوم','Cold Foam',20),
 ('nutella-waffle','fruits','إضافة فواكه','Add Fruits',20),('lotus-waffle','fruits','إضافة فواكه','Add Fruits',20),('pistachio-waffle','fruits','إضافة فواكه','Add Fruits',20),('choose-your-waffle','fruits','إضافة فواكه','Add Fruits',20),('mini-pancakes','fruits','إضافة فواكه','Add Fruits',20)
)
INSERT INTO public.soft_opening_item_addons(item_id,key,name_ar,name_en,price)
SELECT i.id,v.key,v.name_ar,v.name_en,v.price FROM v JOIN public.soft_opening_items i ON i.slug=v.item
ON CONFLICT (item_id,key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.create_soft_opening_order(
  _branch_id uuid, _items jsonb, _method_key text DEFAULT 'cash', _tendered numeric DEFAULT NULL,
  _notes text DEFAULT NULL, _discount_amount numeric DEFAULT 0, _discount_reason text DEFAULT NULL
) RETURNS TABLE(out_id uuid, out_number text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  _profile uuid := public.current_profile_id();
  _company uuid := public.current_company_id();
  _shift uuid; _order uuid; _number text; _seq int;
  _entry jsonb; _qty int; _price numeric; _base numeric; _mods numeric; _name text; _size_name text; _line numeric;
  _item public.soft_opening_items; _variant public.soft_opening_item_variants; _addon public.soft_opening_item_addons;
  _extras text[]; _aid text;
  _subtotal numeric := 0; _discount numeric := round(GREATEST(COALESCE(_discount_amount,0),0),2); _total numeric;
  _key text := COALESCE(NULLIF(btrim(_method_key), ''), 'cash');
  _pm uuid; _clean_notes text := NULLIF(left(btrim(COALESCE(_notes,'')),500),'');
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
  _number := '20S-' || to_char(CURRENT_DATE,'YYMMDD') || '-' || lpad(_seq::text,4,'0');

  INSERT INTO public.orders(company_id,branch_id,shift_id,order_number,order_type,status,subtotal,discount_amount,discount_reason,tax_amount,total,notes,created_by,completed_at,is_soft_opening)
  VALUES(_company,_branch_id,_shift,_number,'takeaway','completed',0,0,NULL,0,0,_clean_notes,_profile,now(),true) RETURNING id INTO _order;

  FOR _entry IN SELECT * FROM jsonb_array_elements(_items) LOOP
    _qty := COALESCE((_entry->>'quantity')::int,0);
    IF _qty <= 0 OR _qty > 99 THEN RAISE EXCEPTION 'Invalid quantity'; END IF;
    _size_name := NULL; _mods := 0; _extras := ARRAY[]::text[];
    IF NULLIF(_entry->>'item_id','') IS NOT NULL THEN
      SELECT * INTO _item FROM public.soft_opening_items WHERE id=(_entry->>'item_id')::uuid AND is_active;
      IF _item.id IS NULL THEN RAISE EXCEPTION 'Menu item unavailable'; END IF;
      _name := _item.name_ar || ' / ' || _item.name_en;
      _base := _item.price;
      IF NULLIF(_entry->>'variant_id','') IS NOT NULL THEN
        SELECT * INTO _variant FROM public.soft_opening_item_variants WHERE id=(_entry->>'variant_id')::uuid AND item_id=_item.id AND is_active;
        IF _variant.id IS NULL THEN RAISE EXCEPTION 'Option unavailable'; END IF;
        _base := _variant.price;
        _size_name := _variant.name_ar || ' / ' || _variant.name_en;
      ELSIF EXISTS (SELECT 1 FROM public.soft_opening_item_variants v WHERE v.item_id=_item.id AND v.is_active) THEN
        RAISE EXCEPTION 'Select an option';
      END IF;
      IF jsonb_typeof(_entry->'addon_ids') = 'array' THEN
        FOR _aid IN SELECT jsonb_array_elements_text(_entry->'addon_ids') LOOP
          SELECT * INTO _addon FROM public.soft_opening_item_addons WHERE id=_aid::uuid AND item_id=_item.id AND is_active;
          IF _addon.id IS NULL THEN RAISE EXCEPTION 'Add-on unavailable'; END IF;
          _mods := _mods + _addon.price; _extras := _extras || (_addon.name_en || ' +' || _addon.price::int);
        END LOOP;
      END IF;
      IF COALESCE((_entry->>'in_can')::boolean,false) THEN
        IF _item.serve_type <> 'cold' THEN RAISE EXCEPTION 'Can serving is only for cold drinks'; END IF;
        _mods := _mods + 30; _extras := _extras || 'CAN +30'::text;
      END IF;
      IF array_length(_extras,1) > 0 THEN
        _size_name := concat_ws(' · ', _size_name, array_to_string(_extras, ' · '));
      END IF;
    ELSE
      _name := NULLIF(btrim(COALESCE(_entry->>'name','')), '');
      _base := round(COALESCE((_entry->>'unit_price')::numeric,0),2);
      IF _name IS NULL OR char_length(_name) > 120 THEN RAISE EXCEPTION 'Invalid custom item name'; END IF;
      IF _base <= 0 OR _base > 100000 THEN RAISE EXCEPTION 'Invalid custom item price'; END IF;
    END IF;
    _price := _base + _mods;
    _line := round(_price*_qty,2); _subtotal := _subtotal+_line;
    INSERT INTO public.order_items(order_id,product_id,size_id,product_name,size_name,unit_price,base_price,modifiers_total,quantity,line_total,unit_cost,status)
    VALUES(_order,NULL,NULL,_name,_size_name,_price,_base,_mods,_qty,_line,0,'active');
  END LOOP;

  IF _subtotal <= 0 THEN RAISE EXCEPTION 'Order total must be positive'; END IF;
  IF _discount > _subtotal THEN RAISE EXCEPTION 'Discount exceeds subtotal'; END IF;
  IF _discount > 0 AND NOT (public.has_permission('pos.apply_discount') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized to discount'; END IF;
  IF _discount > 0 AND NULLIF(btrim(COALESCE(_discount_reason,'')),'') IS NULL THEN RAISE EXCEPTION 'Discount reason required'; END IF;
  _total := round(_subtotal-_discount,2);
  UPDATE public.orders SET subtotal=_subtotal,discount_amount=_discount,discount_reason=NULLIF(btrim(COALESCE(_discount_reason,'')),''),total=_total WHERE id=_order;

  SELECT pm.id INTO _pm FROM public.payment_methods pm WHERE pm.company_id=_company AND pm.key=_key AND pm.is_active LIMIT 1;
  INSERT INTO public.order_payments(order_id,payment_method_id,method_key,amount,created_by) VALUES(_order,_pm,_key,_total,_profile);
  PERFORM public.log_audit('SOFT_OPENING_SALE','pos','orders',_order,NULL,jsonb_build_object('order_id',_order,'order_number',_number,'subtotal',_subtotal,'discount',_discount,'total_amount',_total,'cashier_id',_profile,'method_key',_key,'tendered',_tendered,'items',jsonb_array_length(_items),'notes',_clean_notes),_discount_reason,_branch_id);
  RETURN QUERY SELECT _order,_number;
END $function$;
REVOKE ALL ON FUNCTION public.create_soft_opening_order(uuid,jsonb,text,numeric,text,numeric,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_soft_opening_order(uuid,jsonb,text,numeric,text,numeric,text) TO authenticated, service_role;