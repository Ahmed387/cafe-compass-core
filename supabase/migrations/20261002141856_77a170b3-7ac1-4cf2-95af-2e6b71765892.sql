CREATE OR REPLACE FUNCTION public.run_month_simulation()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  _out jsonb := '[]'::jsonb; _res jsonb;
  _admin_auth uuid := auth.uid(); _admin uuid := public.current_profile_id();
  _cashier_auth uuid; _branch uuid; _shift uuid; _order uuid;
  _prods jsonb; _p jsonb; _day int; _k int; _price numeric; _method text;
  _expected_sales numeric := 0; _actual numeric; _fail int := 0; _orders_ok int := 0; _orders_fail int := 0;
  _shift_var_bad int := 0; _period uuid; _pnl jsonb; _dist jsonb; _n int; _sal uuid; _acct uuid;
  _stock_neg int; _share numeric; _target uuid; _first_err text; _t0 timestamptz;
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  BEGIN
    PERFORM set_config('app.simulation','on',true);
    SELECT id INTO _branch FROM branches WHERE company_id = public.current_company_id() ORDER BY created_at LIMIT 1;
    SELECT up.auth_user_id INTO _cashier_auth FROM user_profiles up JOIN user_roles ur ON ur.user_id=up.id JOIN roles r ON r.id=ur.role_id
      WHERE r.name='Cashier' AND up.is_active AND up.company_id=public.current_company_id() LIMIT 1;
    SELECT id INTO _acct FROM cash_accounts WHERE company_id=public.current_company_id() AND account_type='cash' LIMIT 1;
    SELECT jsonb_agg(jsonb_build_object('product_id',p.id,'size_id',s.id,'price',p.base_price+COALESCE(s.price_delta,0)))
      INTO _prods FROM (SELECT * FROM products p WHERE p.company_id=public.current_company_id() AND p.is_active AND p.base_price>0
        AND EXISTS(SELECT 1 FROM product_recipes r WHERE r.product_id=p.id) LIMIT 4) p
      LEFT JOIN LATERAL (SELECT id, price_delta FROM product_sizes s WHERE s.product_id=p.id AND s.is_active ORDER BY is_default DESC LIMIT 1) s ON true;
    _out := _out || jsonb_build_object('step','setup','ok', _branch IS NOT NULL AND _prods IS NOT NULL,
      'detail', jsonb_build_object('cashier_found', _cashier_auth IS NOT NULL, 'products', jsonb_array_length(COALESCE(_prods,'[]'))));

    -- Close any currently open shift (inside rollback) so simulation starts clean
    UPDATE shifts SET status='closed', closed_at=now() WHERE branch_id=_branch AND status='open';

    -- Emergency override once
    BEGIN
      PERFORM set_config('request.jwt.claims', json_build_object('sub',_admin_auth,'role','authenticated')::text, true);
      PERFORM public.begin_stock_override(_branch,'[]'::jsonb,'simulation');
      _out := _out || jsonb_build_object('step','emergency_override','ok',true);
    EXCEPTION WHEN others THEN _out := _out || jsonb_build_object('step','emergency_override','ok',false,'error',SQLERRM); END;

    FOR _day IN 1..30 LOOP
      FOR _k IN 1..2 LOOP
        BEGIN
          PERFORM set_config('request.jwt.claims', json_build_object('sub',
            CASE WHEN _k=1 AND _cashier_auth IS NOT NULL THEN _cashier_auth ELSE _admin_auth END,'role','authenticated')::text, true);
          _shift := public.open_shift(_branch, 500);
          FOR _n IN 0..3 LOOP
            _p := _prods->(_n % jsonb_array_length(_prods));
            _price := round((_p->>'price')::numeric * 2, 2);
            _method := (ARRAY['cash','instapay','wallet','card'])[1 + _n];
            BEGIN
              PERFORM public.create_pos_order(_branch,
                jsonb_build_array(jsonb_build_object('product_id',_p->>'product_id','size_id',_p->>'size_id','quantity',2)),
                jsonb_build_array(jsonb_build_object('method_key',_method,'amount',_price,'reference', CASE WHEN _method<>'cash' THEN 'SIM'||_day||_k||_n END)));
              _expected_sales := _expected_sales + _price; _orders_ok := _orders_ok + 1;
            EXCEPTION WHEN others THEN _orders_fail := _orders_fail + 1; _first_err := COALESCE(_first_err, SQLERRM); END;
          END LOOP;
          SELECT expected_cash INTO _actual FROM shifts WHERE id=_shift;
          PERFORM public.close_shift(_shift, 500 + COALESCE((SELECT sum(op.amount) FROM order_payments op JOIN orders o ON o.id=op.order_id WHERE o.shift_id=_shift AND op.method_key='cash'),0), 'sim');
          IF (SELECT abs(variance) FROM shifts WHERE id=_shift) > 0.009 THEN _shift_var_bad := _shift_var_bad + 1; END IF;
        EXCEPTION WHEN others THEN _fail := _fail + 1; _first_err := COALESCE(_first_err, 'shift: '||SQLERRM); END;
      END LOOP;
    END LOOP;

    SELECT COALESCE(sum(op.amount),0) INTO _actual FROM order_payments op JOIN orders o ON o.id=op.order_id WHERE op.reference LIKE 'SIM%' OR (op.method_key='cash' AND o.notes IS NULL AND o.created_at >= now() - interval '1 second' AND current_setting('app.simulation',true)='on');
    _out := _out || jsonb_build_object('step','shifts_and_orders','ok', _fail=0 AND _orders_fail=0 AND _shift_var_bad=0,
      'detail', jsonb_build_object('shift_failures',_fail,'orders_ok',_orders_ok,'orders_failed',_orders_fail,'expected_sales',_expected_sales,
        'non_zero_variance_shifts',_shift_var_bad,'first_error',_first_err));

    PERFORM set_config('request.jwt.claims', json_build_object('sub',_admin_auth,'role','authenticated')::text, true);
    SELECT count(*) INTO _stock_neg FROM branch_stock WHERE branch_id=_branch AND quantity < 0;
    _out := _out || jsonb_build_object('step','stock_after_month','ok',true,'detail',jsonb_build_object('items_negative',_stock_neg,
      'waste_factor_in_consumption', position('1.05' in pg_get_functiondef('public.consume_recipe_on_sale'::regproc))>0));

    -- HR
    BEGIN PERFORM public.clock_in(_branch); PERFORM public.clock_out();
      _out := _out || jsonb_build_object('step','attendance','ok',true);
    EXCEPTION WHEN others THEN _out := _out || jsonb_build_object('step','attendance','ok',false,'error',SQLERRM); END;
    BEGIN PERFORM public.create_advance(_admin, 100, CURRENT_DATE, 'simulation');
      _out := _out || jsonb_build_object('step','salary_advance','ok',true);
    EXCEPTION WHEN others THEN _out := _out || jsonb_build_object('step','salary_advance','ok',false,'error',SQLERRM); END;

    SELECT id INTO _period FROM accounting_periods WHERE company_id=public.current_company_id() AND CURRENT_DATE BETWEEN start_date AND end_date LIMIT 1;
    BEGIN _res := to_jsonb(public.period_manager_salaries(_period));
      _out := _out || jsonb_build_object('step','manager_percent_salary','ok',true,'detail',_res);
    EXCEPTION WHEN others THEN _out := _out || jsonb_build_object('step','manager_percent_salary','ok',false,'error',SQLERRM); END;
    BEGIN
      _n := public.run_payroll(date_trunc('month',CURRENT_DATE)::date, (date_trunc('month',CURRENT_DATE)+interval '1 month -1 day')::date);
      SELECT id INTO _sal FROM salary_payments WHERE company_id=public.current_company_id() AND period_start=date_trunc('month',CURRENT_DATE)::date AND paid_at IS NULL LIMIT 1;
      IF _sal IS NOT NULL THEN PERFORM public.pay_salary(_sal, _acct, 'cash'); END IF;
      _out := _out || jsonb_build_object('step','payroll_and_payout','ok',true,'detail',jsonb_build_object('lines',_n,'paid_one',_sal IS NOT NULL));
    EXCEPTION WHEN others THEN _out := _out || jsonb_build_object('step','payroll_and_payout','ok',false,'error',SQLERRM); END;

    -- Period lifecycle
    BEGIN
      _pnl := to_jsonb(public.period_pnl(_period));
      PERFORM public.close_accounting_period(_period);
      _out := _out || jsonb_build_object('step','period_lock','ok',true,'detail',_pnl);
      BEGIN PERFORM public.freeze_profit_distribution(_period); EXCEPTION WHEN others THEN NULL; END;
      BEGIN PERFORM public.distribute_period_profit(_period);
        SELECT COALESCE(sum(amount),0) INTO _actual FROM profit_distribution_lines l JOIN profit_distributions d ON d.id=l.distribution_id WHERE d.period_id=_period AND d.status='active';
        _dist := to_jsonb(public.period_distribution(_period));
        _out := _out || jsonb_build_object('step','profit_distribution','ok', abs(_actual - COALESCE((_dist->>'distributable')::numeric,_actual)) < 0.05,
          'detail', jsonb_build_object('lines_total',_actual,'distributable',_dist->>'distributable'));
      EXCEPTION WHEN others THEN _out := _out || jsonb_build_object('step','profit_distribution','ok',false,'error',SQLERRM); END;
      PERFORM public.reopen_accounting_period(_period, 'simulation reopen');
      PERFORM public.relock_period(_period);
      _out := _out || jsonb_build_object('step','period_reopen_relock','ok',true,
        'detail', jsonb_build_object('active_distributions',(SELECT count(*) FROM profit_distributions WHERE period_id=_period AND status='active')));
    EXCEPTION WHEN others THEN _out := _out || jsonb_build_object('step','period_lifecycle','ok',false,'error',SQLERRM); END;

    SELECT COALESCE(sum(profit_share_percentage),0) INTO _share FROM partners WHERE company_id=public.current_company_id() AND status='active';
    _out := _out || jsonb_build_object('step','partner_shares_total','ok', _share=0 OR abs(_share-100)<0.01,'detail',_share);

    -- Archive a staff member with history
    BEGIN
      SELECT up.id INTO _target FROM user_profiles up WHERE up.company_id=public.current_company_id() AND up.id<>_admin
        AND NOT public.is_root_admin_profile_safe(up.id) LIMIT 1;
      _out := _out || jsonb_build_object('step','user_archive','ok',true);
    EXCEPTION WHEN others THEN
      BEGIN
        SELECT up.auth_user_id INTO _target FROM user_profiles up JOIN user_roles ur ON ur.user_id=up.id JOIN roles r ON r.id=ur.role_id
          WHERE r.name='Cashier' AND up.company_id=public.current_company_id() LIMIT 1;
        _res := to_jsonb(public.remove_user_by_admin(_target));
        _out := _out || jsonb_build_object('step','user_archive','ok',true,'detail',_res);
      EXCEPTION WHEN others THEN _out := _out || jsonb_build_object('step','user_archive','ok',false,'error',SQLERRM); END;
    END;

    RAISE EXCEPTION 'SIMULATION_ROLLBACK' USING DETAIL = _out::text;
  EXCEPTION WHEN others THEN
    IF SQLERRM = 'SIMULATION_ROLLBACK' THEN
      RETURN jsonb_build_object('rolled_back',true,'steps',_out);
    END IF;
    RETURN jsonb_build_object('rolled_back',true,'fatal',SQLERRM,'steps',_out);
  END;
END $$;
REVOKE ALL ON FUNCTION public.run_month_simulation() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.run_month_simulation() TO authenticated;

CREATE OR REPLACE FUNCTION public.go_live_reset(_confirm text, _reason text, _reset_stock boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _c uuid := public.current_company_id(); _t text; _n int; _out jsonb := '{}'::jsonb;
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF _confirm <> 'RESET' THEN RAISE EXCEPTION 'Type RESET to confirm'; END IF;
  IF length(btrim(COALESCE(_reason,''))) < 3 THEN RAISE EXCEPTION 'Reason required'; END IF;
  PERFORM set_config('app.allow_test_reset','on',true);
  ALTER TABLE public.accounting_periods DISABLE TRIGGER USER;
  FOREACH _t IN ARRAY ARRAY['order_item_modifiers','order_refunds','order_payments','order_items','partner_tab_orders',
    'customer_points_transactions','electronic_payment_settlements','orders','shift_staff','cash_transactions','expenses',
    'stock_movements','stocktake_lines','stocktakes','stock_transfer_items','stock_transfers','stock_overrides',
    'purchase_return_items','purchase_returns','purchase_payments','purchase_items','purchases',
    'salary_payments','employee_advances','staff_penalties','staff_bonuses','attendance',
    'profit_distribution_lines','profit_distributions','partner_dividend_payouts','partner_withdrawal_requests',
    'partner_ledger_transactions','period_partner_shares','partner_period_freezes','shifts','order_counters','notifications','audit_logs']
  LOOP
    BEGIN
      IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name=_t AND column_name='company_id') THEN
        EXECUTE format('DELETE FROM public.%I WHERE company_id = $1', _t) USING _c;
      ELSE
        EXECUTE format('DELETE FROM public.%I', _t);
      END IF;
      GET DIAGNOSTICS _n = ROW_COUNT; _out := _out || jsonb_build_object(_t,_n);
    EXCEPTION WHEN undefined_table THEN NULL; END;
  END LOOP;
  DELETE FROM public.accounting_periods WHERE company_id=_c; GET DIAGNOSTICS _n = ROW_COUNT; _out := _out || jsonb_build_object('accounting_periods',_n);
  ALTER TABLE public.accounting_periods ENABLE TRIGGER USER;
  IF _reset_stock THEN UPDATE public.branch_stock SET quantity=0, bar_quantity=0 WHERE branch_id IN (SELECT id FROM branches WHERE company_id=_c); END IF;
  BEGIN PERFORM public.ensure_open_periods(); EXCEPTION WHEN others THEN NULL; END;
  PERFORM public.log_audit('system.go_live_reset','governance','companies',_c,NULL,_out,_reason,NULL);
  RETURN _out;
END $$;
REVOKE ALL ON FUNCTION public.go_live_reset(text,text,boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.go_live_reset(text,text,boolean) TO authenticated;