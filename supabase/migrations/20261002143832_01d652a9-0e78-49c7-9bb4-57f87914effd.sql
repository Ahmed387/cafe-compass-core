CREATE OR REPLACE FUNCTION public.run_month_simulation()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _out jsonb := '[]'::jsonb; _res jsonb;
  _admin_auth uuid := auth.uid(); _admin uuid := public.current_profile_id();
  _cashier_auth uuid; _branch uuid; _shift uuid; _order uuid;
  _prods jsonb; _p jsonb; _day int; _k int; _price numeric; _method text;
  _expected_sales numeric := 0; _actual numeric; _fail int := 0; _orders_ok int := 0; _orders_fail int := 0;
  _shift_var_bad int := 0; _period uuid; _pnl jsonb; _dist jsonb; _n int; _sal uuid; _acct uuid;
  _stock_neg int; _share numeric; _target uuid; _first_err text; _first_dist uuid; _second_dist uuid;
  _ledger_net numeric; _second_total numeric; _active int; _reversed int;
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

    UPDATE shifts SET status='closed', closed_at=now() WHERE branch_id=_branch AND status='open';

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
          PERFORM public.close_shift(_shift, 500 + COALESCE((SELECT sum(op.amount) FROM order_payments op JOIN orders o ON o.id=op.order_id WHERE o.shift_id=_shift AND op.method_key='cash'),0), 'sim');
          IF (SELECT abs(variance) FROM shifts WHERE id=_shift) > 0.009 THEN _shift_var_bad := _shift_var_bad + 1; END IF;
        EXCEPTION WHEN others THEN _fail := _fail + 1; _first_err := COALESCE(_first_err, 'shift: '||SQLERRM); END;
      END LOOP;
    END LOOP;

    _out := _out || jsonb_build_object('step','shifts_and_orders','ok', _fail=0 AND _orders_fail=0 AND _shift_var_bad=0,
      'detail', jsonb_build_object('shift_failures',_fail,'orders_ok',_orders_ok,'orders_failed',_orders_fail,'expected_sales',_expected_sales,
        'non_zero_variance_shifts',_shift_var_bad,'first_error',_first_err));

    PERFORM set_config('request.jwt.claims', json_build_object('sub',_admin_auth,'role','authenticated')::text, true);
    SELECT count(*) INTO _stock_neg FROM branch_stock WHERE branch_id=_branch AND quantity < 0;
    _out := _out || jsonb_build_object('step','stock_after_month','ok',true,'detail',jsonb_build_object('items_negative',_stock_neg,
      'waste_factor_in_consumption', position('1.05' in pg_get_functiondef('public.consume_recipe_on_sale'::regproc))>0));

    BEGIN PERFORM public.clock_in(_branch); PERFORM public.clock_out();
      _out := _out || jsonb_build_object('step','attendance','ok',true);
    EXCEPTION WHEN others THEN _out := _out || jsonb_build_object('step','attendance','ok',false,'error',SQLERRM); END;
    BEGIN PERFORM public.create_advance(_admin, 100, CURRENT_DATE, 'simulation');
      _out := _out || jsonb_build_object('step','salary_advance','ok',true);
    EXCEPTION WHEN others THEN _out := _out || jsonb_build_object('step','salary_advance','ok',false,'error',SQLERRM); END;

    SELECT id INTO _period FROM accounting_periods WHERE company_id=public.current_company_id() AND CURRENT_DATE BETWEEN start_date AND end_date LIMIT 1;
    BEGIN SELECT jsonb_agg(to_jsonb(m)) INTO _res FROM public.period_manager_salaries(_period) m;
      _out := _out || jsonb_build_object('step','manager_percent_salary','ok',true,'detail',_res);
    EXCEPTION WHEN others THEN _out := _out || jsonb_build_object('step','manager_percent_salary','ok',false,'error',SQLERRM); END;
    BEGIN
      _n := public.run_payroll(date_trunc('month',CURRENT_DATE)::date, (date_trunc('month',CURRENT_DATE)+interval '1 month -1 day')::date);
      SELECT id INTO _sal FROM salary_payments WHERE company_id=public.current_company_id() AND period_start=date_trunc('month',CURRENT_DATE)::date AND paid_at IS NULL LIMIT 1;
      IF _sal IS NOT NULL THEN PERFORM public.pay_salary(_sal, _acct, 'cash'); END IF;
      _out := _out || jsonb_build_object('step','payroll_and_payout','ok',true,'detail',jsonb_build_object('lines',_n,'paid_one',_sal IS NOT NULL));
    EXCEPTION WHEN others THEN _out := _out || jsonb_build_object('step','payroll_and_payout','ok',false,'error',SQLERRM); END;

    BEGIN
      PERFORM public.mark_order_delivered(o.id) FROM orders o WHERE o.status='pending' AND o.company_id=public.current_company_id();
      _pnl := to_jsonb(public.period_pnl(_period));
      PERFORM public.close_accounting_period(_period);
      _out := _out || jsonb_build_object('step','period_lock','ok',true,'detail',_pnl);
      BEGIN PERFORM public.freeze_profit_distribution(_period); EXCEPTION WHEN others THEN NULL; END;
      _first_dist := public.distribute_period_profit(_period);
      SELECT COALESCE(sum(amount),0) INTO _actual FROM profit_distribution_lines WHERE distribution_id=_first_dist;
      _dist := to_jsonb(public.period_distribution(_period));
      _out := _out || jsonb_build_object('step','profit_distribution','ok', abs(_actual - (_dist->>'distributable')::numeric) < 0.05,
        'detail', jsonb_build_object('lines_total',_actual,'distributable',_dist->>'distributable','distribution',_dist));
    EXCEPTION WHEN others THEN _out := _out || jsonb_build_object('step','period_lock_distribute','ok',false,'error',SQLERRM); END;

    BEGIN
      PERFORM public.reopen_accounting_period(_period, 'simulation reopen');
      SELECT count(*) FILTER (WHERE status='active'), count(*) FILTER (WHERE status='reversed') INTO _active, _reversed
        FROM profit_distributions WHERE period_id=_period;
      _out := _out || jsonb_build_object('step','period_reopen_auto_reverse','ok', _active=0 AND _reversed>=1,
        'detail', jsonb_build_object('status',(SELECT status FROM accounting_periods WHERE id=_period),'active',_active,'reversed',_reversed));

      _shift := public.open_shift(_branch, 500);
      _p := _prods->0; _price := round((_p->>'price')::numeric * 2, 2);
      SELECT out_id INTO _order FROM public.create_pos_order(_branch,
        jsonb_build_array(jsonb_build_object('product_id',_p->>'product_id','size_id',_p->>'size_id','quantity',2)),
        jsonb_build_array(jsonb_build_object('method_key','cash','amount',_price)));
      PERFORM public.mark_order_delivered(_order);
      PERFORM public.close_shift(_shift, 500 + _price, 'sim reopen');

      PERFORM public.close_accounting_period(_period);
      BEGIN PERFORM public.freeze_profit_distribution(_period); EXCEPTION WHEN others THEN NULL; END;
      _second_dist := public.distribute_period_profit(_period);
      SELECT COALESCE(sum(amount),0) INTO _second_total FROM profit_distribution_lines WHERE distribution_id=_second_dist;
      _dist := to_jsonb(public.period_distribution(_period));
      SELECT count(*) FILTER (WHERE status='active'), count(*) FILTER (WHERE status='reversed') INTO _active, _reversed
        FROM profit_distributions WHERE period_id=_period;
      SELECT COALESCE(sum(amount),0) INTO _ledger_net FROM partner_ledger_transactions
        WHERE status='active' AND reference_id IN (_first_dist,_second_dist)
          AND reference_type IN ('profit_distribution','profit_distribution_reversal');
      _out := _out || jsonb_build_object('step','period_reclose_redistribute',
        'ok', _active=1 AND _reversed>=1 AND abs(_second_total-(_dist->>'distributable')::numeric)<0.05 AND abs(_ledger_net-_second_total)<0.05,
        'detail', jsonb_build_object('first_total',_actual,'second_total',_second_total,'distributable',_dist->>'distributable',
          'extra_sale',_price,'active',_active,'reversed',_reversed,'partner_ledger_net',_ledger_net));
    EXCEPTION WHEN others THEN _out := _out || jsonb_build_object('step','period_reopen_reclose','ok',false,'error',SQLERRM); END;

    SELECT COALESCE(sum(profit_share_percentage),0) INTO _share FROM partners WHERE company_id=public.current_company_id() AND status='active';
    _out := _out || jsonb_build_object('step','partner_shares_total','ok', _share=0 OR abs(_share-100)<0.01,'detail',_share);

    BEGIN
      SELECT up.id INTO _target FROM user_profiles up JOIN user_roles ur ON ur.user_id=up.id JOIN roles r ON r.id=ur.role_id
        WHERE r.name='Cashier' AND up.company_id=public.current_company_id() LIMIT 1;
      _res := to_jsonb(public.remove_user_by_admin(_target));
      _out := _out || jsonb_build_object('step','user_archive','ok',
        (SELECT archived_at IS NOT NULL AND NOT is_active FROM user_profiles WHERE id=_target),'detail',_res);
    EXCEPTION WHEN others THEN _out := _out || jsonb_build_object('step','user_archive','ok',false,'error',SQLERRM); END;

    RAISE EXCEPTION 'SIMULATION_ROLLBACK';
  EXCEPTION WHEN others THEN
    IF SQLERRM = 'SIMULATION_ROLLBACK' THEN
      RETURN jsonb_build_object('rolled_back',true,'steps',_out);
    END IF;
    RETURN jsonb_build_object('rolled_back',true,'fatal',SQLERRM,'steps',_out);
  END;
END $function$;