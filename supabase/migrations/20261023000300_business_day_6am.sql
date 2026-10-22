-- The café's business day runs from 06:00 to 06:00 Cairo time: a bill at
-- 01:30 belongs to the day before. Every "today" in the database now comes
-- from that day instead of the server's UTC date.

CREATE OR REPLACE FUNCTION public.business_day_start_hour()
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$ SELECT 6 $function$;

CREATE OR REPLACE FUNCTION public.business_date(_ts timestamp with time zone, _company uuid DEFAULT NULL::uuid)
 RETURNS date
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT ((_ts AT TIME ZONE public.company_tz(_company)) - make_interval(hours => public.business_day_start_hour()))::date
$function$;

CREATE OR REPLACE FUNCTION public.business_day_start(_day date, _company uuid DEFAULT NULL::uuid)
 RETURNS timestamp with time zone
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT ((_day::timestamp + make_interval(hours => public.business_day_start_hour())) AT TIME ZONE public.company_tz(_company))
$function$;

-- Replace the server's UTC date with the business day in every function
-- that used it (bodies and parameter defaults).
DO $$
DECLARE _f record; _def text;
BEGIN
  FOR _f IN
    SELECT p.oid, pg_get_functiondef(p.oid) AS def
      FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'
       AND p.proname NOT IN ('business_today', 'business_date', 'business_day_start')
       AND pg_get_functiondef(p.oid) ~* '\mcurrent_date\M'
  LOOP
    _def := regexp_replace(_f.def, '\mcurrent_date\M', 'public.business_today()', 'gi');
    EXECUTE _def;
  END LOOP;
END $$;

-- Profit distribution: the super admin picks any finished period (even one
-- month). The "3 profitable months in a row" lock is gone; the figure stays
-- in 'sustainability' for information.
DO $$
DECLARE _def text;
BEGIN
  _def := pg_get_functiondef('public._payout_calc(uuid,date,date,numeric)'::regprocedure);
  _def := regexp_replace(_def, E'\\n\\s*''self_sustaining'', COALESCE\\(\\(_sus->>''reached''\\)::boolean, false\\),', '');
  IF _def ~ 'self_sustaining' THEN RAISE EXCEPTION '_payout_calc: self_sustaining check not removed'; END IF;
  EXECUTE _def;
END $$;

-- Offer and product reports: count only bills inside the chosen business days
-- (the old join summed lines from every date).
CREATE OR REPLACE FUNCTION public.offers_performance(_from date DEFAULT (public.business_today() - 30), _to date DEFAULT public.business_today())
 RETURNS TABLE(offer_id uuid, title text, offer_type text, offer_price numeric, times_sold bigint, revenue numeric, cogs numeric, net_profit numeric, margin_pct numeric, discount_given numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  LEFT JOIN (public.order_items oi
             JOIN public.orders o ON o.id = oi.order_id
              AND o.status IN ('pending','completed','refunded','partially_refunded')
              AND o.created_at >= public.business_day_start(_from)
              AND o.created_at < public.business_day_start(_to + 1))
    ON oi.offer_id = po.id AND oi.status = 'active'
  WHERE po.company_id = public.current_company_id()
    AND (public.has_permission('reports.view') OR public.has_permission('analytics.view') OR public.is_super_admin())
  GROUP BY po.id, po.title, po.offer_type, po.offer_price
  ORDER BY revenue DESC
$function$;

CREATE OR REPLACE FUNCTION public.product_demand(_from date, _to date)
 RETURNS TABLE(product_id uuid, name text, name_ar text, category text, image_url text, base_price numeric, unit_cost numeric, qty numeric, revenue numeric, cost numeric, margin numeric, orders_count bigint, last_sold_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT p.id, p.name, p.name_ar, c.name, p.image_url, p.base_price, p.cost,
    COALESCE(SUM(oi.quantity), 0),
    COALESCE(SUM(oi.line_total), 0),
    COALESCE(SUM(oi.unit_cost * oi.quantity), 0),
    COALESCE(SUM(oi.line_total), 0) - COALESCE(SUM(oi.unit_cost * oi.quantity), 0),
    COUNT(DISTINCT o.id),
    MAX(o.created_at)
  FROM public.products p
  LEFT JOIN public.categories c ON c.id = p.category_id
  LEFT JOIN (public.order_items oi
             JOIN public.orders o ON o.id = oi.order_id
              AND o.status IN ('completed','refunded','partially_refunded')
              AND o.created_at >= public.business_day_start(_from)
              AND o.created_at < public.business_day_start(_to + 1))
    ON oi.product_id = p.id AND oi.status = 'active'
  WHERE p.company_id = public.current_company_id() AND p.is_active
    AND (public.has_permission('analytics.view') OR public.has_permission('reports.sales')
         OR public.is_super_admin())
  GROUP BY p.id, p.name, p.name_ar, c.name, p.image_url, p.base_price, p.cost
  ORDER BY 9 DESC
$function$;
