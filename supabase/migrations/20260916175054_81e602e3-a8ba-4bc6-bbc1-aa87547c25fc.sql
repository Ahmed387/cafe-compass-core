-- 1) Notifications can be dismissed by their owner (super admins may clear any).
DROP POLICY IF EXISTS notif_delete ON public.notifications;
CREATE POLICY notif_delete ON public.notifications
  FOR DELETE TO authenticated
  USING (
    company_id = public.current_company_id()
    AND (user_id = public.current_profile_id() OR public.is_super_admin())
  );
GRANT DELETE ON public.notifications TO authenticated;

-- 2) Shift open: notify partners + super admins.
CREATE OR REPLACE FUNCTION public.open_shift(_branch_id uuid, _opening_cash numeric DEFAULT 0)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _profile uuid := public.current_profile_id(); _company uuid := public.current_company_id(); _id uuid; _other uuid;
  _name text; _tz text; _when text;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('shifts.open') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF NOT public.can_access_branch(_branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF EXISTS (SELECT 1 FROM public.shifts WHERE branch_id = _branch_id AND user_id = _profile AND status = 'open') THEN
    RAISE EXCEPTION 'You already have an open shift';
  END IF;
  SELECT s.user_id INTO _other FROM public.shifts s
  WHERE s.branch_id = _branch_id AND s.status = 'open' LIMIT 1;
  IF _other IS NOT NULL THEN
    RAISE EXCEPTION 'Another shift is already open on this branch and must be closed first';
  END IF;
  INSERT INTO public.shifts (company_id, branch_id, user_id, opening_cash)
  VALUES (_company, _branch_id, _profile, COALESCE(_opening_cash, 0)) RETURNING id INTO _id;
  PERFORM public.log_audit('shift.open','pos','shifts',_id,NULL,jsonb_build_object('opening_cash',_opening_cash),NULL,_branch_id);

  SELECT COALESCE(NULLIF(up.display_name,''), up.first_name) INTO _name FROM public.user_profiles up WHERE up.id = _profile;
  SELECT COALESCE(NULLIF(c.timezone,''),'Africa/Cairo') INTO _tz FROM public.companies c WHERE c.id = _company;
  _when := to_char(now() AT TIME ZONE _tz, 'HH24:MI');

  INSERT INTO public.notifications (company_id, branch_id, user_id, type, severity, title, body, data)
  SELECT _company, _branch_id, tgt.profile_id, 'shift.open', 'info', 'بدء وردية جديدة',
    'قام ' || COALESCE(_name,'الكاشير') || ' ببدء وردية جديدة الساعة ' || _when ||
    ' بعهدة افتتاحية ' || to_char(COALESCE(_opening_cash,0),'FM999999990.00') || ' ج.م',
    jsonb_build_object('shift_id', _id, 'opening_cash', COALESCE(_opening_cash,0))
  FROM (
    SELECT up.id AS profile_id
    FROM public.user_profiles up
    JOIN public.user_roles ur ON ur.user_id = up.id
    JOIN public.roles r ON r.id = ur.role_id
    WHERE up.company_id = _company AND up.is_active AND r.key = 'super_admin'
    UNION
    SELECT pa.user_id
    FROM public.partners pa
    WHERE pa.company_id = _company AND pa.status = 'active' AND pa.user_id IS NOT NULL
  ) tgt;

  RETURN _id;
END $$;

-- 3) Shift close: post to treasury (unchanged) + profit notifications.
CREATE OR REPLACE FUNCTION public.close_shift(_shift_id uuid, _closing_cash numeric, _notes text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _s public.shifts; _expected numeric; _cash_in numeric := 0; _cash_out numeric := 0;
  _profile uuid := public.current_profile_id(); _acc uuid; _company uuid;
  _sales numeric := 0; _cogs numeric := 0; _net numeric := 0; _capital numeric := 0;
  _name text; _tz text; _from text; _to text; _pct numeric; _share numeric; _r record;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO _s FROM public.shifts WHERE id = _shift_id;
  IF _s.id IS NULL THEN RAISE EXCEPTION 'Shift not found'; END IF;
  IF _s.status = 'closed' THEN RAISE EXCEPTION 'Shift already closed'; END IF;
  IF NOT (public.has_permission('shifts.close') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF NOT public.can_access_branch(_s.branch_id) THEN RAISE EXCEPTION 'Not authorized for this branch'; END IF;
  IF _s.user_id <> _profile AND NOT (public.has_permission('shifts.adjust_cash') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'You can only close your own shift';
  END IF;

  SELECT COALESCE(SUM(p.amount),0) INTO _cash_in
  FROM public.orders o JOIN public.order_payments p ON p.order_id = o.id
  WHERE o.shift_id = _shift_id AND o.status <> 'cancelled' AND p.method_key = 'cash';

  SELECT COALESCE(SUM(r.amount),0) INTO _cash_out
  FROM public.order_refunds r
  WHERE r.shift_id = _shift_id AND r.status = 'active' AND COALESCE(r.method_key,'cash') = 'cash';

  _expected := _s.opening_cash + _cash_in - _cash_out;

  UPDATE public.shifts SET status = 'closed', closing_cash = _closing_cash, expected_cash = _expected,
    variance = COALESCE(_closing_cash,0) - _expected, notes = _notes, closed_at = now(), closed_by = _profile
  WHERE id = _shift_id;

  SELECT company_id INTO _company FROM public.branches WHERE id = _s.branch_id;
  _acc := public.default_cash_account(_company, 'cash');
  IF _acc IS NOT NULL AND COALESCE(_closing_cash,0) - _s.opening_cash > 0 THEN
    PERFORM public.post_cash_txn(_company, _acc, 'in',
      round(COALESCE(_closing_cash,0) - _s.opening_cash, 2), 'shift_deposit', 'cash', CURRENT_DATE,
      'shift', _shift_id, 'Shift cash deposit', NULL, false);
  END IF;

  PERFORM public.log_audit('shift.close','pos','shifts',_shift_id,NULL,
    jsonb_build_object('closing_cash',_closing_cash,'expected_cash',_expected),_notes,_s.branch_id);

  -- Shift profitability: sales of active items minus their recipe cost.
  SELECT COALESCE(SUM(oi.line_total),0), COALESCE(SUM(oi.unit_cost * oi.quantity),0)
  INTO _sales, _cogs
  FROM public.orders o
  JOIN public.order_items oi ON oi.order_id = o.id
  WHERE o.shift_id = _shift_id AND o.status <> 'cancelled' AND oi.status = 'active';
  _net := round(_sales - _cogs, 2);

  SELECT COALESCE(NULLIF(up.display_name,''), up.first_name) INTO _name
  FROM public.user_profiles up WHERE up.id = _s.user_id;
  SELECT COALESCE(NULLIF(c.timezone,''),'Africa/Cairo') INTO _tz FROM public.companies c WHERE c.id = _company;
  _from := to_char(_s.opened_at AT TIME ZONE _tz, 'HH24:MI');
  _to := to_char(now() AT TIME ZONE _tz, 'HH24:MI');

  SELECT COALESCE(SUM(cc.amount),0) INTO _capital
  FROM public.partner_capital_contributions cc
  JOIN public.partners pa ON pa.id = cc.partner_id
  WHERE cc.company_id = _company AND cc.status = 'active' AND pa.status = 'active';

  FOR _r IN
    SELECT pa.id, pa.user_id, COALESCE(SUM(cc.amount),0) AS capital
    FROM public.partners pa
    LEFT JOIN public.partner_capital_contributions cc
      ON cc.partner_id = pa.id AND cc.status = 'active'
    WHERE pa.company_id = _company AND pa.status = 'active' AND pa.user_id IS NOT NULL
    GROUP BY pa.id, pa.user_id
  LOOP
    _pct := CASE WHEN _capital > 0 THEN round(_r.capital / _capital * 100, 2) ELSE 0 END;
    _share := round(_net * _pct / 100, 2);
    INSERT INTO public.notifications (company_id, branch_id, user_id, type, severity, title, body, data)
    VALUES (_company, _s.branch_id, _r.user_id, 'shift.close', 'info', 'تقرير تقفيل وردية وأرباح',
      'أغلقت وردية ' || COALESCE(_name,'الكاشير') || ' (من ' || _from || ' إلى ' || _to || '). صافي ربح الوردية: ' ||
      to_char(_net,'FM999999990.00') || ' ج.م. نصيب أرباحك الصافي منها (' || to_char(_pct,'FM999990.00') || '%): ' ||
      to_char(_share,'FM999999990.00') || ' ج.م',
      jsonb_build_object('shift_id', _shift_id, 'sales', _sales, 'cogs', _cogs,
        'net_profit', _net, 'percentage', _pct, 'partner_share', _share));
  END LOOP;

  INSERT INTO public.notifications (company_id, branch_id, user_id, type, severity, title, body, data)
  SELECT _company, _s.branch_id, up.id, 'shift.close', 'info', 'تقرير تقفيل وردية وأرباح',
    'أغلقت وردية ' || COALESCE(_name,'الكاشير') || ' (من ' || _from || ' إلى ' || _to || '). إجمالي المبيعات: ' ||
    to_char(_sales,'FM999999990.00') || ' ج.م، تكلفة البضاعة: ' || to_char(_cogs,'FM999999990.00') ||
    ' ج.م، صافي ربح الوردية: ' || to_char(_net,'FM999999990.00') || ' ج.م.',
    jsonb_build_object('shift_id', _shift_id, 'sales', _sales, 'cogs', _cogs, 'net_profit', _net)
  FROM public.user_profiles up
  JOIN public.user_roles ur ON ur.user_id = up.id
  JOIN public.roles r ON r.id = ur.role_id
  WHERE up.company_id = _company AND up.is_active AND r.key = 'super_admin';

  RETURN _shift_id;
END $$;

-- 4) Super-admin only operational reset. Catalog, people and settings are preserved.
CREATE OR REPLACE FUNCTION public.reset_operational_data(p_confirm text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _company uuid := public.current_company_id(); _profile uuid := public.current_profile_id();
  _tbl text; _counts jsonb := '{}'::jsonb; _n bigint;
  _guarded text[] := ARRAY['orders','order_items','order_payments','order_refunds','purchases','purchase_items',
    'expenses','stock_movements','cash_transactions','customer_vouchers','shifts'];
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF p_confirm <> 'RESET-20S' THEN RAISE EXCEPTION 'Confirmation text does not match'; END IF;

  FOREACH _tbl IN ARRAY _guarded LOOP
    EXECUTE format('ALTER TABLE public.%I DISABLE TRIGGER USER', _tbl);
  END LOOP;

  DELETE FROM public.order_item_modifiers m USING public.order_items oi, public.orders o
    WHERE m.order_item_id = oi.id AND oi.order_id = o.id AND o.company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('order_item_modifiers', _n);

  DELETE FROM public.order_refunds WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('order_refunds', _n);
  DELETE FROM public.order_payments p USING public.orders o WHERE p.order_id = o.id AND o.company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('order_payments', _n);
  DELETE FROM public.order_items oi USING public.orders o WHERE oi.order_id = o.id AND o.company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('order_items', _n);
  DELETE FROM public.customer_points_transactions WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('customer_points_transactions', _n);
  DELETE FROM public.customer_vouchers WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('customer_vouchers', _n);
  DELETE FROM public.orders WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('orders', _n);
  DELETE FROM public.order_counters WHERE branch_id IN (SELECT id FROM public.branches WHERE company_id = _company);
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('order_counters', _n);
  DELETE FROM public.shifts WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('shifts', _n);
  DELETE FROM public.purchase_return_items ri USING public.purchase_returns pr
    WHERE ri.purchase_return_id = pr.id AND pr.company_id = _company;
  DELETE FROM public.purchase_returns WHERE company_id = _company;
  DELETE FROM public.purchase_payments WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('purchase_payments', _n);
  DELETE FROM public.purchase_items pi USING public.purchases pu WHERE pi.purchase_id = pu.id AND pu.company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('purchase_items', _n);
  DELETE FROM public.purchases WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('purchases', _n);
  DELETE FROM public.expenses WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('expenses', _n);
  DELETE FROM public.stock_movements WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('stock_movements', _n);
  DELETE FROM public.cash_transactions WHERE company_id = _company;
  GET DIAGNOSTICS _n = ROW_COUNT; _counts := _counts || jsonb_build_object('cash_transactions', _n);

  UPDATE public.branch_stock SET quantity = 0
   WHERE branch_id IN (SELECT id FROM public.branches WHERE company_id = _company);
  UPDATE public.cash_accounts SET opening_balance = 0 WHERE company_id = _company;
  UPDATE public.customers SET points_balance = 0 WHERE company_id = _company;

  FOREACH _tbl IN ARRAY _guarded LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE TRIGGER USER', _tbl);
  END LOOP;

  PERFORM public.log_audit('system.reset_operational','settings','companies',_company,NULL,_counts,NULL,NULL);
  RETURN _counts;
END $$;

REVOKE ALL ON FUNCTION public.reset_operational_data(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reset_operational_data(text) TO authenticated, service_role;