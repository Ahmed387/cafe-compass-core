-- Helper: master toggle state
CREATE OR REPLACE FUNCTION public.offers_enabled(_company_id uuid DEFAULT NULL)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE((
    SELECT (s.value->>'enabled')::boolean FROM public.app_settings s
    WHERE s.company_id = COALESCE(_company_id, public.current_company_id())
      AND s.scope = 'company' AND s.key = 'offers' AND s.branch_id IS NULL
    LIMIT 1
  ), true)
$$;

CREATE OR REPLACE FUNCTION public.set_offers_enabled(_enabled boolean)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _company uuid := public.current_company_id(); _old boolean;
BEGIN
  IF NOT (public.has_permission('settings.manage') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'غير مصرح لك بتغيير إعدادات العروض';
  END IF;
  _old := public.offers_enabled(_company);
  INSERT INTO public.app_settings (company_id, scope, key, value)
  VALUES (_company, 'company', 'offers', jsonb_build_object('enabled', _enabled))
  ON CONFLICT (company_id, scope, key, COALESCE(branch_id, '00000000-0000-0000-0000-000000000000'::uuid))
  DO UPDATE SET value = jsonb_build_object('enabled', _enabled), updated_at = now();

  PERFORM public.log_audit('offers.master_toggle','offers','app_settings',NULL,
    jsonb_build_object('enabled',_old), jsonb_build_object('enabled',_enabled));
  RETURN _enabled;
END $$;

-- Live cost + base price computation for a single item or a bundle payload
CREATE OR REPLACE FUNCTION public.offer_price_preview(_payload jsonb)
RETURNS TABLE(base_total numeric, live_cost numeric, safe_floor numeric,
              normal_profit numeric, normal_margin numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  _company uuid := public.current_company_id();
  _type text := COALESCE(_payload->>'offer_type','single');
  _items jsonb;
  _it jsonb; _p public.products; _s public.product_sizes;
  _qty int; _base numeric := 0; _cost numeric := 0;
BEGIN
  IF NOT (public.has_permission('products.view') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'غير مصرح';
  END IF;

  IF _type = 'bundle' THEN
    _items := COALESCE(_payload->'items','[]'::jsonb);
  ELSE
    _items := jsonb_build_array(jsonb_build_object(
      'product_id', _payload->>'product_id',
      'size_id', _payload->>'size_id',
      'quantity', COALESCE(_payload->>'quantity','1')));
  END IF;

  FOR _it IN SELECT * FROM jsonb_array_elements(_items) LOOP
    _qty := GREATEST(COALESCE((_it->>'quantity')::int, 1), 1);
    SELECT * INTO _p FROM public.products
     WHERE id = NULLIF(_it->>'product_id','')::uuid AND company_id = _company AND is_active;
    IF _p.id IS NULL THEN RAISE EXCEPTION 'منتج غير موجود أو غير نشط'; END IF;
    _s := NULL;
    IF NULLIF(_it->>'size_id','') IS NOT NULL THEN
      SELECT * INTO _s FROM public.product_sizes
       WHERE id = (_it->>'size_id')::uuid AND product_id = _p.id AND is_active;
    END IF;
    _base := _base + (_p.base_price + COALESCE(_s.price_delta,0)) * _qty;
    _cost := _cost + COALESCE(_p.cost,0) * _qty;
  END LOOP;

  RETURN QUERY SELECT round(_base,2), round(_cost,2), round(_cost * 1.25, 2),
    round(_base - _cost, 2),
    CASE WHEN _base > 0 THEN round(((_base - _cost) / _base) * 100, 2) ELSE 0 END;
END $$;

-- Unified INSERT/UPDATE with live DB cost floor
CREATE OR REPLACE FUNCTION public.save_product_offer(_payload jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  _company uuid := public.current_company_id();
  _profile uuid := public.current_profile_id();
  _id uuid := NULLIF(_payload->>'id','')::uuid;
  _type text := COALESCE(_payload->>'offer_type','single');
  _product uuid := NULLIF(_payload->>'product_id','')::uuid;
  _items jsonb := COALESCE(_payload->'items','[]'::jsonb);
  _price numeric := ROUND(COALESCE((_payload->>'offer_price')::numeric, 0), 2);
  _starts date := COALESCE(NULLIF(_payload->>'starts_at','')::date, CURRENT_DATE);
  _ends date := NULLIF(_payload->>'ends_at','')::date;
  _title text := NULLIF(btrim(COALESCE(_payload->>'title','')),'');
  _preview record; _old jsonb; _it jsonb; _clash int; _pid uuid;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'غير مسجل الدخول'; END IF;
  IF NOT (public.has_permission('products.update') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'غير مصرح لك بإدارة العروض';
  END IF;
  IF _title IS NULL THEN RAISE EXCEPTION 'عنوان العرض مطلوب'; END IF;
  IF _type NOT IN ('single','bundle') THEN RAISE EXCEPTION 'نوع عرض غير صحيح'; END IF;
  IF _type = 'single' AND _product IS NULL THEN RAISE EXCEPTION 'اختر المنتج أولًا'; END IF;
  IF _type = 'bundle' AND jsonb_array_length(_items) < 2 THEN
    RAISE EXCEPTION 'الباقة تحتاج صنفين على الأقل';
  END IF;
  IF _ends IS NOT NULL AND _ends < _starts THEN RAISE EXCEPTION 'تاريخ النهاية قبل البداية'; END IF;

  -- Live cost floor: computed here from products.cost, never trusted from the client.
  SELECT * INTO _preview FROM public.offer_price_preview(
    jsonb_build_object('offer_type',_type,'product_id',_product,
      'size_id',_payload->>'size_id','quantity',COALESCE(_payload->>'quantity','1'),'items',_items));

  IF _price <= 0 THEN RAISE EXCEPTION 'سعر العرض يجب أن يكون أكبر من صفر'; END IF;
  IF _price < _preview.safe_floor THEN
    RAISE EXCEPTION 'ممنوع الحفظ: السعر المقترح (%) يقل عن هامش الأمان 25%% — الحد الأدنى الآمن هو % ج.م',
      to_char(_price,'FM999999990.00'), to_char(_preview.safe_floor,'FM999999990.00');
  END IF;

  -- Overlapping active offers on the same product are rejected
  FOR _pid IN
    SELECT CASE WHEN _type = 'single' THEN _product
                ELSE NULLIF(x->>'product_id','')::uuid END
    FROM (SELECT CASE WHEN _type='single' THEN jsonb_build_array('{}'::jsonb) ELSE _items END AS arr) s
    CROSS JOIN LATERAL jsonb_array_elements(s.arr) x
  LOOP
    IF _pid IS NULL THEN CONTINUE; END IF;
    SELECT count(*) INTO _clash
    FROM public.product_offers po
    LEFT JOIN public.offer_bundle_items bi ON bi.offer_id = po.id
    WHERE po.company_id = _company AND po.is_active
      AND (_id IS NULL OR po.id <> _id)
      AND COALESCE(po.product_id, bi.product_id) = _pid
      AND po.starts_at <= COALESCE(_ends, 'infinity'::date)
      AND COALESCE(po.ends_at, 'infinity'::date) >= _starts;
    IF _clash > 0 THEN
      RAISE EXCEPTION 'يوجد عرض نشط آخر على نفس الصنف في فترة متقاطعة';
    END IF;
  END LOOP;

  IF _id IS NULL THEN
    INSERT INTO public.product_offers (company_id, product_id, offer_type, title, offer_price,
      base_price_snapshot, unit_cost_snapshot, double_points, starts_at, ends_at, is_active,
      notes, image_path, created_by)
    VALUES (_company, CASE WHEN _type='single' THEN _product ELSE NULL END, _type, _title, _price,
      _preview.base_total, _preview.live_cost, COALESCE((_payload->>'double_points')::boolean,false),
      _starts, _ends, true, NULLIF(btrim(COALESCE(_payload->>'notes','')),''),
      NULLIF(btrim(COALESCE(_payload->>'image_path','')),''), _profile)
    RETURNING id INTO _id;
    PERFORM public.log_audit('offer.create','offers','product_offers',_id,NULL,
      jsonb_build_object('title',_title,'type',_type,'offer_price',_price,
        'base_total',_preview.base_total,'live_cost',_preview.live_cost,'items',_items));
  ELSE
    SELECT to_jsonb(po) INTO _old FROM public.product_offers po
     WHERE po.id = _id AND po.company_id = _company;
    IF _old IS NULL THEN RAISE EXCEPTION 'العرض غير موجود'; END IF;
    UPDATE public.product_offers SET
      product_id = CASE WHEN _type='single' THEN _product ELSE NULL END,
      offer_type = _type, title = _title, offer_price = _price,
      base_price_snapshot = _preview.base_total, unit_cost_snapshot = _preview.live_cost,
      double_points = COALESCE((_payload->>'double_points')::boolean,false),
      starts_at = _starts, ends_at = _ends,
      notes = NULLIF(btrim(COALESCE(_payload->>'notes','')),''),
      image_path = NULLIF(btrim(COALESCE(_payload->>'image_path','')),''),
      updated_at = now()
    WHERE id = _id;
    PERFORM public.log_audit('offer.update','offers','product_offers',_id,_old,
      jsonb_build_object('title',_title,'type',_type,'offer_price',_price,
        'base_total',_preview.base_total,'live_cost',_preview.live_cost,'items',_items));
  END IF;

  DELETE FROM public.offer_bundle_items WHERE offer_id = _id;
  IF _type = 'bundle' THEN
    FOR _it IN SELECT * FROM jsonb_array_elements(_items) LOOP
      INSERT INTO public.offer_bundle_items (offer_id, product_id, size_id, quantity)
      VALUES (_id, (_it->>'product_id')::uuid, NULLIF(_it->>'size_id','')::uuid,
        GREATEST(COALESCE((_it->>'quantity')::int,1),1));
    END LOOP;
  END IF;

  RETURN _id;
END $$;

CREATE OR REPLACE FUNCTION public.set_offer_active(_offer_id uuid, _active boolean, _reason text DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _old jsonb;
BEGIN
  IF NOT (public.has_permission('products.update') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'غير مصرح لك بإدارة العروض';
  END IF;
  SELECT to_jsonb(po) INTO _old FROM public.product_offers po
   WHERE po.id = _offer_id AND po.company_id = public.current_company_id();
  IF _old IS NULL THEN RAISE EXCEPTION 'العرض غير موجود'; END IF;
  UPDATE public.product_offers SET is_active = _active, updated_at = now() WHERE id = _offer_id;
  PERFORM public.log_audit(CASE WHEN _active THEN 'offer.activate' ELSE 'offer.deactivate' END,
    'offers','product_offers',_offer_id,_old,jsonb_build_object('is_active',_active),_reason);
  RETURN _active;
END $$;

-- Offers performance & ROI, driven by order_items.offer_id (no text parsing)
CREATE OR REPLACE FUNCTION public.offers_performance(_from date DEFAULT (CURRENT_DATE - 30), _to date DEFAULT CURRENT_DATE)
RETURNS TABLE(offer_id uuid, title text, offer_type text, offer_price numeric,
              times_sold bigint, revenue numeric, cogs numeric, net_profit numeric,
              margin_pct numeric, discount_given numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT po.id, po.title, po.offer_type, po.offer_price,
         COUNT(DISTINCT COALESCE(oi.bundle_key, oi.id::text)) AS times_sold,
         COALESCE(SUM(oi.line_total),0) AS revenue,
         COALESCE(SUM(oi.unit_cost * oi.quantity),0) AS cogs,
         COALESCE(SUM(oi.line_total - oi.unit_cost * oi.quantity),0) AS net_profit,
         CASE WHEN COALESCE(SUM(oi.line_total),0) > 0
              THEN ROUND(COALESCE(SUM(oi.line_total - oi.unit_cost * oi.quantity),0)
                         / SUM(oi.line_total) * 100, 2) ELSE 0 END AS margin_pct,
         COALESCE(SUM((oi.base_price - oi.unit_price) * oi.quantity),0) AS discount_given
  FROM public.product_offers po
  LEFT JOIN public.order_items oi ON oi.offer_id = po.id AND oi.status = 'active'
  LEFT JOIN public.orders o ON o.id = oi.order_id
    AND o.status IN ('pending','completed','refunded','partially_refunded')
    AND o.created_at::date BETWEEN _from AND _to
  WHERE po.company_id = public.current_company_id()
    AND (public.has_permission('reports.view') OR public.has_permission('analytics.view') OR public.is_super_admin())
  GROUP BY po.id, po.title, po.offer_type, po.offer_price
  ORDER BY revenue DESC
$$;

-- Saving offers is now RPC-only
DROP POLICY IF EXISTS "offers_insert" ON public.product_offers;
DROP POLICY IF EXISTS "offers_update" ON public.product_offers;