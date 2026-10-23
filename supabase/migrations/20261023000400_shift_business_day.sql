-- Business day = the day the shift opened. A shift opened 22/10 at 18:00 and
-- closed 23/10 at 18:00 counts entirely on 22/10: its bills, refunds, waste and
-- drawer difference. Anything without a shift uses the plain Cairo calendar day
-- (the 06:00 rule is gone). "Today" is the open shift's day while one is open.

CREATE OR REPLACE FUNCTION public.business_day_start_hour()
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$ SELECT 0 $function$;

ALTER TABLE public.shifts ADD COLUMN IF NOT EXISTS business_date date;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS business_date date;
ALTER TABLE public.order_refunds ADD COLUMN IF NOT EXISTS business_date date;
ALTER TABLE public.stock_movements ADD COLUMN IF NOT EXISTS business_date date;

-- Business day of the newest open shift (of a branch, or of the company).
CREATE OR REPLACE FUNCTION public.open_shift_business_date(_company uuid, _branch uuid DEFAULT NULL)
 RETURNS date
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT s.business_date FROM public.shifts s
   WHERE s.company_id = _company AND s.status = 'open' AND (_branch IS NULL OR s.branch_id = _branch)
   ORDER BY s.opened_at DESC LIMIT 1
$function$;

CREATE OR REPLACE FUNCTION public.business_today(_company uuid DEFAULT NULL::uuid)
 RETURNS date
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(public.open_shift_business_date(COALESCE(_company, public.current_company_id())),
                  public.business_date(now(), _company))
$function$;

CREATE OR REPLACE FUNCTION public.trg_shift_business_date()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  NEW.business_date := COALESCE(NEW.business_date, public.business_date(COALESCE(NEW.opened_at, now()), NEW.company_id));
  RETURN NEW;
END $function$;

-- Bills and refunds take their shift's day.
CREATE OR REPLACE FUNCTION public.trg_row_business_date()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  NEW.business_date := COALESCE((SELECT s.business_date FROM public.shifts s WHERE s.id = NEW.shift_id),
                                public.business_date(COALESCE(NEW.created_at, now()), NEW.company_id));
  RETURN NEW;
END $function$;

-- Stock moves take the day of the shift open at that moment.
CREATE OR REPLACE FUNCTION public.trg_stock_move_business_date()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  NEW.business_date := COALESCE(NEW.business_date,
                                public.open_shift_business_date(NEW.company_id, NEW.branch_id),
                                public.business_date(COALESCE(NEW.created_at, now()), NEW.company_id));
  RETURN NEW;
END $function$;

CREATE OR REPLACE TRIGGER t_shifts_business_date BEFORE INSERT ON public.shifts
  FOR EACH ROW EXECUTE FUNCTION public.trg_shift_business_date();
CREATE OR REPLACE TRIGGER t_orders_business_date BEFORE INSERT OR UPDATE OF shift_id ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.trg_row_business_date();
CREATE OR REPLACE TRIGGER t_refunds_business_date BEFORE INSERT OR UPDATE OF shift_id ON public.order_refunds
  FOR EACH ROW EXECUTE FUNCTION public.trg_row_business_date();
CREATE OR REPLACE TRIGGER t_stock_moves_business_date BEFORE INSERT ON public.stock_movements
  FOR EACH ROW EXECUTE FUNCTION public.trg_stock_move_business_date();

-- Fill the new column on existing rows. Only the new column is written; other
-- triggers (updated_at, closed-shift lock, waste recharge) are skipped.
SET LOCAL session_replication_role = replica;

UPDATE public.shifts s SET business_date = public.business_date(s.opened_at, s.company_id)
 WHERE s.business_date IS NULL;

UPDATE public.orders o
   SET business_date = COALESCE((SELECT s.business_date FROM public.shifts s WHERE s.id = o.shift_id),
                                public.business_date(o.created_at, o.company_id))
 WHERE o.business_date IS NULL;

UPDATE public.order_refunds r
   SET business_date = COALESCE((SELECT s.business_date FROM public.shifts s WHERE s.id = r.shift_id),
                                public.business_date(r.created_at, r.company_id))
 WHERE r.business_date IS NULL;

UPDATE public.stock_movements sm
   SET business_date = COALESCE((SELECT s.business_date FROM public.shifts s
                                  WHERE s.branch_id = sm.branch_id AND sm.created_at >= s.opened_at
                                    AND sm.created_at < COALESCE(s.closed_at, 'infinity')
                                  ORDER BY s.opened_at DESC LIMIT 1),
                                public.business_date(sm.created_at, sm.company_id))
 WHERE sm.business_date IS NULL;

SET LOCAL session_replication_role = origin;

ALTER TABLE public.shifts ALTER COLUMN business_date SET NOT NULL;
ALTER TABLE public.orders ALTER COLUMN business_date SET NOT NULL;
ALTER TABLE public.order_refunds ALTER COLUMN business_date SET NOT NULL;
ALTER TABLE public.stock_movements ALTER COLUMN business_date SET NOT NULL;

CREATE INDEX IF NOT EXISTS orders_company_business_date_idx ON public.orders (company_id, business_date);
CREATE INDEX IF NOT EXISTS order_refunds_company_business_date_idx ON public.order_refunds (company_id, business_date);
CREATE INDEX IF NOT EXISTS stock_movements_company_business_date_idx ON public.stock_movements (company_id, business_date);

-- Reports read the business day instead of clock-time ranges.
CREATE OR REPLACE FUNCTION public._range_pnl(_company uuid, _from date, _to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _t0 timestamptz; _t1 timestamptz;
  _gross numeric := 0; _promo numeric := 0; _manual numeric := 0; _points numeric := 0;
  _tax numeric := 0; _refunds numeric := 0; _refund_tax numeric := 0; _orders int := 0;
  _cogs_sold numeric := 0; _cogs_returned numeric := 0; _refund_waste numeric := 0;
  _waste numeric := 0; _waste_staff numeric := 0; _stocktake numeric := 0; _shortage numeric := 0; _over numeric := 0;
  _expenses numeric := 0; _pending_exp numeric := 0; _pending_cnt int := 0;
  _payroll numeric := 0; _mgmt_recorded numeric := 0; _tab_open numeric := 0;
  _revenue numeric; _cogs numeric; _gp numeric; _ops numeric; _net numeric;
BEGIN
  IF _company IS NULL THEN RAISE EXCEPTION 'Company not found'; END IF;
  IF _from IS NULL OR _to IS NULL OR _to < _from THEN RAISE EXCEPTION 'Choose a valid date range'; END IF;

  _t0 := public.business_day_start(_from, _company);
  _t1 := public.business_day_start(_to + 1, _company);

  -- Sales (orders counted on their shift's business day) ----------
  SELECT COUNT(*), COALESCE(SUM(o.promotional_discount), 0), COALESCE(SUM(o.discount_amount), 0),
         COALESCE(SUM(o.tax_amount), 0)
    INTO _orders, _promo, _manual, _tax
    FROM public.orders o
   WHERE o.company_id = _company
     AND o.status IN ('completed', 'pending', 'refunded', 'partially_refunded')
     AND o.business_date BETWEEN _from AND _to;

  SELECT COALESCE(SUM((oi.base_price + COALESCE(oi.modifiers_total, 0)) * oi.quantity), 0),
         COALESCE(SUM(public.line_cogs(oi)), 0)
    INTO _gross, _cogs_sold
    FROM public.orders o JOIN public.order_items oi ON oi.order_id = o.id
   WHERE o.company_id = _company
     AND o.status IN ('completed', 'pending', 'refunded', 'partially_refunded')
     AND o.business_date BETWEEN _from AND _to
     AND oi.status = 'active';

  SELECT COALESCE(SUM(op.amount), 0) INTO _points
    FROM public.orders o JOIN public.order_payments op ON op.order_id = o.id
   WHERE o.company_id = _company
     AND o.status IN ('completed', 'pending', 'refunded', 'partially_refunded')
     AND o.business_date BETWEEN _from AND _to
     AND public.tender_key(op.method_key) = 'points';

  -- Refunds are recognised on the business day of the shift they happen in. Refunds of cancelled orders are
  -- skipped: a cancelled order's sale is already excluded, so its refund would
  -- otherwise be deducted twice.
  SELECT COALESCE(SUM(r.amount), 0), COALESCE(SUM(r.tax_amount), 0)
    INTO _refunds, _refund_tax
    FROM public.order_refunds r JOIN public.orders o ON o.id = r.order_id
   WHERE r.company_id = _company AND r.status = 'active' AND o.status <> 'cancelled'
     AND COALESCE(r.origin, 'manual') <> 'void'
     AND r.business_date BETWEEN _from AND _to;

  -- Restocked refund lines give their cost back; wasted ones were already in COGS.
  SELECT COALESCE(SUM(CASE WHEN e->>'disposition' = 'restock'
                           THEN COALESCE(public.order_item_unit_cogs(NULLIF(e->>'order_item_id', '')::uuid),
                                         COALESCE((e->>'unit_cost')::numeric, 0))
                                * COALESCE((e->>'quantity')::numeric, 0) END), 0),
         COALESCE(SUM(CASE WHEN e->>'disposition' = 'waste'
                           THEN COALESCE((e->>'unit_cost')::numeric, 0) * COALESCE((e->>'quantity')::numeric, 0) END), 0)
    INTO _cogs_returned, _refund_waste
    FROM public.order_refunds r JOIN public.orders o ON o.id = r.order_id
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(r.items_payload, '[]'::jsonb)) e
   WHERE r.company_id = _company AND r.status = 'active' AND o.status <> 'cancelled'
     AND r.business_date BETWEEN _from AND _to;

  -- A full refund (refund_order) returns every active line to stock, so its cost comes back too.
  _cogs_returned := _cogs_returned + COALESCE((
    SELECT SUM(public.line_cogs(oi))
      FROM public.order_refunds r
      JOIN public.orders o ON o.id = r.order_id
      JOIN public.order_items oi ON oi.order_id = o.id AND oi.status = 'active'
     WHERE r.company_id = _company AND r.status = 'active' AND r.kind = 'full' AND r.items_payload IS NULL
       AND COALESCE(r.origin, 'manual') = 'manual' AND o.status = 'refunded'
       AND r.business_date BETWEEN _from AND _to), 0);

  -- Stock losses -----------------------------------------------------
  -- Waste charged to staff (record_waste) is recovered as payroll penalties,
  -- which lower payroll cost when deducted; it is listed apart for clarity.
  SELECT COALESCE(SUM(-sm.quantity * sm.unit_cost), 0),
         COALESCE(SUM(-sm.quantity * sm.unit_cost) FILTER (WHERE sm.waste_bearer IN ('staff', 'all_staff')), 0)
    INTO _waste, _waste_staff
    FROM public.stock_movements sm
   WHERE sm.company_id = _company AND sm.movement_type = 'waste' AND sm.quantity < 0
     AND sm.business_date BETWEEN _from AND _to;

  SELECT COALESCE(SUM(st.shortage_cost), 0) INTO _stocktake
    FROM public.stocktakes st
   WHERE st.company_id = _company AND st.shortage_cost > 0
     AND st.created_at >= _t0 AND st.created_at < _t1;

  -- Drawer differences (on the shift's business day) ---------------------
  SELECT COALESCE(SUM(GREATEST(-sh.variance, 0)), 0), COALESCE(SUM(GREATEST(sh.variance, 0)), 0)
    INTO _shortage, _over
    FROM public.shifts sh
   WHERE sh.company_id = _company AND sh.status = 'closed'
     AND sh.business_date BETWEEN _from AND _to;

  -- Operating expenses --------------------------------------------------
  SELECT COALESCE(SUM(e.amount) FILTER (WHERE e.approved_at IS NOT NULL), 0),
         COALESCE(SUM(e.amount) FILTER (WHERE e.approved_at IS NULL), 0),
         COUNT(*) FILTER (WHERE e.approved_at IS NULL)
    INTO _expenses, _pending_exp, _pending_cnt
    FROM public.expenses e
   WHERE e.company_id = _company AND e.status = 'active'
     AND e.expense_date BETWEEN _from AND _to;

  -- Payroll: each salary line is spread over its own days, so any range gets
  -- exactly its share and nothing is counted twice.
  SELECT COALESCE(SUM(public.salary_line_cost(s)
           * (LEAST(s.period_end, _to) - GREATEST(s.period_start, _from) + 1)::numeric
           / (s.period_end - s.period_start + 1)), 0),
         COALESCE(SUM(public.salary_line_cost(s)
           * (LEAST(s.period_end, _to) - GREATEST(s.period_start, _from) + 1)::numeric
           / (s.period_end - s.period_start + 1)) FILTER (WHERE s.salary_kind = 'manager_percent'), 0)
    INTO _payroll, _mgmt_recorded
    FROM public.salary_payments s
   WHERE s.company_id = _company AND s.status = 'active'
     AND s.period_start <= _to AND s.period_end >= _from;

  -- Informational: partner tab balance still owed from sales in this range.
  SELECT COALESCE(SUM(t.total_amount - t.settled_amount), 0) INTO _tab_open
    FROM public.partner_tab_orders t
   WHERE t.company_id = _company AND NOT t.is_settled
     AND EXISTS (SELECT 1 FROM public.orders o WHERE o.id = t.order_id AND o.business_date BETWEEN _from AND _to);

  -- Results ------------------------------------------------------------
  _revenue := _gross - _promo - _manual - _points - (_refunds - _refund_tax);
  _cogs := _cogs_sold - _cogs_returned;
  _gp := _revenue - _cogs - _waste - _stocktake;
  _ops := _expenses + _payroll + _shortage - _over;
  _net := _gp - _ops;

  RETURN jsonb_build_object(
    'from', _from, 'to', _to, 'days', (_to - _from + 1), 'orders_count', _orders,
    'gross_sales', round(_gross, 2),
    'promo_discount', round(_promo, 2),
    'manual_discounts', round(_manual, 2),
    'points_redeemed', round(_points, 2),
    'refunds_total', round(_refunds - _refund_tax, 2),
    'revenue', round(_revenue, 2),
    'tax_collected', round(_tax - _refund_tax, 2),
    'cogs', round(_cogs, 2),
    'cogs_returned', round(_cogs_returned, 2),
    'refund_waste_info', round(_refund_waste, 2),
    'waste_cost', round(_waste, 2),
    'waste_business', round(_waste - _waste_staff, 2),
    'waste_charged_staff', round(_waste_staff, 2),
    'stocktake_shortage', round(_stocktake, 2),
    'gross_profit', round(_gp, 2),
    'expenses_total', round(_expenses, 2),
    'expenses_pending', round(_pending_exp, 2),
    'expenses_pending_count', _pending_cnt,
    'payroll_total', round(_payroll, 2),
    'management_salary_recorded', round(_mgmt_recorded, 2),
    'cash_shortage', round(_shortage, 2),
    'cash_over', round(_over, 2),
    'operating_total', round(_ops, 2),
    'net_profit', round(_net, 2),
    'partner_tab_open', round(_tab_open, 2),
    'departments', jsonb_build_array(
      jsonb_build_object('key', 'sales', 'income', round(_revenue, 2), 'cost', round(_cogs, 2),
                         'result', round(_revenue - _cogs, 2)),
      jsonb_build_object('key', 'warehouse', 'income', 0, 'cost', round(_waste + _stocktake, 2),
                         'result', round(-(_waste + _stocktake), 2)),
      jsonb_build_object('key', 'operations', 'income', round(_over, 2),
                         'cost', round(_expenses + _payroll + _shortage, 2), 'result', round(-_ops, 2))
    )
  );
END $function$;

CREATE OR REPLACE FUNCTION public.orders_period_summary(_branch_id uuid, _from date, _to date, _status text DEFAULT 'all'::text, _order_type text DEFAULT 'all'::text, _pay_method text DEFAULT 'all'::text, _shift_id uuid DEFAULT NULL::uuid, _search text DEFAULT NULL::text)
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
  _today date;
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
  _today := public.business_today(_company);

  WITH f AS (
    SELECT o.id, o.status::text AS status, o.business_date,
      CASE WHEN o.status::text NOT IN ('completed','pending','refunded','partially_refunded') THEN 0
        ELSE round(o.total - COALESCE(o.tax_amount,0) - COALESCE(pt.amt,0) - COALESCE(rf.amt,0), 2) END AS revenue
    FROM orders o
    LEFT JOIN LATERAL (SELECT SUM(op.amount) AS amt FROM order_payments op
                       WHERE op.order_id = o.id AND public.tender_key(op.method_key) = 'points') pt ON true
    LEFT JOIN LATERAL (SELECT SUM(r.amount - COALESCE(r.tax_amount,0)) AS amt FROM order_refunds r
                       WHERE r.order_id = o.id AND r.status = 'active' AND COALESCE(r.origin,'manual') <> 'void') rf ON true
    WHERE o.company_id = _company
      AND o.branch_id = _branch_id
      AND (o.business_date BETWEEN _from AND _to OR (_cashier AND o.shift_id = ANY(_shifts)))
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
        OR (_q ~ '^\d{4}-\d{2}-\d{2}$' AND o.business_date = _q::date)
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
    'today_count', (SELECT COUNT(*) FROM f WHERE business_date = _today AND status <> 'cancelled'),
    'today_sales', (SELECT COALESCE(SUM(revenue),0) FROM f WHERE business_date = _today),
    'tenders', (SELECT COALESCE(jsonb_object_agg(k, amt),'{}'::jsonb) FROM t),
    'tenderCounts', (SELECT COALESCE(jsonb_object_agg(k, cnt),'{}'::jsonb) FROM t)
  ) INTO _res;
  RETURN _res;
END;
$function$;

CREATE OR REPLACE FUNCTION public.sales_period_summary(_from date, _to date, _branch_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _cid uuid := public.current_company_id();
  _t0 timestamptz; _t1 timestamptz; _p jsonb; _rev numeric; _cnt int := 0; _cancelled int := 0;
  _by_day jsonb := '[]'::jsonb; _by_product jsonb := '[]'::jsonb;
  _by_method jsonb := '[]'::jsonb; _by_cashier jsonb := '[]'::jsonb;
BEGIN
  IF NOT (public.has_permission('reports.sales') OR public.has_permission('pos.view') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF _branch_id IS NOT NULL AND NOT public.can_access_branch(_branch_id) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF _from IS NULL OR _to IS NULL OR _to < _from THEN RAISE EXCEPTION 'Choose a valid date range'; END IF;

  _t0 := public.business_day_start(_from, _cid);
  _t1 := public.business_day_start(_to + 1, _cid);
  _p := public._range_pnl(_cid, _from, _to);
  _rev := (_p->>'revenue')::numeric;

  SELECT COUNT(*) FILTER (WHERE o.status IN ('pending','completed','refunded','partially_refunded')),
         COUNT(*) FILTER (WHERE o.status = 'cancelled')
    INTO _cnt, _cancelled
    FROM public.orders o
   WHERE o.company_id = _cid AND (_branch_id IS NULL OR o.branch_id = _branch_id)
     AND o.business_date BETWEEN _from AND _to;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('day', d.day, 'revenue', (d.p->>'revenue')::numeric,
           'count', (d.p->>'orders_count')::int) ORDER BY d.day), '[]'::jsonb)
    INTO _by_day
    FROM (SELECT g::date AS day, public._range_pnl(_cid, g::date, g::date) AS p
            FROM generate_series(_from, _to, interval '1 day') g) d
   WHERE (d.p->>'orders_count')::int > 0 OR (d.p->>'revenue')::numeric <> 0;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('name', p.name, 'qty', p.qty, 'revenue', p.revenue) ORDER BY p.revenue DESC), '[]'::jsonb)
    INTO _by_product
  FROM (
    SELECT oi.product_name AS name, SUM(oi.quantity) AS qty, ROUND(SUM(oi.line_total),2) AS revenue
    FROM public.order_items oi JOIN public.orders o ON o.id = oi.order_id
    WHERE o.company_id = _cid AND (_branch_id IS NULL OR o.branch_id = _branch_id)
      AND o.status IN ('pending','completed','refunded','partially_refunded') AND oi.status = 'active'
      AND o.business_date BETWEEN _from AND _to
    GROUP BY 1 ORDER BY 3 DESC LIMIT 200
  ) p;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('method', m.method_key, 'amount', m.amount) ORDER BY m.amount DESC), '[]'::jsonb)
    INTO _by_method
  FROM (
    SELECT op.method_key, ROUND(SUM(op.amount),2) AS amount
    FROM public.order_payments op JOIN public.orders o ON o.id = op.order_id
    WHERE o.company_id = _cid AND (_branch_id IS NULL OR o.branch_id = _branch_id)
      AND o.status IN ('pending','completed','refunded','partially_refunded')
      AND o.business_date BETWEEN _from AND _to
    GROUP BY 1
  ) m;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('name', c.name, 'revenue', c.revenue, 'count', c.cnt) ORDER BY c.revenue DESC), '[]'::jsonb)
    INTO _by_cashier
  FROM (
    SELECT COALESCE(NULLIF(up.display_name,''), up.first_name, '—') AS name,
           ROUND(SUM(public.order_revenue(o)),2) AS revenue, COUNT(*) AS cnt
    FROM public.orders o LEFT JOIN public.user_profiles up ON up.id = o.created_by
    WHERE o.company_id = _cid AND (_branch_id IS NULL OR o.branch_id = _branch_id)
      AND o.status IN ('pending','completed','refunded','partially_refunded')
      AND o.business_date BETWEEN _from AND _to
    GROUP BY 1
  ) c;

  RETURN jsonb_build_object(
    'revenue', ROUND(_rev, 2),
    'refunds', (_p->>'refunds_total')::numeric,
    'discounts', (_p->>'manual_discounts')::numeric,
    'cogs', (_p->>'cogs')::numeric,
    'gross_profit', ROUND(_rev - (_p->>'cogs')::numeric, 2),
    'count', _cnt,
    'cancelled', _cancelled,
    'avg', CASE WHEN _cnt > 0 THEN ROUND(_rev / _cnt, 2) ELSE 0 END,
    'by_day', _by_day, 'by_product', _by_product, 'by_method', _by_method, 'by_cashier', _by_cashier);
END
$function$;

CREATE OR REPLACE FUNCTION public._payout_calc(_company uuid, _from date, _to date, _fund numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _pnl jsonb; _net numeric; _mgmt_total numeric; _mgmt_recorded numeric; _mgmt_due numeric;
  _after_mgmt numeric; _cfg jsonb; _rtype text; _rval numeric; _reserve numeric; _available numeric;
  _fund_r numeric := round(GREATEST(COALESCE(_fund, 0), 0), 2); _pool numeric; _share_total numeric;
  _active_total numeric; _lines jsonb := '[]'::jsonb; _allocated numeric := 0; _r record; _amt numeric;
  _tab numeric; _adv numeric; _tab_d numeric; _adv_d numeric; _largest uuid; _overlap jsonb; _open_shifts int; _open_orders int; _sus jsonb; _today date;
  _to_end timestamptz;
BEGIN
  _today := public.business_today(_company);
  _pnl := public._range_pnl(_company, _from, _to);
  _net := (_pnl->>'net_profit')::numeric;
  _to_end := public.business_day_start(_to + 1, _company);

  SELECT COALESCE(SUM(m.amount), 0) INTO _mgmt_total FROM public._management_salary(_company, _from, _to, _pnl) m;
  _mgmt_recorded := (_pnl->>'management_salary_recorded')::numeric;
  _mgmt_due := GREATEST(round(_mgmt_total - _mgmt_recorded, 2), 0);
  _after_mgmt := round(_net - _mgmt_due, 2);

  _cfg := public.operating_reserve_settings();
  _rtype := COALESCE(_cfg->>'operating_reserve_type', 'percent');
  _rval := GREATEST(COALESCE((_cfg->>'operating_reserve_value')::numeric, 0), 0);
  _reserve := CASE WHEN _after_mgmt <= 0 THEN 0
                   WHEN _rtype = 'amount' THEN LEAST(_rval, _after_mgmt)
                   ELSE round(_after_mgmt * LEAST(_rval, 100) / 100.0, 2) END;
  _available := GREATEST(round(_after_mgmt - _reserve, 2), 0);
  _pool := round(_available - _fund_r, 2);

  -- Partner shares: active partners, must total 100%. Paused partners keep
  -- their share in the café (no line, nothing is redistributed to others).
  SELECT COALESCE(SUM(po.ownership_percentage), 0),
         COALESCE(SUM(po.ownership_percentage) FILTER (WHERE NOT p.dividends_paused), 0)
    INTO _share_total, _active_total
    FROM public.partner_ownership po JOIN public.partners p ON p.id = po.partner_id
   WHERE po.company_id = _company AND p.status = 'active' AND po.ownership_percentage > 0;
  _share_total := round(_share_total, 4);

  IF round(_active_total, 4) = 100 THEN
    SELECT po.partner_id INTO _largest
      FROM public.partner_ownership po JOIN public.partners p ON p.id = po.partner_id
     WHERE po.company_id = _company AND p.status = 'active' AND po.ownership_percentage > 0
     ORDER BY po.ownership_percentage DESC, po.partner_id LIMIT 1;
  END IF;

  FOR _r IN
    SELECT po.partner_id, p.name, po.ownership_percentage AS pct, p.dividends_paused AS paused
      FROM public.partner_ownership po JOIN public.partners p ON p.id = po.partner_id
     WHERE po.company_id = _company AND p.status = 'active' AND po.ownership_percentage > 0
     ORDER BY (po.partner_id = _largest) NULLS FIRST, po.partner_id
  LOOP
    _amt := CASE WHEN _r.paused OR _pool <= 0 THEN 0
                 WHEN _r.partner_id = _largest THEN round(_pool - _allocated, 2)
                 ELSE round(_pool * _r.pct / 100.0, 2) END;
    _allocated := _allocated + _amt;
    SELECT COALESCE(SUM(t.total_amount - t.settled_amount), 0) INTO _tab
      FROM public.partner_tab_orders t
     WHERE t.partner_id = _r.partner_id AND NOT t.is_settled AND t.created_at < _to_end;
    -- Partner advances (سلف) taken up to the end of the range.
    SELECT COALESCE(SUM(a.amount - a.deducted_amount), 0) INTO _adv
      FROM public.partner_advances a
     WHERE a.partner_id = _r.partner_id AND a.status = 'active' AND a.deducted_amount < a.amount AND a.advance_date <= _to;
    -- Order: tabs first, then advances; each only up to what the dividend covers.
    _tab_d := LEAST(round(_tab, 2), _amt);
    _adv_d := LEAST(round(_adv, 2), _amt - _tab_d);
    _lines := _lines || jsonb_build_array(jsonb_build_object(
      'partner_id', _r.partner_id, 'name', _r.name, 'pct', _r.pct, 'paused', _r.paused,
      'amount', _amt, 'tab_open', round(_tab, 2), 'tab_deduct', _tab_d,
      'advance_open', round(_adv, 2), 'advance_deduct', _adv_d,
      'cash_due', round(_amt - _tab_d - _adv_d, 2),
      'tab_carried', round(_tab - _tab_d, 2),
      'advance_carried', round(_adv - _adv_d, 2)));
  END LOOP;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', d.id, 'from', d.range_from, 'to', d.range_to)), '[]'::jsonb)
    INTO _overlap
    FROM public.profit_distributions d
   WHERE d.company_id = _company AND d.status = 'active' AND d.range_from IS NOT NULL
     AND d.range_from <= _to AND d.range_to >= _from;

  SELECT count(*) INTO _open_shifts FROM public.shifts s
   WHERE s.company_id = _company AND s.status = 'open' AND s.business_date <= _to;
  SELECT count(*) INTO _open_orders FROM public.orders o
   WHERE o.company_id = _company AND o.status = 'open'
     AND o.business_date BETWEEN _from AND _to;

  _sus := public.financial_self_sustainability();

  RETURN jsonb_build_object(
    'from', _from, 'to', _to, 'pnl', _pnl,
    'net_profit', round(_net, 2),
    'management_salary_total', round(_mgmt_total, 2),
    'management_salary_recorded', round(_mgmt_recorded, 2),
    'management_salary_due', _mgmt_due,
    'net_after_management', _after_mgmt,
    'reserve_type', _rtype, 'reserve_value', _rval, 'reserve_amount', round(_reserve, 2),
    'available_before_fund', _available,
    'development_fund', _fund_r,
    'partner_pool', GREATEST(_pool, 0),
    'retained_paused', round(GREATEST(_pool, 0) - _allocated, 2),
    'lines', _lines,
    'sustainability', _sus,
    'checks', jsonb_build_object(
      'range_valid', _to >= _from AND _to <= _today,
      'no_overlap', jsonb_array_length(_overlap) = 0,
      'no_open_shifts', _open_shifts = 0,
      'no_open_orders', _open_orders = 0,
      'net_positive', _available > 0,
      'fund_within_limit', _fund_r <= _available,
      'partner_pool_positive', _pool > 0,
      'shares_total_100', _share_total = 100),
    'overlaps', _overlap, 'open_shifts', _open_shifts, 'open_orders', _open_orders,
    'share_total', _share_total);
END $function$;

CREATE OR REPLACE FUNCTION public.monthly_operating_costs(_from date, _to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _company uuid := public.current_company_id(); _p jsonb; _t0 timestamptz; _t1 timestamptz;
  _purchases numeric := 0; _purch_paid numeric := 0; _advances numeric := 0; _items jsonb; _cats jsonb;
  _cogs numeric; _waste numeric; _payroll numeric; _expenses numeric;
BEGIN
  IF NOT (public.has_permission('reports.profit') OR public.has_permission('treasury.view')
          OR public.has_permission('partners.view_profit') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  _p := public._range_pnl(_company, _from, _to);
  _t0 := public.business_day_start(_from, _company);
  _t1 := public.business_day_start(_to + 1, _company);
  _cogs := (_p->>'cogs')::numeric;
  _waste := (_p->>'waste_cost')::numeric + (_p->>'stocktake_shortage')::numeric;
  _payroll := (_p->>'payroll_total')::numeric;
  _expenses := (_p->>'expenses_total')::numeric;

  SELECT COALESCE(SUM(p.total - p.returned_amount),0), COALESCE(SUM(p.paid_amount),0)
    INTO _purchases, _purch_paid
  FROM public.purchases p WHERE p.company_id = _company AND p.status <> 'cancelled'
    AND p.purchase_date BETWEEN _from AND _to;

  SELECT COALESCE(SUM(a.amount),0) INTO _advances FROM public.employee_advances a
  WHERE a.company_id = _company AND a.status = 'active' AND a.advance_date BETWEEN _from AND _to;

  SELECT COALESCE(jsonb_agg(x ORDER BY x->>'cost' DESC), '[]'::jsonb) INTO _items FROM (
    SELECT jsonb_build_object('item', i.name, 'item_ar', i.name_ar, 'unit', i.unit,
      'qty', round(SUM(-sm.quantity),3), 'cost', round(SUM(-sm.quantity * sm.unit_cost),2)) AS x
    FROM public.stock_movements sm JOIN public.inventory_items i ON i.id = sm.item_id
    WHERE sm.company_id = _company AND sm.quantity < 0
      AND sm.movement_type IN ('sale_consumption','waste','adjustment','stocktake')
      AND sm.business_date BETWEEN _from AND _to
    GROUP BY i.name, i.name_ar, i.unit
  ) s;

  SELECT COALESCE(jsonb_agg(x ORDER BY x->>'amount' DESC), '[]'::jsonb) INTO _cats FROM (
    SELECT jsonb_build_object('category', COALESCE(c.name,'Other'), 'category_ar', c.name_ar,
      'amount', round(SUM(e.amount),2)) AS x
    FROM public.expenses e LEFT JOIN public.expense_categories c ON c.id = e.category_id
    WHERE e.company_id = _company AND e.status = 'active' AND e.approved_at IS NOT NULL
      AND e.expense_date BETWEEN _from AND _to
    GROUP BY c.name, c.name_ar
  ) s;

  RETURN jsonb_build_object(
    'from', _from, 'to', _to,
    'sales', (_p->>'revenue')::numeric, 'tax', (_p->>'tax_collected')::numeric,
    'cogs', _cogs, 'waste', round(_waste, 2),
    'purchases_total', round(_purchases,2), 'purchases_paid', round(_purch_paid,2),
    'purchases_due', round(_purchases - _purch_paid,2),
    'payroll', _payroll, 'advances', round(_advances,2),
    'expenses', _expenses, 'expenses_pending', (_p->>'expenses_pending')::numeric,
    'operating_total', round(_cogs + _waste + _payroll + _expenses, 2),
    'net_profit', (_p->>'net_profit')::numeric,
    'consumption', COALESCE(_items,'[]'::jsonb),
    'expense_breakdown', COALESCE(_cats,'[]'::jsonb));
END
$function$;

CREATE OR REPLACE FUNCTION public.my_partner_dashboard(_from date, _to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _company uuid := public.current_company_id(); _partner uuid := public.current_partner_id();
  _pnl jsonb; _t0 timestamptz; _t1 timestamptz; _tabs jsonb; _tab_total numeric; _shifts jsonb; _debts numeric;
  _advances numeric; _share numeric; _p public.partners;
BEGIN
  IF public.current_profile_id() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF _partner IS NULL THEN RAISE EXCEPTION 'Not a partner'; END IF;
  IF _from IS NULL OR _to IS NULL OR _to < _from THEN RAISE EXCEPTION 'Choose a valid date range'; END IF;
  SELECT * INTO _p FROM public.partners WHERE id = _partner;
  _t0 := public.business_day_start(_from, _company);
  _t1 := public.business_day_start(_to + 1, _company);
  _pnl := public._range_pnl(_company, _from, _to);

  SELECT COALESCE(SUM(t.total_amount), 0),
         COALESCE(jsonb_agg(jsonb_build_object('order_number', o.order_number, 'created_at', t.created_at,
           'amount', t.total_amount, 'open', round(t.total_amount - t.settled_amount, 2)) ORDER BY t.created_at DESC), '[]'::jsonb)
    INTO _tab_total, _tabs
    FROM public.partner_tab_orders t JOIN public.orders o ON o.id = t.order_id
   WHERE t.partner_id = _partner AND o.business_date BETWEEN _from AND _to;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'shift_id', s.f->>'shiftId', 'opened_at', s.f->>'openedAt', 'closed_at', s.f->>'closedAt',
           'cashier', s.cashier, 'net_sales', (s.f->>'netSales')::numeric, 'gross_margin', (s.f->>'grossMargin')::numeric,
           'variance', (s.f->>'variance')::numeric) ORDER BY s.f->>'openedAt' DESC), '[]'::jsonb)
    INTO _shifts
    FROM (SELECT public._shift_figures(sh) AS f, COALESCE(NULLIF(up.display_name, ''), up.first_name) AS cashier
            FROM public.shifts sh LEFT JOIN public.user_profiles up ON up.id = sh.user_id
           WHERE sh.company_id = _company AND sh.business_date BETWEEN _from AND _to) s;

  SELECT COALESCE(SUM(p.total - p.returned_amount - p.paid_amount), 0) INTO _debts
    FROM public.purchases p
   WHERE p.company_id = _company AND p.status <> 'cancelled' AND round(p.total - p.returned_amount - p.paid_amount, 2) > 0;

  SELECT COALESCE(SUM(a.amount - a.deducted_amount), 0) INTO _advances
    FROM public.partner_advances a WHERE a.partner_id = _partner AND a.status = 'active';
  SELECT ownership_percentage INTO _share FROM public.partner_ownership WHERE partner_id = _partner;

  RETURN jsonb_build_object(
    'from', _from, 'to', _to, 'partner_name', _p.name, 'share_pct', COALESCE(_share, 0),
    'gross_sales', _pnl->'gross_sales', 'revenue', _pnl->'revenue', 'net_profit', _pnl->'net_profit',
    'my_share_estimate', CASE WHEN (_pnl->>'net_profit')::numeric > 0
                              THEN round((_pnl->>'net_profit')::numeric * COALESCE(_share, 0) / 100.0, 2) ELSE 0 END,
    'my_tab_total', round(_tab_total, 2), 'my_tabs', _tabs,
    'my_open_advances', round(_advances, 2),
    'my_balance', public.partner_balance(_partner),
    'supplier_debts', round(_debts, 2),
    'shifts', _shifts);
END $function$;

CREATE OR REPLACE FUNCTION public.offers_performance(_from date DEFAULT (business_today() - 30), _to date DEFAULT business_today())
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
              AND o.business_date BETWEEN _from AND _to)
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
              AND o.business_date BETWEEN _from AND _to)
    ON oi.product_id = p.id AND oi.status = 'active'
  WHERE p.company_id = public.current_company_id() AND p.is_active
    AND (public.has_permission('analytics.view') OR public.has_permission('reports.sales')
         OR public.is_super_admin())
  GROUP BY p.id, p.name, p.name_ar, c.name, p.image_url, p.base_price, p.cost
  ORDER BY 9 DESC
$function$;
