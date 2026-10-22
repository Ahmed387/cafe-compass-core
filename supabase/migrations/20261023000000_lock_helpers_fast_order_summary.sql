SET lock_timeout = '10s';

-- 1) Internal helpers are only meant to be called from other SECURITY DEFINER
--    functions. Logged-in users could call them straight through /rpc
--    (e.g. a cashier charging a colleague with _charge_staff).
REVOKE EXECUTE ON FUNCTION public._charge_staff FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._attribute_shift_shortage FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._charge_waste FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._order_line_to_waste FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._check_waste_bearer FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.refund_order_items FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.partner_balance(uuid) FROM PUBLIC, anon, authenticated;

-- 2) Orders page summary. The old SQL version ran the orders RLS policy per
--    row (3s+, timing out at rush). This version checks the same access rules
--    once, then reads the rows directly. Customer-credit payments (cashback
--    wallet) are reported as 'points', not as cash.
CREATE OR REPLACE FUNCTION public.orders_period_summary(
  _branch_id uuid, _from date, _to date, _status text DEFAULT 'all', _order_type text DEFAULT 'all',
  _pay_method text DEFAULT 'all', _shift_id uuid DEFAULT NULL, _search text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  _company uuid := public.current_company_id();
  _cashier boolean;
  _shifts uuid[];
  _t0 timestamptz;
  _t1 timestamptz;
  _today0 timestamptz;
  _today1 timestamptz;
  _q text := NULLIF(btrim(regexp_replace(COALESCE(_search,''), '[%,()]', '', 'g')), '');
  _empty jsonb := jsonb_build_object('count',0,'sales',0,'cancelled',0,'refunded',0,'pending',0,
                    'today_count',0,'today_sales',0,'tenders','{}'::jsonb,'tenderCounts','{}'::jsonb);
  _res jsonb;
BEGIN
  IF public.current_profile_id() IS NULL OR _company IS NULL OR _branch_id IS NULL THEN
    RETURN _empty;
  END IF;
  IF NOT (public.has_permission('pos.view') OR public.has_permission('reports.sales') OR public.has_permission('kitchen.view')) THEN
    RETURN _empty;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM branches b WHERE b.id = _branch_id AND b.company_id = _company)
     OR NOT public.can_access_branch(_branch_id) THEN
    RETURN _empty;
  END IF;

  _cashier := public.is_cashier_only();
  IF _cashier THEN
    SELECT COALESCE(array_agg(s.id), '{}') INTO _shifts
    FROM shifts s WHERE s.branch_id = _branch_id AND s.status = 'open' AND public.cashier_can_see_shift(s.id);
  END IF;

  _t0 := public.business_day_start(_from, _company);
  _t1 := public.business_day_start(_to + 1, _company);
  _today0 := public.business_day_start(public.business_today(_company), _company);
  _today1 := public.business_day_start(public.business_today(_company) + 1, _company);

  WITH f AS (
    SELECT o.id, o.status::text AS status, o.created_at,
      CASE WHEN o.status::text NOT IN ('completed','pending','refunded','partially_refunded') THEN 0
        ELSE round(o.total - COALESCE(o.tax_amount,0) - COALESCE(pt.amt,0) - COALESCE(rf.amt,0), 2) END AS revenue
    FROM orders o
    LEFT JOIN LATERAL (SELECT SUM(op.amount) AS amt FROM order_payments op
                       WHERE op.order_id = o.id AND public.tender_key(op.method_key) = 'points') pt ON true
    LEFT JOIN LATERAL (SELECT SUM(r.amount - COALESCE(r.tax_amount,0)) AS amt FROM order_refunds r
                       WHERE r.order_id = o.id AND r.status = 'active' AND COALESCE(r.origin,'manual') <> 'void') rf ON true
    WHERE o.company_id = _company
      AND o.branch_id = _branch_id
      AND o.created_at >= _t0 AND o.created_at < _t1
      AND (NOT _cashier
           OR (o.shift_id IS NULL AND o.status IN ('open','pending'))
           OR o.shift_id = ANY(_shifts))
      AND (_shift_id IS NULL OR o.shift_id = _shift_id)
      AND (_order_type = 'all' OR o.order_type::text = _order_type)
      AND (_status = 'all'
           OR (_status = 'refunded' AND o.status IN ('refunded','partially_refunded'))
           OR (_status <> 'refunded' AND o.status::text = _status))
      AND (_pay_method = 'all' OR EXISTS (SELECT 1 FROM order_payments p WHERE p.order_id = o.id AND p.method_key = _pay_method))
      AND (_q IS NULL
        OR (_q ~ '^\d{4}-\d{2}-\d{2}$' AND public.business_date(o.created_at, o.company_id) = _q::date)
        OR (_q !~ '^\d{4}-\d{2}-\d{2}$' AND (
             o.order_number ILIKE '%'||_q||'%' OR o.customer_name ILIKE '%'||_q||'%' OR o.customer_phone ILIKE '%'||_q||'%'
             OR EXISTS (SELECT 1 FROM order_items i WHERE i.order_id = o.id AND i.product_name ILIKE '%'||_q||'%')
             OR EXISTS (SELECT 1 FROM user_profiles u WHERE u.id = o.created_by AND (u.display_name ILIKE '%'||_q||'%' OR u.first_name ILIKE '%'||_q||'%' OR u.last_name ILIKE '%'||_q||'%')))))
  ),
  t AS (
    SELECT public.tender_key(p.method_key) AS k, SUM(p.amount) AS amt, COUNT(*) AS cnt
    FROM f JOIN order_payments p ON p.order_id = f.id
    WHERE f.status <> 'cancelled' GROUP BY 1
  )
  SELECT jsonb_build_object(
    'count', (SELECT COUNT(*) FROM f),
    'sales', (SELECT COALESCE(SUM(f.revenue),0) FROM f),
    'cancelled', (SELECT COUNT(*) FROM f WHERE status = 'cancelled'),
    'refunded', (SELECT COUNT(*) FROM f WHERE status IN ('refunded','partially_refunded')),
    'pending', (SELECT COUNT(*) FROM f WHERE status = 'pending'),
    'today_count', (SELECT COUNT(*) FROM f WHERE created_at >= _today0 AND created_at < _today1 AND status <> 'cancelled'),
    'today_sales', (SELECT COALESCE(SUM(revenue),0) FROM f WHERE created_at >= _today0 AND created_at < _today1),
    'tenders', (SELECT COALESCE(jsonb_object_agg(k, amt),'{}'::jsonb) FROM t),
    'tenderCounts', (SELECT COALESCE(jsonb_object_agg(k, cnt),'{}'::jsonb) FROM t)
  ) INTO _res;
  RETURN _res;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.orders_period_summary(uuid, date, date, text, text, text, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.orders_period_summary(uuid, date, date, text, text, text, uuid, text) TO authenticated;
