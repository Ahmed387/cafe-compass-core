CREATE OR REPLACE FUNCTION public.is_can_eligible_product(_category_id uuid, _name text)
RETURNS boolean LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.categories c WHERE c.id = _category_id AND (
      upper(c.name) IN ('ICE COFFEE','ICED COFFEE','FRAPPEE','FRAPPE','FRAPPUCCINO','MILKSHAKE','SMOOTHIE','MOJITO','FRESH JUICE','FRESH JUICES','COLD MATCHA')
      OR (upper(c.name) = 'MATCHA' AND (_name ILIKE '%iced%' OR _name ILIKE '%ice %' OR _name ILIKE '%cold%' OR _name ILIKE '%مثلج%' OR _name ILIKE '%ايس%' OR _name ILIKE '%آيس%'))
    ))
$$;

CREATE OR REPLACE FUNCTION public.auto_link_can_group()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE g uuid;
BEGIN
  SELECT id INTO g FROM public.modifier_groups WHERE name = 'Serve in Can' AND company_id = NEW.company_id LIMIT 1;
  IF g IS NOT NULL AND public.is_can_eligible_product(NEW.category_id, NEW.name) THEN
    INSERT INTO public.product_modifier_groups(product_id, group_id) VALUES (NEW.id, g) ON CONFLICT DO NOTHING;
  END IF;
  RETURN NEW;
END $$;
REVOKE EXECUTE ON FUNCTION public.auto_link_can_group() FROM anon, public, authenticated;

DROP TRIGGER IF EXISTS trg_auto_link_can_group ON public.products;
CREATE TRIGGER trg_auto_link_can_group AFTER INSERT OR UPDATE OF category_id, name ON public.products
FOR EACH ROW EXECUTE FUNCTION public.auto_link_can_group();

INSERT INTO public.product_modifier_groups(product_id, group_id)
SELECT p.id, g.id FROM public.products p JOIN public.modifier_groups g ON g.company_id = p.company_id AND g.name = 'Serve in Can'
WHERE public.is_can_eligible_product(p.category_id, p.name)
ON CONFLICT DO NOTHING;

-- Partial refunds: status + reports
DO $$
DECLARE d text;
BEGIN
  d := pg_get_functiondef('public.refund_order(uuid,numeric,text,text)'::regprocedure);
  d := replace(d, $q$IF _o.status <> 'completed' THEN RAISE EXCEPTION 'Only completed orders can be refunded'; END IF;$q$,
                  $q$IF _o.status NOT IN ('completed','partially_refunded') THEN RAISE EXCEPTION 'Only completed orders can be refunded'; END IF;$q$);
  d := replace(d, $q$    UPDATE public.orders SET status = 'refunded', updated_at = now() WHERE id = _order_id;
  END IF;$q$, $q$    UPDATE public.orders SET status = 'refunded', updated_at = now() WHERE id = _order_id;
  ELSE
    UPDATE public.orders SET status = 'partially_refunded', updated_at = now() WHERE id = _order_id;
  END IF;$q$);
  IF d !~ 'partially_refunded'', updated_at' THEN RAISE EXCEPTION 'refund_order patch failed'; END IF;
  EXECUTE d;

  d := pg_get_functiondef('public.monthly_operating_costs(date,date)'::regprocedure);
  d := replace(d, $q$o.status IN ('completed','refunded')$q$, $q$o.status IN ('completed','refunded','partially_refunded')$q$);
  d := replace(d, $q$o.status = 'completed' AND oi.status = 'active'$q$, $q$o.status IN ('completed','partially_refunded') AND oi.status = 'active'$q$);
  EXECUTE d;

  d := pg_get_functiondef('public.product_demand(date,date)'::regprocedure);
  d := replace(d, $q$o.status IN ('completed','refunded')$q$, $q$o.status IN ('completed','refunded','partially_refunded')$q$);
  EXECUTE d;
END $$;

UPDATE public.orders o SET status = 'partially_refunded', updated_at = now()
WHERE o.status = 'completed' AND EXISTS (SELECT 1 FROM public.order_refunds r WHERE r.order_id = o.id AND r.status = 'active');