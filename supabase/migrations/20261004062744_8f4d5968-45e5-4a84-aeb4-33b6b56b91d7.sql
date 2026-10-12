CREATE OR REPLACE FUNCTION public.can_absorb_shortage() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT EXISTS (SELECT 1 FROM public.user_roles ur JOIN public.roles r ON r.id = ur.role_id
    WHERE ur.user_id = public.current_profile_id() AND r.key IN ('super_admin','manager','partner'));
$f$;

CREATE OR REPLACE FUNCTION public.close_shift_handover(_shift_id uuid, _closing_cash numeric, _retained_float numeric, _shortage_mode text DEFAULT NULL::text, _shortage_staff_id uuid DEFAULT NULL::uuid, _notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _s public.shifts; _profile uuid := public.current_profile_id(); _expenses numeric;
  _expected numeric; _short numeric; _staff uuid[]; _n int; _each numeric; _i int; _amt numeric;
BEGIN
  SELECT * INTO _s FROM public.shifts WHERE id = _shift_id;
  IF _s.id IS NULL THEN RAISE EXCEPTION 'Shift not found'; END IF;
  IF _closing_cash IS NULL OR _closing_cash < 0 THEN RAISE EXCEPTION 'Counted cash is required'; END IF;
  IF _retained_float IS NULL OR _retained_float < 0 OR _retained_float > _closing_cash THEN
    RAISE EXCEPTION 'Retained float must be between 0 and the counted cash';
  END IF;

  _expenses := public.shift_expense_total(_shift_id);
  PERFORM public.close_shift(_shift_id, _closing_cash, _notes);
  SELECT expected_cash INTO _expected FROM public.shifts WHERE id = _shift_id;
  _expected := round(_expected - _expenses, 2);
  _short := round(_expected - _closing_cash, 2);

  IF _short > 0 THEN
    IF _shortage_mode IS NULL OR _shortage_mode NOT IN ('split','staff','venue') THEN
      RAISE EXCEPTION 'Shortage must be attributed';
    END IF;
    IF _shortage_mode = 'venue' AND NOT (public.is_super_admin() OR public.has_permission('expenses.approve') OR public.can_absorb_shortage()) THEN
      RAISE EXCEPTION 'Only a manager can approve venue-absorbed shortage';
    END IF;
    IF _shortage_mode = 'staff' THEN
      IF NOT EXISTS (SELECT 1 FROM public.shift_staff WHERE shift_id = _shift_id AND staff_id = _shortage_staff_id)
         AND _shortage_staff_id IS DISTINCT FROM _s.user_id THEN
        RAISE EXCEPTION 'Selected staff member is not on this shift';
      END IF;
      INSERT INTO public.staff_penalties (company_id, staff_id, amount, reason, shift_id, created_by)
      VALUES (_s.company_id, _shortage_staff_id, _short, 'عجز درج الوردية', _shift_id, _profile);
    ELSIF _shortage_mode = 'split' THEN
      SELECT array_agg(DISTINCT x) INTO _staff FROM (
        SELECT staff_id AS x FROM public.shift_staff WHERE shift_id = _shift_id
        UNION SELECT _s.user_id) q;
      _n := array_length(_staff,1);
      _each := floor(_short / _n * 100) / 100;
      FOR _i IN 1.._n LOOP
        _amt := CASE WHEN _i = _n THEN round(_short - _each * (_n - 1), 2) ELSE _each END;
        INSERT INTO public.staff_penalties (company_id, staff_id, amount, reason, shift_id, created_by)
        VALUES (_s.company_id, _staff[_i], _amt, 'عجز درج الوردية (موزع)', _shift_id, _profile);
      END LOOP;
    END IF;
  END IF;

  UPDATE public.shifts SET expected_cash = _expected, variance = round(_closing_cash - _expected, 2),
    shift_expenses = _expenses, retained_float = round(_retained_float,2),
    cash_drop = round(_closing_cash - _retained_float, 2),
    shortage_resolution = CASE WHEN _short > 0 THEN _shortage_mode END,
    shortage_staff_id = CASE WHEN _short > 0 AND _shortage_mode = 'staff' THEN _shortage_staff_id END
  WHERE id = _shift_id;

  PERFORM public.log_audit('shift.handover','pos','shifts',_shift_id,NULL,
    jsonb_build_object('expected',_expected,'counted',_closing_cash,'retained',_retained_float,
      'drawer_expenses',_expenses,'shortage',GREATEST(_short,0),'mode',_shortage_mode),_notes,_s.branch_id);
  RETURN jsonb_build_object('expected',_expected,'shortage',GREATEST(_short,0),'cash_drop',round(_closing_cash - _retained_float,2));
END $function$;

CREATE OR REPLACE FUNCTION public.period_pnl(_period_id uuid)
 RETURNS TABLE(gross_sales numeric, promo_discount numeric, manual_discounts numeric, points_redeemed numeric, refunds_total numeric, refund_tax_reversed numeric, partner_tab_unsettled numeric, revenue numeric, tax_collected numeric, cogs numeric, waste_cost numeric, expenses_total numeric, payroll_total numeric, gross_profit numeric, net_profit numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _p public.accounting_periods;
  _gross numeric := 0; _promo numeric := 0; _manual numeric := 0; _pts numeric := 0;
  _tax numeric := 0; _ref numeric := 0; _ref_tax numeric := 0; _tab numeric := 0;
  _cogs numeric := 0; _waste numeric := 0; _ref_waste numeric := 0;
  _exp numeric := 0; _pay numeric := 0; _net_rev numeric := 0; _gp numeric := 0;
BEGIN
  IF NOT (public.has_permission('reports.profit') OR public.has_permission('partners.view_profit') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  SELECT * INTO _p FROM public.accounting_periods WHERE id = _period_id AND company_id = public.current_company_id();
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Period not found'; END IF;

  CREATE TEMP TABLE IF NOT EXISTS _pnl_orders (order_id uuid PRIMARY KEY, on_tab boolean) ON COMMIT DROP;
  DELETE FROM _pnl_orders WHERE true;

  INSERT INTO _pnl_orders (order_id, on_tab)
  SELECT o.id,
         EXISTS (SELECT 1 FROM public.partner_tab_orders pt
                  WHERE pt.order_id = o.id AND NOT pt.is_settled)
  FROM public.orders o
  WHERE o.company_id = _p.company_id
    AND o.status IN ('pending','completed','refunded','partially_refunded')
    AND o.created_at::date BETWEEN _p.start_date AND _p.end_date;

  SELECT COALESCE(SUM((oi.base_price + COALESCE(oi.modifiers_total,0)) * oi.quantity),0)
    INTO _gross
  FROM public.order_items oi JOIN _pnl_orders po ON po.order_id = oi.order_id
  WHERE oi.status = 'active' AND NOT po.on_tab;

  SELECT COALESCE(SUM(o.promotional_discount),0), COALESCE(SUM(o.discount_amount),0),
         COALESCE(SUM(o.tax_amount),0)
    INTO _promo, _manual, _tax
  FROM public.orders o JOIN _pnl_orders po ON po.order_id = o.id
  WHERE NOT po.on_tab;

  SELECT COALESCE(SUM(o.total),0) INTO _tab
  FROM public.orders o JOIN _pnl_orders po ON po.order_id = o.id
  WHERE po.on_tab;

  SELECT COALESCE(SUM(op.amount),0) INTO _pts
  FROM public.order_payments op JOIN _pnl_orders po ON po.order_id = op.order_id
  WHERE op.method_key = 'points';

  SELECT COALESCE(SUM(oi.unit_cost * oi.quantity),0) INTO _cogs
  FROM public.order_items oi JOIN _pnl_orders po ON po.order_id = oi.order_id
  WHERE oi.status = 'active';

  SELECT COALESCE(SUM(-sm.quantity * sm.unit_cost),0) INTO _waste
  FROM public.stock_movements sm
  WHERE sm.company_id = _p.company_id
    AND sm.movement_type = 'waste'
    AND sm.quantity < 0
    AND sm.created_at::date BETWEEN _p.start_date AND _p.end_date;

  SELECT COALESCE(SUM(COALESCE((entry->>'unit_cost')::numeric,0) * COALESCE((entry->>'quantity')::numeric,0)),0)
    INTO _ref_waste
  FROM public.order_refunds r
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(r.items_payload,'[]'::jsonb)) AS entry
  WHERE r.company_id = _p.company_id AND r.status = 'active'
    AND entry->>'disposition' = 'waste'
    AND r.created_at::date BETWEEN _p.start_date AND _p.end_date;

  _waste := _waste + _ref_waste + COALESCE((SELECT SUM(st.shortage_cost) FROM public.stocktakes st
    WHERE st.company_id = _p.company_id AND COALESCE(st.settlement,'venue') = 'venue'
      AND st.created_at::date BETWEEN _p.start_date AND _p.end_date),0)
    -- Drawer shortages absorbed by the venue are a real cash loss.
    + COALESCE((SELECT SUM(-sh.variance) FROM public.shifts sh
      WHERE sh.company_id = _p.company_id AND sh.status = 'closed' AND sh.shortage_resolution = 'venue'
        AND sh.variance < 0 AND sh.closed_at::date BETWEEN _p.start_date AND _p.end_date),0);

  SELECT COALESCE(SUM(r.amount),0), COALESCE(SUM(r.tax_amount),0)
    INTO _ref, _ref_tax
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

  _net_rev := _gross - _promo - _manual - _pts - _ref + _ref_tax - _tax;
  _gp := _net_rev - _cogs - _waste;

  RETURN QUERY SELECT
    round(_gross,2), round(_promo,2), round(_manual,2), round(_pts,2),
    round(_ref,2), round(_ref_tax,2), round(_tab,2),
    round(_net_rev,2), round(_tax - _ref_tax,2),
    round(_cogs,2), round(_waste,2),
    round(_exp,2), round(_pay,2),
    round(_gp,2), round(_gp - _exp - _pay, 2);
END
$function$;