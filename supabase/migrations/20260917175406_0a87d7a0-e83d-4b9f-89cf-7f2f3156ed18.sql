-- 1) Super-admin expense amount correction with full audit trail
CREATE OR REPLACE FUNCTION public.correct_expense_amount(_expense_id uuid, _new_amount numeric, _reason text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE _profile uuid := public.current_profile_id(); _e public.expenses; _acc uuid; _delta numeric;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only the super admin can correct an expense amount'; END IF;
  IF _new_amount IS NULL OR _new_amount <= 0 THEN RAISE EXCEPTION 'Amount must be greater than zero'; END IF;
  IF _reason IS NULL OR length(btrim(_reason)) < 5 THEN RAISE EXCEPTION 'A correction reason is required'; END IF;

  SELECT * INTO _e FROM public.expenses
   WHERE id = _expense_id AND company_id = public.current_company_id();
  IF _e.id IS NULL THEN RAISE EXCEPTION 'Expense not found'; END IF;
  IF _e.status <> 'active' THEN RAISE EXCEPTION 'Only active expenses can be corrected'; END IF;
  PERFORM public.assert_period_open(_e.expense_date, _e.company_id);
  IF round(_e.amount, 2) = round(_new_amount, 2) THEN RAISE EXCEPTION 'The new amount matches the current amount'; END IF;

  _delta := round(_new_amount, 2) - round(_e.amount, 2);

  UPDATE public.expenses
     SET amount = round(_new_amount, 2), updated_at = now()
   WHERE id = _expense_id;

  -- Keep the cash book in step only when the expense already hit cash (approved).
  IF _e.approved_at IS NOT NULL THEN
    _acc := public.default_cash_account(_e.company_id, _e.payment_method);
    IF _acc IS NOT NULL AND _delta <> 0 THEN
      PERFORM public.post_cash_txn(_e.company_id, _acc,
        CASE WHEN _delta > 0 THEN 'out' ELSE 'in' END, abs(_delta), 'expense',
        COALESCE(NULLIF(_e.payment_method,''),'cash'), _e.expense_date, 'expense', _expense_id,
        'Expense correction: ' || btrim(_reason), NULL, false);
    END IF;
  END IF;

  PERFORM public.log_audit('expense.correct_amount','finance','expenses',_expense_id,
    jsonb_build_object('amount', _e.amount),
    jsonb_build_object('amount', round(_new_amount,2), 'delta', _delta),
    btrim(_reason), _e.branch_id);

  RETURN _expense_id;
END $function$;

REVOKE ALL ON FUNCTION public.correct_expense_amount(uuid, numeric, text) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.correct_expense_amount(uuid, numeric, text) TO authenticated, service_role;

-- 2) Refund-time operational waste is a real loss: fold it into period_pnl.waste_cost
CREATE OR REPLACE FUNCTION public.period_pnl(_period_id uuid)
RETURNS TABLE(revenue numeric, tax_collected numeric, cogs numeric, waste_cost numeric, refunds_total numeric, points_redeemed numeric, expenses_total numeric, payroll_total numeric, net_profit numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE _p public.accounting_periods;
  _rev numeric := 0; _tax numeric := 0; _cogs numeric := 0; _waste numeric := 0;
  _ref numeric := 0; _ref_tax numeric := 0; _ref_all numeric := 0; _exp numeric := 0; _pay numeric := 0;
  _pts numeric := 0; _net_rev numeric := 0; _ref_waste numeric := 0;
BEGIN
  IF NOT (public.has_permission('reports.profit') OR public.has_permission('partners.view_profit') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  SELECT * INTO _p FROM public.accounting_periods WHERE id = _period_id AND company_id = public.current_company_id();
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Period not found'; END IF;

  SELECT COALESCE(SUM(o.total - o.tax_amount),0), COALESCE(SUM(o.tax_amount),0)
    INTO _rev, _tax
  FROM public.orders o
  WHERE o.company_id = _p.company_id AND o.status IN ('pending','completed','refunded','partially_refunded')
    AND o.created_at::date BETWEEN _p.start_date AND _p.end_date;

  SELECT COALESCE(SUM(op.amount),0) INTO _pts
  FROM public.order_payments op JOIN public.orders o ON o.id = op.order_id
  WHERE o.company_id = _p.company_id AND o.status IN ('pending','completed','refunded','partially_refunded')
    AND op.method_key = 'points'
    AND o.created_at::date BETWEEN _p.start_date AND _p.end_date;

  SELECT COALESCE(SUM(oi.unit_cost * oi.quantity),0) INTO _cogs
  FROM public.order_items oi JOIN public.orders o ON o.id = oi.order_id
  WHERE o.company_id = _p.company_id AND o.status IN ('pending','completed','refunded','partially_refunded') AND oi.status = 'active'
    AND o.created_at::date BETWEEN _p.start_date AND _p.end_date;

  SELECT COALESCE(SUM(-sm.quantity * sm.unit_cost),0) INTO _waste
  FROM public.stock_movements sm
  WHERE sm.company_id = _p.company_id
    AND sm.movement_type IN ('waste','stocktake')
    AND sm.quantity < 0
    AND sm.created_at::date BETWEEN _p.start_date AND _p.end_date;

  -- Items refunded as operational waste never return to stock; their consumed
  -- recipe cost is a period loss, tracked in the refund payload.
  SELECT COALESCE(SUM(COALESCE((entry->>'unit_cost')::numeric,0) * COALESCE((entry->>'quantity')::numeric,0)),0)
    INTO _ref_waste
  FROM public.order_refunds r
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(r.items_payload,'[]'::jsonb)) AS entry
  WHERE r.company_id = _p.company_id AND r.status = 'active'
    AND entry->>'disposition' = 'waste'
    AND r.created_at::date BETWEEN _p.start_date AND _p.end_date;

  _waste := _waste + _ref_waste;

  SELECT COALESCE(SUM(r.amount) FILTER (WHERE r.origin = 'manual'),0),
         COALESCE(SUM(r.tax_amount) FILTER (WHERE r.origin = 'manual'),0),
         COALESCE(SUM(r.amount),0)
    INTO _ref, _ref_tax, _ref_all
  FROM public.order_refunds r JOIN public.orders o ON o.id = r.order_id
  WHERE r.company_id = _p.company_id AND r.status = 'active'
    AND o.status IN ('completed','refunded','partially_refunded','cancelled')
    AND r.created_at::date BETWEEN _p.start_date AND _p.end_date;

  SELECT COALESCE(SUM(e.amount),0) INTO _exp FROM public.expenses e
  WHERE e.company_id = _p.company_id AND e.status = 'active' AND e.approved_at IS NOT NULL
    AND e.expense_date BETWEEN _p.start_date AND _p.end_date;

  SELECT COALESCE(SUM(s.net_amount),0) INTO _pay FROM public.salary_payments s
  WHERE s.company_id = _p.company_id AND s.status = 'active'
    AND s.period_start <= _p.end_date AND s.period_end >= _p.start_date;

  _net_rev := _rev - (_ref - _ref_tax) - _pts;

  RETURN QUERY SELECT round(_net_rev,2), round(_tax - _ref_tax,2),
    round(_cogs,2), round(_waste,2), round(_ref_all,2), round(_pts,2),
    round(_exp,2), round(_pay,2),
    round(_net_rev - _cogs - _waste - _exp - _pay, 2);
END
$function$;

REVOKE ALL ON FUNCTION public.period_pnl(uuid) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.period_pnl(uuid) TO authenticated, service_role;

-- 3) A period may not close while orders are still awaiting handover
CREATE OR REPLACE FUNCTION public.close_accounting_period(_period_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE _profile uuid := public.current_profile_id(); _p public.accounting_periods;
  _open_shifts integer := 0; _open_orders integer := 0; _pending_orders integer := 0;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('periods.manage') OR public.has_permission('settings.manage') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT * INTO _p FROM public.accounting_periods
   WHERE id = _period_id AND company_id = public.current_company_id();
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Period not found'; END IF;
  IF _p.status = 'closed' THEN RAISE EXCEPTION 'Period is already closed'; END IF;

  SELECT count(*) INTO _open_shifts FROM public.shifts s
   WHERE s.company_id = _p.company_id AND s.status = 'open'
     AND s.opened_at::date <= _p.end_date;
  IF _open_shifts > 0 THEN
    RAISE EXCEPTION 'Close the % open shift(s) in this period first', _open_shifts;
  END IF;

  SELECT count(*) INTO _open_orders FROM public.orders o
   WHERE o.company_id = _p.company_id AND o.status = 'open'
     AND o.created_at::date BETWEEN _p.start_date AND _p.end_date;
  IF _open_orders > 0 THEN
    RAISE EXCEPTION 'Settle the % unpaid order(s) in this period first', _open_orders;
  END IF;

  SELECT count(*) INTO _pending_orders FROM public.orders o
   WHERE o.company_id = _p.company_id AND o.status = 'pending'
     AND o.created_at::date BETWEEN _p.start_date AND _p.end_date;
  IF _pending_orders > 0 THEN
    RAISE EXCEPTION 'Hand over the % order(s) still awaiting delivery in this period first', _pending_orders;
  END IF;

  UPDATE public.accounting_periods
     SET status = 'closed', closed_at = now(), closed_by = _profile
   WHERE id = _period_id;

  PERFORM public.log_audit('period.close','finance','accounting_periods',_period_id,
    jsonb_build_object('status','open'), jsonb_build_object('status','closed'), NULL, NULL);
  RETURN _period_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.close_accounting_period(uuid) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.close_accounting_period(uuid) TO authenticated, service_role;