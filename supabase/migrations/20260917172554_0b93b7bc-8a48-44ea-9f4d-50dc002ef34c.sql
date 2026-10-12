-- Golden Matrix Parts 4-8: server-side lifecycle + item-level refunds + payroll penalties

-- ======================================================
-- (A) create_pos_order: orders start as 'pending'
-- ======================================================
DO $$
DECLARE src text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO src FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'create_pos_order';
  IF src IS NOT NULL THEN
    src := replace(src, '_order_type, ''completed'',', '_order_type, ''pending'',');
    src := replace(src, '_notes, _profile, now())', '_notes, _profile, NULL)');
    EXECUTE src;
  END IF;
END $$;

-- ======================================================
-- (B) mark_order_delivered: handover action
-- ======================================================
CREATE OR REPLACE FUNCTION public.mark_order_delivered(_order_id uuid)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  _profile uuid := public.current_profile_id();
  _o public.orders;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('pos.view') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT * INTO _o FROM public.orders WHERE id = _order_id;
  IF _o.id IS NULL THEN RAISE EXCEPTION 'Order not found'; END IF;
  IF NOT public.can_access_branch(_o.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _o.status <> 'pending' THEN RAISE EXCEPTION 'Only pending orders can be marked as delivered'; END IF;

  UPDATE public.orders
  SET status = 'completed', completed_at = now(), updated_at = now()
  WHERE id = _order_id;

  PERFORM public.log_audit('order.delivered', 'pos', 'orders', _order_id, NULL,
    jsonb_build_object('order_number', _o.order_number, 'total', _o.total),
    NULL, _o.branch_id);
  RETURN _order_id;
END;
$$;

-- ======================================================
-- (C) refund_order_items: item-level refunds (waste / restock)
-- ======================================================
CREATE OR REPLACE FUNCTION public.refund_order_items(
  _order_id uuid,
  _items jsonb,
  _method_key text DEFAULT 'cash',
  _reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  _profile uuid := public.current_profile_id();
  _o public.orders;
  _entry jsonb;
  _r record;
  _item_id uuid;
  _qty int;
  _disposition text;
  _oi public.order_items;
  _refunded_qty int;
  _remaining_qty int;
  _line_gross numeric := 0;
  _amount numeric := 0;
  _paid numeric;
  _already numeric;
  _ratio numeric;
  _payload jsonb := '[]'::jsonb;
  _refund_id uuid;
  _tax_share numeric := 0;
  _earned int := 0;
  _reversed int := 0;
  _take int := 0;
  _balance int;
  _all_done boolean := false;
  _new_status text;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('pos.process_refund') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF _reason IS NULL OR length(btrim(_reason)) < 3 THEN RAISE EXCEPTION 'A reason is required'; END IF;
  IF _items IS NULL OR jsonb_array_length(_items) = 0 THEN RAISE EXCEPTION 'No refund items provided'; END IF;

  SELECT * INTO _o FROM public.orders WHERE id = _order_id;
  IF _o.id IS NULL THEN RAISE EXCEPTION 'Order not found'; END IF;
  IF NOT public.can_access_branch(_o.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _o.status NOT IN ('completed','partially_refunded') THEN
    RAISE EXCEPTION 'Only delivered orders can be refunded';
  END IF;

  SELECT COALESCE(SUM(amount),0) INTO _paid FROM public.order_payments WHERE order_id = _order_id;
  SELECT COALESCE(SUM(amount),0) INTO _already FROM public.order_refunds WHERE order_id = _order_id AND status = 'active';
  IF round(_paid - _already, 2) <= 0 THEN RAISE EXCEPTION 'This order is fully refunded'; END IF;

  -- Pass 1: validate every entry and compute the gross refund value.
  FOR _entry IN SELECT * FROM jsonb_array_elements(_items) LOOP
    _item_id := NULLIF(_entry->>'order_item_id','')::uuid;
    _qty := COALESCE((_entry->>'quantity')::int, 0);
    _disposition := COALESCE(NULLIF(_entry->>'disposition',''), 'restock');
    IF _disposition NOT IN ('restock','waste') THEN RAISE EXCEPTION 'Invalid disposition'; END IF;
    IF _qty <= 0 THEN RAISE EXCEPTION 'Refund quantity must be greater than zero'; END IF;

    SELECT * INTO _oi FROM public.order_items
    WHERE id = _item_id AND order_id = _order_id;
    IF _oi.id IS NULL THEN RAISE EXCEPTION 'Order line not found'; END IF;
    IF _oi.status = 'voided' THEN RAISE EXCEPTION 'Line % is already voided', _oi.product_name; END IF;

    SELECT COALESCE(SUM((e->>'quantity')::int),0) INTO _refunded_qty
    FROM public.order_refunds r,
         jsonb_array_elements(COALESCE(r.items_payload,'[]'::jsonb)) e
    WHERE r.order_id = _order_id AND r.status = 'active' AND r.origin = 'manual'
      AND e->>'order_item_id' = _item_id::text;

    _remaining_qty := _oi.quantity - _refunded_qty;
    IF _qty > _remaining_qty THEN
      RAISE EXCEPTION 'Cannot refund more than the remaining % on %', _remaining_qty, _oi.product_name;
    END IF;

    _line_gross := _line_gross + round((COALESCE(_oi.unit_price,0) + COALESCE(_oi.modifiers_total,0)) * _qty, 2);
  END LOOP;

  IF _line_gross <= 0 THEN RAISE EXCEPTION 'Nothing to refund'; END IF;

  -- Proportional share of the invoice total (discount + tax included).
  _ratio := CASE WHEN COALESCE(_o.subtotal,0) > 0 THEN _o.total / _o.subtotal ELSE 1 END;
  _amount := round(LEAST(_line_gross * _ratio, round(_paid - _already, 2)), 2);

  IF _paid > 0 AND COALESCE(_o.tax_amount,0) > 0 THEN
    _tax_share := round(_o.tax_amount * LEAST(_amount / _paid, 1), 2);
  END IF;

  -- Pass 2: stock side-effects + payload.
  FOR _entry IN SELECT * FROM jsonb_array_elements(_items) LOOP
    _item_id := NULLIF(_entry->>'order_item_id','')::uuid;
    _qty := (_entry->>'quantity')::int;
    _disposition := COALESCE(NULLIF(_entry->>'disposition',''), 'restock');
    SELECT * INTO _oi FROM public.order_items WHERE id = _item_id;

    IF _disposition = 'restock' THEN
      IF _qty = _oi.quantity THEN
        PERFORM public.return_line_stock(_item_id);
      ELSE
        FOR _r IN SELECT sm.item_id, sm.quantity, sm.branch_id
                  FROM public.stock_movements sm
                  WHERE sm.reference_type = 'order_item'
                    AND sm.movement_type = 'sale_consumption'
                    AND sm.reference_id = _item_id
        LOOP
          PERFORM public.apply_stock_movement(_r.branch_id, _r.item_id, 'sale_return',
            -round(_r.quantity * _qty / _oi.quantity, 3), NULL,
            'Partial item refund (restock)', 'order_item', _item_id);
        END LOOP;
      END IF;
    END IF;
    -- Waste: ingredients were consumed at sale time; stock stays as-is.
    -- The loss is recorded in items_payload and surfaced on the shift waste card.

    _payload := _payload || jsonb_build_object(
      'order_item_id', _item_id,
      'product_name', _oi.product_name,
      'quantity', _qty,
      'unit_price', COALESCE(_oi.unit_price,0),
      'unit_cost', COALESCE(_oi.unit_cost,0),
      'line_gross', round((COALESCE(_oi.unit_price,0) + COALESCE(_oi.modifiers_total,0)) * _qty, 2),
      'disposition', _disposition);
  END LOOP;

  INSERT INTO public.order_refunds
    (company_id, branch_id, order_id, shift_id, kind, amount, tax_amount, method_key,
     reason, status, origin, items_payload, created_by)
  VALUES
    (_o.company_id, _o.branch_id, _o.id, _o.shift_id, 'partial', _amount, _tax_share,
     COALESCE(NULLIF(_method_key,''),'cash'), _reason, 'active', 'manual', _payload, _profile)
  RETURNING id INTO _refund_id;

  -- Loyalty reversal: proportional to the refunded value.
  IF _o.customer_id IS NOT NULL AND _paid > 0 THEN
    SELECT COALESCE(SUM(points),0) INTO _earned
    FROM public.customer_points_transactions
    WHERE order_id = _order_id AND kind = 'earn';
    SELECT COALESCE(-SUM(points),0) INTO _reversed
    FROM public.customer_points_transactions
    WHERE order_id = _order_id AND kind = 'refund';

    IF _earned > 0 THEN
      _take := LEAST(round(_earned * (_amount / _paid))::int, _earned - _reversed);
      IF _take > 0 THEN
        SELECT points_balance INTO _balance FROM public.customers WHERE id = _o.customer_id;
        _take := LEAST(_take, GREATEST(COALESCE(_balance,0), 0));
      END IF;
    END IF;

    UPDATE public.customers
    SET points_balance = GREATEST(COALESCE(points_balance,0) - GREATEST(_take,0), 0),
        total_spent = GREATEST(COALESCE(total_spent,0) - _amount, 0),
        updated_at = now()
    WHERE id = _o.customer_id
    RETURNING points_balance INTO _balance;

    IF _take > 0 THEN
      INSERT INTO public.customer_points_transactions
        (company_id, customer_id, order_id, kind, points, balance_after, description, created_by)
      VALUES (_o.company_id, _o.customer_id, _order_id, 'refund', -_take, _balance,
        'Points reversed on item refund ' || COALESCE(_o.order_number,''), _profile);
    END IF;
  END IF;

  -- Did every line get fully refunded (or voided)?
  SELECT COALESCE(bool_and(t.remaining = 0), false) INTO _all_done
  FROM (
    SELECT oi.quantity
           - COALESCE(ref.refunded_qty, 0)
           - CASE WHEN oi.status = 'voided' THEN oi.quantity ELSE 0 END AS remaining
    FROM public.order_items oi
    LEFT JOIN (
      SELECT e->>'order_item_id' AS iid, SUM((e->>'quantity')::int) AS refunded_qty
      FROM public.order_refunds r,
           jsonb_array_elements(COALESCE(r.items_payload,'[]'::jsonb)) e
      WHERE r.order_id = _order_id AND r.status = 'active' AND r.origin = 'manual'
      GROUP BY 1
    ) ref ON ref.iid = oi.id::text
    WHERE oi.order_id = _order_id
  ) t;

  _new_status := CASE WHEN _all_done THEN 'refunded' ELSE 'partially_refunded' END;
  UPDATE public.orders
  SET status = _new_status::public.order_status, updated_at = now()
  WHERE id = _order_id;

  IF _all_done AND _o.customer_id IS NOT NULL THEN
    UPDATE public.customers
    SET visits = GREATEST(COALESCE(visits,1) - 1, 0), updated_at = now()
    WHERE id = _o.customer_id;
  END IF;

  PERFORM public.log_audit('order.refund_items', 'pos', 'orders', _order_id,
    jsonb_build_object('paid', _paid, 'refunded_before', _already),
    jsonb_build_object('refund_id', _refund_id, 'amount', _amount,
      'items', _payload, 'status', _new_status, 'points_reversed', GREATEST(_take,0)),
    _reason, _o.branch_id);

  RETURN jsonb_build_object('refund_id', _refund_id, 'amount', _amount,
    'kind', CASE WHEN _all_done THEN 'full' ELSE 'partial' END,
    'status', _new_status, 'points_reversed', GREATEST(_take,0));
END;
$$;

-- ======================================================
-- (D) Reports count 'pending' orders (money already collected)
-- ======================================================
DO $$
DECLARE src text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO src FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'period_pnl';
  IF src IS NOT NULL THEN
    src := replace(src, 'o.status IN (''completed'',''refunded'')',
                         'o.status IN (''pending'',''completed'',''refunded'')');
    src := replace(src, 'o.status = ''completed'' AND oi.status = ''active''',
                         'o.status IN (''pending'',''completed'',''refunded'') AND oi.status = ''active''');
    EXECUTE src;
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO src FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'sales_period_summary';
  IF src IS NOT NULL THEN
    src := replace(src, 'o.status IN (''completed'',''refunded'')',
                         'o.status IN (''pending'',''completed'',''refunded'')');
    src := replace(src, 'o.status = ''completed'' AND oi.status = ''active''',
                         'o.status IN (''pending'',''completed'',''refunded'') AND oi.status = ''active''');
    EXECUTE src;
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO src FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'orders_period_summary';
  IF src IS NOT NULL THEN
    src := replace(src, 'o.status IN (''completed'',''refunded'')',
                         'o.status IN (''pending'',''completed'',''refunded'')');
    src := replace(src, '''refunded'', COUNT(*) FILTER (WHERE o.status = ''refunded''),',
                         '''refunded'', COUNT(*) FILTER (WHERE o.status = ''refunded''),
    ''pending'', COUNT(*) FILTER (WHERE o.status = ''pending''),');
    src := replace(src, 'AND (_status IS NULL OR o.status::text = _status);',
                         'AND (_status IS NULL OR o.status::text = _status
      OR (_status = ''refunded'' AND o.status = ''partially_refunded''));');
    EXECUTE src;
  END IF;
END $$;

-- ======================================================
-- (E) run_payroll: deduct unsettled penalties
-- ======================================================
CREATE OR REPLACE FUNCTION public.run_payroll(_period_start date, _period_end date)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_company uuid := public.current_company_id();
  v_actor uuid := public.current_profile_id();
  v_count integer := 0;
  v_active integer := 0;
  r record;
  v_advances numeric;
  v_absent integer;
  v_absence numeric;
  v_penalties numeric;
  v_deduction numeric;
  v_payment uuid;
BEGIN
  IF NOT public.has_permission('payroll.manage') THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF _period_start IS NULL OR _period_end IS NULL OR _period_end < _period_start THEN
    RAISE EXCEPTION 'invalid payroll period';
  END IF;

  SELECT count(*) INTO v_active
  FROM public.employee_salaries s
  WHERE s.company_id = v_company AND s.is_active;

  IF v_active = 0 THEN
    RAISE EXCEPTION 'No active employee salaries are defined. Add salaries first.';
  END IF;

  FOR r IN
    SELECT s.user_id, s.base_salary
    FROM public.employee_salaries s
    WHERE s.company_id = v_company
      AND s.is_active
      AND NOT EXISTS (
        SELECT 1 FROM public.salary_payments p
        WHERE p.user_id = s.user_id
          AND p.period_start = _period_start
          AND p.status = 'active'
      )
  LOOP
    SELECT COALESCE(sum(a.amount), 0) INTO v_advances
    FROM public.employee_advances a
    WHERE a.user_id = r.user_id
      AND a.status = 'active'
      AND a.settled_payment_id IS NULL
      AND a.advance_date <= _period_end;

    SELECT count(*) INTO v_absent
    FROM public.attendance at
    WHERE at.user_id = r.user_id
      AND at.company_id = v_company
      AND at.status = 'absent'
      AND at.work_date BETWEEN _period_start AND _period_end;

    SELECT COALESCE(sum(sp.amount), 0) INTO v_penalties
    FROM public.staff_penalties sp
    WHERE sp.company_id = v_company
      AND sp.staff_id = r.user_id
      AND sp.is_settled = false
      AND sp.payroll_id IS NULL
      AND sp.created_at::date BETWEEN _period_start AND _period_end;

    v_absence := round(COALESCE(r.base_salary, 0) / 30.0 * COALESCE(v_absent, 0), 2);
    v_advances := LEAST(v_advances, r.base_salary);
    v_deduction := round(LEAST(v_advances + v_absence + COALESCE(v_penalties, 0), r.base_salary), 2);

    INSERT INTO public.salary_payments (
      company_id, user_id, period_start, period_end, base_amount, bonus, deduction, created_by
    ) VALUES (
      v_company, r.user_id, _period_start, _period_end, r.base_salary, 0, v_deduction, v_actor
    ) RETURNING id INTO v_payment;

    IF v_advances > 0 THEN
      UPDATE public.employee_advances
      SET settled_payment_id = v_payment, settled_at = now()
      WHERE user_id = r.user_id
        AND status = 'active'
        AND settled_payment_id IS NULL
        AND advance_date <= _period_end;
    END IF;

    IF COALESCE(v_penalties, 0) > 0 THEN
      UPDATE public.staff_penalties
      SET is_settled = true, payroll_id = v_payment
      WHERE company_id = v_company
        AND staff_id = r.user_id
        AND is_settled = false
        AND payroll_id IS NULL
        AND created_at::date BETWEEN _period_start AND _period_end;
    END IF;

    v_count := v_count + 1;
  END LOOP;

  IF v_count = 0 THEN RAISE EXCEPTION 'payroll already generated for this period'; END IF;

  PERFORM public.log_audit('payroll.run', 'payroll', NULL, NULL, NULL,
    jsonb_build_object('period_start', _period_start, 'count', v_count));
  RETURN v_count;
END;
$function$;