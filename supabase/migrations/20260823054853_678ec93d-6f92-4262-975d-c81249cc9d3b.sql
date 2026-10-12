-- 1) Auto-closed shifts must deposit the drawer cash into the central safe
CREATE OR REPLACE FUNCTION public.auto_close_due_shifts()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE _s public.shifts; _policy public.shift_policies; _close timestamptz;
  _closed integer := 0; _expected numeric; _cash_in numeric; _cash_out numeric;
  _acc uuid; _deposit numeric;
BEGIN
  FOR _s IN SELECT * FROM public.shifts WHERE status = 'open' LOOP
    SELECT * INTO _policy FROM public.shift_policies WHERE company_id = _s.company_id;
    _close := public.work_day_close_at(_s.company_id, _s.opened_at);
    IF _close IS NOT NULL AND _close <= _s.opened_at THEN
      _close := public.work_day_close_at(_s.company_id, _s.opened_at + interval '1 day');
    END IF;
    IF _close IS NULL THEN CONTINUE; END IF;

    IF now() >= _close - make_interval(mins => COALESCE(_policy.warn_minutes, 30))
       AND now() < _close THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.notifications
        WHERE company_id = _s.company_id AND type = 'shift.closing_soon'
          AND data->>'shift_id' = _s.id::text
      ) THEN
        INSERT INTO public.notifications (company_id, branch_id, user_id, type, severity, title, body, data)
        VALUES (_s.company_id, _s.branch_id, _s.user_id, 'shift.closing_soon', 'warning',
          'Shift closing soon',
          'The open shift will be closed automatically at the end of working hours.',
          jsonb_build_object('shift_id', _s.id, 'closes_at', _close));
        INSERT INTO public.notifications (company_id, branch_id, required_permission, type, severity, title, body, data)
        VALUES (_s.company_id, _s.branch_id, 'shifts.close', 'shift.closing_soon', 'warning',
          'Shift closing soon',
          'An open shift will be closed automatically at the end of working hours.',
          jsonb_build_object('shift_id', _s.id, 'closes_at', _close));
      END IF;
    END IF;

    IF COALESCE(_policy.auto_close, true) AND now() >= _close THEN
      SELECT COALESCE(SUM(p.amount),0) INTO _cash_in
      FROM public.orders o JOIN public.order_payments p ON p.order_id = o.id
      WHERE o.shift_id = _s.id AND o.status <> 'cancelled' AND p.method_key = 'cash';
      SELECT COALESCE(SUM(r.amount),0) INTO _cash_out
      FROM public.order_refunds r
      WHERE r.shift_id = _s.id AND r.status = 'active' AND COALESCE(r.method_key,'cash') = 'cash';
      _expected := _s.opening_cash + _cash_in - _cash_out;

      UPDATE public.shifts SET status = 'closed', closing_cash = _expected, expected_cash = _expected,
        variance = 0, closed_at = LEAST(now(), _close),
        notes = COALESCE(notes || ' | ', '') || 'Auto-closed at end of working hours'
      WHERE id = _s.id;

      -- Same treasury deposit the manual closure performs
      _deposit := round(_expected - _s.opening_cash, 2);
      _acc := public.default_cash_account(_s.company_id, 'cash');
      IF _acc IS NOT NULL AND _deposit > 0 THEN
        PERFORM public.post_cash_txn(_s.company_id, _acc, 'in', _deposit, 'shift_deposit', 'cash',
          (LEAST(now(), _close))::date, 'shift', _s.id, 'Shift cash deposit (auto-close)', NULL, false);
      END IF;

      INSERT INTO public.notifications (company_id, branch_id, required_permission, type, severity, title, body, data)
      VALUES (_s.company_id, _s.branch_id, 'shifts.view', 'shift.auto_closed', 'info',
        'Shift auto-closed',
        'The forgotten shift was closed automatically at the end of working hours.',
        jsonb_build_object('shift_id', _s.id, 'expected_cash', _expected, 'deposited', GREATEST(_deposit,0)));

      INSERT INTO public.audit_logs (company_id, branch_id, action, module, entity_type, entity_id, new_values, reason)
      VALUES (_s.company_id, _s.branch_id, 'shift.auto_close', 'pos', 'shifts', _s.id,
        jsonb_build_object('expected_cash', _expected, 'deposited', GREATEST(_deposit,0)),
        'Automatic end-of-day closure');

      _closed := _closed + 1;
    END IF;
  END LOOP;
  RETURN _closed;
END
$fn$;

-- 2) Refunds reverse the loyalty points, spending total and visit count
CREATE OR REPLACE FUNCTION public.refund_order(_order_id uuid, _amount numeric, _reason text, _method_key text DEFAULT 'cash'::text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE _profile uuid := public.current_profile_id(); _o public.orders;
  _paid numeric := 0; _already numeric := 0; _remaining numeric; _tax_share numeric := 0;
  _kind text; _id uuid; _r record;
  _earned int := 0; _reversed int := 0; _take int := 0; _balance int;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('pos.process_refund') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF _reason IS NULL OR length(btrim(_reason)) < 3 THEN RAISE EXCEPTION 'A reason is required'; END IF;

  SELECT * INTO _o FROM public.orders WHERE id = _order_id;
  IF _o.id IS NULL THEN RAISE EXCEPTION 'Order not found'; END IF;
  IF NOT public.can_access_branch(_o.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _o.status <> 'completed' THEN RAISE EXCEPTION 'Only completed orders can be refunded'; END IF;

  SELECT COALESCE(SUM(amount),0) INTO _paid FROM public.order_payments WHERE order_id = _order_id;
  SELECT COALESCE(SUM(amount),0) INTO _already
  FROM public.order_refunds WHERE order_id = _order_id AND status = 'active';

  _remaining := round(_paid - _already, 2);
  IF _remaining <= 0 THEN RAISE EXCEPTION 'This order is fully refunded'; END IF;
  IF _amount IS NULL OR _amount <= 0 THEN RAISE EXCEPTION 'Refund amount must be greater than zero'; END IF;
  IF round(_amount,2) > _remaining THEN
    RAISE EXCEPTION 'Refund (%) is more than the refundable amount (%)', round(_amount,2), _remaining;
  END IF;

  IF _paid > 0 AND _o.tax_amount > 0 THEN
    _tax_share := round(_o.tax_amount * LEAST(round(_amount,2) / _paid, 1), 2);
  END IF;
  _kind := CASE WHEN round(_amount,2) = _remaining THEN 'full' ELSE 'partial' END;

  INSERT INTO public.order_refunds (company_id, branch_id, order_id, shift_id, kind, amount,
    tax_amount, method_key, reason, created_by)
  VALUES (_o.company_id, _o.branch_id, _o.id, _o.shift_id, _kind, round(_amount,2),
    _tax_share, COALESCE(NULLIF(_method_key,''),'cash'), _reason, _profile)
  RETURNING id INTO _id;

  IF _kind = 'full' THEN
    FOR _r IN SELECT id FROM public.order_items WHERE order_id = _order_id AND status = 'active' LOOP
      PERFORM public.return_line_stock(_r.id);
    END LOOP;
    UPDATE public.orders SET status = 'refunded', updated_at = now() WHERE id = _order_id;
  END IF;

  -- Loyalty reversal: take back the share of points that belongs to the refunded value
  IF _o.customer_id IS NOT NULL THEN
    SELECT COALESCE(SUM(points),0) INTO _earned
    FROM public.customer_points_transactions
    WHERE order_id = _order_id AND kind = 'earn';

    SELECT COALESCE(-SUM(points),0) INTO _reversed
    FROM public.customer_points_transactions
    WHERE order_id = _order_id AND kind = 'refund';

    IF _earned > 0 AND _paid > 0 THEN
      IF _kind = 'full' THEN
        _take := _earned - _reversed;
      ELSE
        _take := LEAST(round(_earned * (round(_amount,2) / _paid))::int, _earned - _reversed);
      END IF;
      IF _take > 0 THEN
        SELECT points_balance INTO _balance FROM public.customers WHERE id = _o.customer_id;
        _take := LEAST(_take, GREATEST(COALESCE(_balance,0), 0));
      END IF;
    END IF;

    UPDATE public.customers
    SET points_balance = GREATEST(points_balance - GREATEST(_take,0), 0),
        total_spent = GREATEST(total_spent - round(_amount,2), 0),
        visits = CASE WHEN _kind = 'full' THEN GREATEST(visits - 1, 0) ELSE visits END,
        updated_at = now()
    WHERE id = _o.customer_id
    RETURNING points_balance INTO _balance;

    IF _take > 0 THEN
      INSERT INTO public.customer_points_transactions
        (company_id, customer_id, order_id, kind, points, balance_after, description, created_by)
      VALUES (_o.company_id, _o.customer_id, _order_id, 'refund', -_take, _balance,
        'Points reversed on refund ' || COALESCE(_o.order_number,''), _profile);
    END IF;
  END IF;

  PERFORM public.log_audit('order.refund','pos','orders',_order_id,
    jsonb_build_object('paid',_paid,'refunded_before',_already),
    jsonb_build_object('refund_amount',round(_amount,2),'kind',_kind,'points_reversed',GREATEST(_take,0)),
    _reason, _o.branch_id);
  RETURN _id;
END
$fn$;

-- 3) Only approved expenses hit the profit statement (cash leaves the safe on approval)
CREATE OR REPLACE FUNCTION public.period_pnl(_period_id uuid)
RETURNS TABLE(revenue numeric, tax_collected numeric, cogs numeric, waste_cost numeric, refunds_total numeric, expenses_total numeric, payroll_total numeric, net_profit numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE _p public.accounting_periods;
  _rev numeric := 0; _tax numeric := 0; _cogs numeric := 0; _waste numeric := 0;
  _ref numeric := 0; _ref_tax numeric := 0; _ref_all numeric := 0; _exp numeric := 0; _pay numeric := 0;
BEGIN
  IF NOT (public.has_permission('reports.profit') OR public.has_permission('partners.view_profit') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  SELECT * INTO _p FROM public.accounting_periods WHERE id = _period_id AND company_id = public.current_company_id();
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Period not found'; END IF;

  SELECT COALESCE(SUM(o.total - o.tax_amount),0), COALESCE(SUM(o.tax_amount),0)
    INTO _rev, _tax
  FROM public.orders o
  WHERE o.company_id = _p.company_id AND o.status IN ('completed','refunded')
    AND o.created_at::date BETWEEN _p.start_date AND _p.end_date;

  SELECT COALESCE(SUM(oi.unit_cost * oi.quantity),0) INTO _cogs
  FROM public.order_items oi JOIN public.orders o ON o.id = oi.order_id
  WHERE o.company_id = _p.company_id AND o.status = 'completed' AND oi.status = 'active'
    AND o.created_at::date BETWEEN _p.start_date AND _p.end_date;

  SELECT COALESCE(SUM(-sm.quantity * sm.unit_cost),0) INTO _waste
  FROM public.stock_movements sm
  WHERE sm.company_id = _p.company_id
    AND sm.movement_type IN ('waste','stocktake')
    AND sm.quantity < 0
    AND sm.created_at::date BETWEEN _p.start_date AND _p.end_date;

  SELECT COALESCE(SUM(r.amount) FILTER (WHERE r.origin = 'manual'),0),
         COALESCE(SUM(r.tax_amount) FILTER (WHERE r.origin = 'manual'),0),
         COALESCE(SUM(r.amount),0)
    INTO _ref, _ref_tax, _ref_all
  FROM public.order_refunds r JOIN public.orders o ON o.id = r.order_id
  WHERE r.company_id = _p.company_id AND r.status = 'active'
    AND o.status IN ('completed','refunded','cancelled')
    AND r.created_at::date BETWEEN _p.start_date AND _p.end_date;

  SELECT COALESCE(SUM(e.amount),0) INTO _exp FROM public.expenses e
  WHERE e.company_id = _p.company_id AND e.status = 'active' AND e.approved_at IS NOT NULL
    AND e.expense_date BETWEEN _p.start_date AND _p.end_date;

  SELECT COALESCE(SUM(s.net_amount),0) INTO _pay FROM public.salary_payments s
  WHERE s.company_id = _p.company_id AND s.status = 'active'
    AND s.period_start <= _p.end_date AND s.period_end >= _p.start_date;

  RETURN QUERY SELECT round(_rev - (_ref - _ref_tax),2), round(_tax - _ref_tax,2),
    round(_cogs,2), round(_waste,2), round(_ref_all,2), round(_exp,2), round(_pay,2),
    round((_rev - (_ref - _ref_tax)) - _cogs - _waste - _exp - _pay, 2);
END
$fn$;

CREATE OR REPLACE FUNCTION public.monthly_operating_costs(_from date, _to date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE _company uuid := public.current_company_id();
  _sales numeric := 0; _tax numeric := 0; _cogs numeric := 0; _waste numeric := 0;
  _purchases numeric := 0; _purch_paid numeric := 0; _payroll numeric := 0; _advances numeric := 0;
  _expenses numeric := 0; _exp_pending numeric := 0; _items jsonb; _cats jsonb;
BEGIN
  IF NOT (public.has_permission('reports.profit') OR public.has_permission('treasury.view')
          OR public.has_permission('partners.view_profit') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT COALESCE(SUM(o.total - o.tax_amount),0), COALESCE(SUM(o.tax_amount),0) INTO _sales, _tax
  FROM public.orders o WHERE o.company_id = _company AND o.status IN ('completed','refunded')
    AND o.created_at::date BETWEEN _from AND _to;

  SELECT COALESCE(SUM(oi.unit_cost * oi.quantity),0) INTO _cogs
  FROM public.order_items oi JOIN public.orders o ON o.id = oi.order_id
  WHERE o.company_id = _company AND o.status = 'completed' AND oi.status = 'active'
    AND o.created_at::date BETWEEN _from AND _to;

  SELECT COALESCE(SUM(-sm.quantity * sm.unit_cost),0) INTO _waste
  FROM public.stock_movements sm
  WHERE sm.company_id = _company AND sm.movement_type IN ('waste','stocktake') AND sm.quantity < 0
    AND sm.created_at::date BETWEEN _from AND _to;

  SELECT COALESCE(SUM(p.total - p.returned_amount),0), COALESCE(SUM(p.paid_amount),0)
    INTO _purchases, _purch_paid
  FROM public.purchases p WHERE p.company_id = _company AND p.status <> 'cancelled'
    AND p.purchase_date BETWEEN _from AND _to;

  SELECT COALESCE(SUM(s.net_amount),0) INTO _payroll FROM public.salary_payments s
  WHERE s.company_id = _company AND s.status = 'active'
    AND s.period_start <= _to AND s.period_end >= _from;

  SELECT COALESCE(SUM(a.amount),0) INTO _advances FROM public.employee_advances a
  WHERE a.company_id = _company AND a.status = 'active' AND a.advance_date BETWEEN _from AND _to;

  SELECT COALESCE(SUM(e.amount) FILTER (WHERE e.approved_at IS NOT NULL),0),
         COALESCE(SUM(e.amount) FILTER (WHERE e.approved_at IS NULL),0)
    INTO _expenses, _exp_pending
  FROM public.expenses e
  WHERE e.company_id = _company AND e.status = 'active' AND e.expense_date BETWEEN _from AND _to;

  SELECT COALESCE(jsonb_agg(x ORDER BY x->>'cost' DESC), '[]'::jsonb) INTO _items FROM (
    SELECT jsonb_build_object('item', i.name, 'item_ar', i.name_ar, 'unit', i.unit,
      'qty', round(SUM(-sm.quantity),3), 'cost', round(SUM(-sm.quantity * sm.unit_cost),2)) AS x
    FROM public.stock_movements sm JOIN public.inventory_items i ON i.id = sm.item_id
    WHERE sm.company_id = _company AND sm.quantity < 0
      AND sm.movement_type IN ('sale_consumption','waste','adjustment','stocktake')
      AND sm.created_at::date BETWEEN _from AND _to
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
    'sales', round(_sales,2), 'tax', round(_tax,2),
    'cogs', round(_cogs,2), 'waste', round(_waste,2),
    'purchases_total', round(_purchases,2), 'purchases_paid', round(_purch_paid,2),
    'purchases_due', round(_purchases - _purch_paid,2),
    'payroll', round(_payroll,2), 'advances', round(_advances,2),
    'expenses', round(_expenses,2), 'expenses_pending', round(_exp_pending,2),
    'operating_total', round(_cogs + _waste + _payroll + _expenses,2),
    'consumption', COALESCE(_items,'[]'::jsonb),
    'expense_breakdown', COALESCE(_cats,'[]'::jsonb)
  );
END
$fn$;

-- 4) Automatic periods must align to calendar months and never overlap an existing period
CREATE OR REPLACE FUNCTION public.ensure_open_periods()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE _c record; _created integer := 0; _start date; _end date;
BEGIN
  _start := date_trunc('month', CURRENT_DATE)::date;
  _end := (date_trunc('month', CURRENT_DATE) + interval '1 month - 1 day')::date;
  FOR _c IN SELECT id FROM public.companies LOOP
    IF NOT EXISTS (
      SELECT 1 FROM public.accounting_periods ap
      WHERE ap.company_id = _c.id
        AND ap.start_date <= _end AND ap.end_date >= _start
    ) THEN
      INSERT INTO public.accounting_periods (company_id, period_type, start_date, end_date, status, auto_created)
      VALUES (_c.id, 'monthly', _start, _end, 'open', true);
      _created := _created + 1;
    END IF;
  END LOOP;
  RETURN _created;
END
$fn$;