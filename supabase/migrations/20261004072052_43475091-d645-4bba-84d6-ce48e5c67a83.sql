CREATE OR REPLACE FUNCTION public.orders_period_summary(
  _branch_id uuid, _from date, _to date,
  _status text DEFAULT 'all', _order_type text DEFAULT 'all',
  _pay_method text DEFAULT 'all', _shift_id uuid DEFAULT NULL,
  _search text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
WITH s AS (SELECT NULLIF(btrim(regexp_replace(COALESCE(_search,''), '[%,()]', '', 'g')), '') AS q),
f AS (
  SELECT o.id, o.status::text AS status, o.total
  FROM orders o, s
  WHERE o.branch_id = _branch_id
    AND o.created_at >= _from::timestamptz AND o.created_at < (_to + 1)::timestamptz
    AND (_shift_id IS NULL OR o.shift_id = _shift_id)
    AND (_order_type = 'all' OR o.order_type::text = _order_type)
    AND (_status = 'all'
         OR (_status = 'refunded' AND o.status IN ('refunded','partially_refunded'))
         OR (_status <> 'refunded' AND o.status::text = _status))
    AND (_pay_method = 'all' OR EXISTS (SELECT 1 FROM order_payments p WHERE p.order_id = o.id AND p.method_key = _pay_method))
    AND (s.q IS NULL
      OR (s.q ~ '^\d{4}-\d{2}-\d{2}$' AND o.created_at::date = s.q::date)
      OR (s.q !~ '^\d{4}-\d{2}-\d{2}$' AND (
           o.order_number ILIKE '%'||s.q||'%' OR o.customer_name ILIKE '%'||s.q||'%' OR o.customer_phone ILIKE '%'||s.q||'%'
           OR EXISTS (SELECT 1 FROM order_items i WHERE i.order_id = o.id AND i.product_name ILIKE '%'||s.q||'%')
           OR EXISTS (SELECT 1 FROM user_profiles u WHERE u.id = o.created_by AND (u.display_name ILIKE '%'||s.q||'%' OR u.first_name ILIKE '%'||s.q||'%' OR u.last_name ILIKE '%'||s.q||'%')))))
),
r AS (SELECT f.id, COALESCE((SELECT SUM(amount) FROM order_refunds x WHERE x.order_id=f.id AND x.status='active'),0) AS refunded FROM f),
t AS (
  SELECT CASE
    WHEN lower(p.method_key) ~ '(partner|tab|account)' THEN 'partner_tab'
    WHEN lower(p.method_key) ~ '(insta|bank)' THEN 'instapay'
    WHEN lower(p.method_key) ~ '(wallet|vodafone)' THEN 'wallet'
    WHEN lower(p.method_key) ~ '(card|visa)' THEN 'visa'
    ELSE 'cash' END AS k, SUM(p.amount) AS amt, COUNT(*) AS cnt
  FROM f JOIN order_payments p ON p.order_id = f.id
  WHERE f.status <> 'cancelled' GROUP BY 1
)
SELECT jsonb_build_object(
  'count', (SELECT COUNT(*) FROM f),
  'sales', (SELECT COALESCE(SUM(f.total - r.refunded),0) FROM f JOIN r USING (id) WHERE f.status <> 'cancelled'),
  'cancelled', (SELECT COUNT(*) FROM f WHERE status='cancelled'),
  'refunded', (SELECT COUNT(*) FROM f WHERE status IN ('refunded','partially_refunded')),
  'pending', (SELECT COUNT(*) FROM f WHERE status='pending'),
  'tenders', (SELECT COALESCE(jsonb_object_agg(k, amt),'{}'::jsonb) FROM t),
  'tenderCounts', (SELECT COALESCE(jsonb_object_agg(k, cnt),'{}'::jsonb) FROM t)
);
$$;
GRANT EXECUTE ON FUNCTION public.orders_period_summary(uuid,date,date,text,text,text,uuid,text) TO authenticated;