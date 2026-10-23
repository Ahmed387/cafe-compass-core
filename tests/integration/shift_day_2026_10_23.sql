-- =====================================================================
-- Shift business day + drawer difference test (2026-10-23), run against
-- the real "20s" database inside ONE transaction that ends in ROLLBACK.
-- Nothing created here is kept.
--
-- Scenario: a shift opened "yesterday" (D) is still open today (T). All of
-- its bills, refunds, expenses, cash drop and drawer difference must count
-- on D. A shortage waits for the super admin, who decides who bears it.
-- =====================================================================
BEGIN;

CREATE TEMP TABLE _results (n serial, step text, ok boolean, detail text) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.act_as(_role_key text) RETURNS boolean LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', up.auth_user_id, 'role', 'authenticated')::text, true) IS NOT NULL
    FROM public.user_profiles up
    JOIN public.user_roles ur ON ur.user_id = up.id
    JOIN public.roles r ON r.id = ur.role_id
   WHERE r.key = _role_key AND up.is_active AND up.auth_user_id IS NOT NULL
   ORDER BY up.created_at LIMIT 1
$$;
CREATE OR REPLACE FUNCTION pg_temp.ok(_step text, _ok boolean, _detail text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$
  INSERT INTO _results (step, ok, detail) VALUES (_step, COALESCE(_ok, false), _detail)
$$;
CREATE OR REPLACE FUNCTION pg_temp.custom_item(_name text, _price numeric, _qty int DEFAULT 1) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_array(jsonb_build_object('custom', true, 'product_id', NULL, 'size_id', NULL,
    'product_name', _name, 'size_name', NULL, 'unit_price', _price, 'quantity', _qty, 'is_taxable', false,
    'modifiers', '[]'::jsonb))
$$;
CREATE OR REPLACE FUNCTION pg_temp.pay(_key text, _amount numeric) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('method_key', _key, 'amount', _amount,
    'payment_method_id', (SELECT id FROM public.payment_methods WHERE key = _key AND company_id = public.current_company_id() LIMIT 1))
$$;
CREATE OR REPLACE FUNCTION pg_temp.pnl(_d date, _key text) RETURNS numeric LANGUAGE sql AS $$
  SELECT (public._range_pnl(public.current_company_id(), _d, _d)->>_key)::numeric
$$;

SELECT pg_temp.act_as('super_admin');

DO $$
DECLARE
  _co uuid := public.current_company_id(); _branch uuid; _shift uuid; _shift2 uuid; _d date; _t date;
  _o uuid; _o2 uuid; _id uuid; _n numeric; _m numeric; _txt text; _fig jsonb; _cat uuid;
  _revD numeric; _revT numeric; _shD numeric; _shT numeric; _ovT numeric; _expD numeric;
BEGIN
  IF public.current_profile_id() IS NULL THEN RAISE EXCEPTION 'setup: no super admin to act as'; END IF;
  _t := public.business_date(now(), _co);
  _d := _t - 1;
  SELECT id INTO _branch FROM public.branches WHERE company_id = _co AND is_active ORDER BY created_at LIMIT 1;

  -- Setup: the open shift (or a new one) is treated as opened yesterday.
  SELECT id INTO _shift FROM public.shifts WHERE branch_id = _branch AND status = 'open' ORDER BY opened_at DESC LIMIT 1;
  IF _shift IS NULL THEN _shift := public.open_shift_with_roster(_branch, 200, ARRAY[]::uuid[]); END IF;
  UPDATE public.shifts SET business_date = _d WHERE id = _shift;
  _revD := pg_temp.pnl(_d, 'revenue'); _revT := pg_temp.pnl(_t, 'revenue');
  _shD := pg_temp.pnl(_d, 'cash_shortage'); _shT := pg_temp.pnl(_t, 'cash_shortage');
  _ovT := pg_temp.pnl(_t, 'cash_over'); _expD := pg_temp.pnl(_d, 'expenses_total');

  -- 1. While the shift is open, "today" is its day.
  PERFORM pg_temp.ok('01 النهارده = يوم الوردية المفتوحة', public.business_today(_co) = _d,
    'business_today=' || public.business_today(_co) || ' يوم الوردية=' || _d || ' التاريخ=' || _t);

  -- 2. A bill made today belongs to the shift's day.
  BEGIN
    SELECT out_id INTO _o FROM public.create_pos_order(_branch, pg_temp.custom_item('TEST يوم الوردية', 100),
      jsonb_build_array(pg_temp.pay('cash', 100)), 'dine_in'::order_type);
    PERFORM pg_temp.ok('02 فاتورة النهارده بتتحسب على يوم الوردية',
      (SELECT business_date FROM public.orders WHERE id = _o) = _d
        AND pg_temp.pnl(_d, 'revenue') - _revD = 100 AND pg_temp.pnl(_t, 'revenue') = _revT,
      'يوم الفاتورة=' || (SELECT business_date FROM public.orders WHERE id = _o)
        || ' زيادة يوم الوردية=' || (pg_temp.pnl(_d, 'revenue') - _revD) || ' زيادة النهارده=' || (pg_temp.pnl(_t, 'revenue') - _revT));
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('02 فاتورة على يوم الوردية', false, SQLERRM); END;

  -- 3. A refund inside the shift counts on the shift's day too.
  BEGIN
    SELECT out_id INTO _o2 FROM public.create_pos_order(_branch, pg_temp.custom_item('TEST مرتجع', 50, 2),
      jsonb_build_array(pg_temp.pay('cash', 100)), 'dine_in'::order_type);
    SELECT id INTO _id FROM public.order_items WHERE order_id = _o2 LIMIT 1;
    PERFORM public.refund_order_items_attributed(_o2,
      jsonb_build_array(jsonb_build_object('order_item_id', _id, 'quantity', 1, 'disposition', 'restock')), 'cash', 'اختبار يوم الوردية', 'venue', NULL);
    PERFORM pg_temp.ok('03 المرتجع على يوم الوردية',
      (SELECT bool_and(business_date = _d) FROM public.order_refunds WHERE order_id = _o2)
        AND pg_temp.pnl(_d, 'revenue') - _revD = 150,
      'زيادة يوم الوردية بعد المرتجع=' || (pg_temp.pnl(_d, 'revenue') - _revD));
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('03 المرتجع على يوم الوردية', false, SQLERRM); END;

  -- 4. A shift expense is dated to the shift's day.
  BEGIN
    SELECT id INTO _cat FROM public.expense_categories WHERE company_id = _co AND is_active LIMIT 1;
    PERFORM public.create_shift_expense(_shift, 40, _cat, 'TEST مصروف يوم الوردية', NULL);
    SELECT expense_date::text INTO _txt FROM public.expenses WHERE shift_id = _shift AND amount = 40 ORDER BY created_at DESC LIMIT 1;
    PERFORM pg_temp.ok('04 مصروف الوردية على يومها', _txt = _d::text, 'تاريخ المصروف=' || _txt);
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('04 مصروف الوردية على يومها', false, SQLERRM); END;

  -- 5. Closing 10 short without choosing a bearer: the shift closes, the shortage waits.
  BEGIN
    _fig := public._shift_drawer((SELECT s FROM public.shifts s WHERE s.id = _shift));
    PERFORM public.close_shift_handover(_shift, (_fig->>'expected')::numeric - 10, 0, NULL, NULL, 'اختبار عجز');
    PERFORM pg_temp.ok('05 قفل بعجز 10: الوردية اتقفلت والعجز مستني قرار السوبر أدمن',
      (SELECT status = 'closed' AND variance = -10 AND shortage_resolution = 'pending' FROM public.shifts WHERE id = _shift)
        AND NOT EXISTS (SELECT 1 FROM public.staff_penalties WHERE shift_id = _shift AND source = 'shift_shortage'),
      (SELECT 'variance=' || variance || ' resolution=' || COALESCE(shortage_resolution, 'null') FROM public.shifts WHERE id = _shift));
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('05 قفل بعجز', false, SQLERRM); END;

  -- 6. The super admins get a warning naming the shift's opening day.
  SELECT body INTO _txt FROM public.notifications
   WHERE type = 'shift.shortage' AND data->>'shift_id' = _shift::text ORDER BY created_at DESC LIMIT 1;
  PERFORM pg_temp.ok('06 تنبيه عجز للسوبر أدمن بتاريخ فتح الوردية',
    _txt LIKE '%' || to_char(_d, 'DD/MM/YYYY') || '%' AND _txt LIKE '%10.00%', _txt);

  -- 7. The shortage counts on the shift's day, not on the day it was closed.
  PERFORM pg_temp.ok('07 العجز على يوم الوردية مش يوم القفل',
    pg_temp.pnl(_d, 'cash_shortage') - _shD = 10 AND pg_temp.pnl(_t, 'cash_shortage') = _shT,
    'يوم الوردية +' || (pg_temp.pnl(_d, 'cash_shortage') - _shD) || ' النهارده +' || (pg_temp.pnl(_t, 'cash_shortage') - _shT));
  PERFORM pg_temp.ok('07b المصروف على يوم الوردية في الأرباح', pg_temp.pnl(_d, 'expenses_total') - _expD = 40,
    'زيادة مصاريف يوم الوردية=' || (pg_temp.pnl(_d, 'expenses_total') - _expD));

  -- 8. The cash drop lands in the treasury on the shift's day.
  PERFORM pg_temp.ok('08 فلوس الوردية في الخزنة بتاريخ فتحها',
    (SELECT bool_and(txn_date = _d) FROM public.cash_transactions WHERE reference_type = 'shift' AND reference_id = _shift),
    (SELECT string_agg(category || '=' || txn_date, ', ') FROM public.cash_transactions WHERE reference_type = 'shift' AND reference_id = _shift));

  -- 9. A cashier can't decide who bears it.
  PERFORM pg_temp.act_as('cashier');
  BEGIN
    PERFORM public.reassign_shift_shortage(_shift, 'venue', NULL, 'الكاشير بيحاول يشيل العجز');
    PERFORM pg_temp.ok('09 الكاشير ميقدرش يقرر مين يتحمل العجز', false, 'قدر!');
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('09 الكاشير ميقدرش يقرر مين يتحمل العجز', true, SQLERRM); END;
  PERFORM pg_temp.act_as('super_admin');

  -- 10. The super admin's first decision needs no reason (except for the venue).
  BEGIN
    PERFORM public.reassign_shift_shortage(_shift, 'split', NULL, NULL);
    SELECT COALESCE(SUM(amount), 0) INTO _n FROM public.staff_penalties WHERE shift_id = _shift AND source = 'shift_shortage';
    PERFORM pg_temp.ok('10 السوبر أدمن وزع العجز على التيم',
      (SELECT shortage_resolution FROM public.shifts WHERE id = _shift) = 'split' AND _n = 10
        AND NOT EXISTS (SELECT 1 FROM public.notifications WHERE type = 'shift.shortage' AND data->>'shift_id' = _shift::text AND read_at IS NULL),
      'خصومات=' || _n);
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('10 السوبر أدمن وزع العجز', false, SQLERRM); END;
  BEGIN
    PERFORM public.reassign_shift_shortage(_shift, 'venue', NULL, NULL);
    PERFORM pg_temp.ok('11 تغيير القرار من غير سبب ممنوع', false, 'اتقبل!');
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('11 تغيير القرار من غير سبب ممنوع', true, SQLERRM); END;
  PERFORM pg_temp.ok('12 مفيش ورديات مستنية قرار عجز من الوردية دي',
    NOT EXISTS (SELECT 1 FROM public.pending_shift_shortages() p WHERE p.shift_id = _shift));

  -- 13. A new shift opened today belongs to today; an overage posts with a warning.
  BEGIN
    _shift2 := public.open_shift_with_roster(_branch, 200, ARRAY[]::uuid[]);
    PERFORM pg_temp.ok('13 وردية جديدة النهارده يومها النهارده',
      (SELECT business_date FROM public.shifts WHERE id = _shift2) = _t AND public.business_today(_co) = _t);
    _fig := public._shift_drawer((SELECT s FROM public.shifts s WHERE s.id = _shift2));
    PERFORM public.close_shift_handover(_shift2, (_fig->>'expected')::numeric + 5, 0, NULL, NULL, 'اختبار زيادة');
    PERFORM pg_temp.ok('14 زيادة 5: نزلت مع الوردية وفيه تنبيه',
      pg_temp.pnl(_t, 'cash_over') - _ovT = 5
        AND EXISTS (SELECT 1 FROM public.notifications WHERE type = 'shift.overage' AND data->>'shift_id' = _shift2::text),
      'زيادة النهارده=' || (pg_temp.pnl(_t, 'cash_over') - _ovT));
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('13 وردية جديدة', false, SQLERRM); END;

  -- 15. Days add up: nothing counted twice, nothing lost.
  _n := (public._range_pnl(_co, _d - 1, _t)->>'net_profit')::numeric;
  _m := pg_temp.pnl(_d - 1, 'net_profit') + pg_temp.pnl(_d, 'net_profit') + pg_temp.pnl(_t, 'net_profit');
  PERFORM pg_temp.ok('15 مجموع الأيام = الفترة كلها', abs(_n - _m) < 0.05, 'الفترة=' || _n || ' مجموع الأيام=' || _m);

  -- 16. The orders screen finds the bill on the shift's day.
  PERFORM pg_temp.ok('16 شاشة الفواتير بتلاقي الفاتورة على يوم الوردية',
    (public.orders_period_summary(_branch, _d, _d, 'all', 'all', 'all', NULL, 'TEST يوم الوردية')->>'count')::int = 1);
END $$;

SELECT n, step, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, detail FROM _results ORDER BY n;

ROLLBACK;
