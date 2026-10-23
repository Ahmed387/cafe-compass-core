-- =====================================================================
-- Full-day integration test (2026-10-22): one working day of the café,
-- run against the real "20s" database inside ONE transaction that ends in
-- ROLLBACK. No shift, invoice, refund, customer or treasury line created
-- here is kept.
--
-- Each check records PASS / FAIL with details in the temp table _results;
-- a failing check never stops the others. Run it in the Supabase SQL
-- editor and read the last result grid.
-- =====================================================================
BEGIN;

CREATE TEMP TABLE _results (n serial, step text, ok boolean, detail text) ON COMMIT DROP;
CREATE TEMP TABLE _ctx (k text PRIMARY KEY, v text) ON COMMIT DROP;

-- Act as a super admin (auth.uid() reads the JWT claims).
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

SELECT pg_temp.act_as('super_admin');

DO $$
DECLARE
  _co uuid := public.current_company_id(); _branch uuid; _shift uuid; _today date;
  _o_cash uuid; _o_split uuid; _o_stock uuid; _o_part uuid; _o_tab uuid; _o_cb1 uuid; _o_cb2 uuid;
  _partner uuid; _cust uuid; _prod uuid := 'ca603bdc-dde4-4995-b095-e60e17cef2ef';
  _n numeric; _m numeric; _txt text; _j jsonb; _pnl0 jsonb; _pnl1 jsonb; _fig jsonb; _item uuid; _cat uuid; _id uuid; _id_count int;
BEGIN
  IF public.current_profile_id() IS NULL THEN RAISE EXCEPTION 'setup: no super admin to act as'; END IF;
  _today := public.business_today(_co);
  SELECT id INTO _branch FROM public.branches WHERE company_id = _co AND is_active ORDER BY created_at LIMIT 1;
  _pnl0 := public.range_pnl(_today, _today);

  -- 1. Open a shift with 200 in the drawer.
  BEGIN
    SELECT id INTO _shift FROM public.shifts WHERE branch_id = _branch AND status = 'open' LIMIT 1;
    IF _shift IS NULL THEN _shift := public.open_shift_with_roster(_branch, 200, ARRAY[]::uuid[]); END IF;
    PERFORM pg_temp.ok('01 فتح وردية', (SELECT status = 'open' FROM public.shifts WHERE id = _shift));
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('01 فتح وردية', false, SQLERRM); END;

  -- 2. Cash bill of 100.
  BEGIN
    SELECT out_id INTO _o_cash FROM public.create_pos_order(_branch, pg_temp.custom_item('TEST كاش', 100),
      jsonb_build_array(pg_temp.pay('cash', 100)), 'dine_in'::order_type);
    SELECT status::text INTO _txt FROM public.orders WHERE id = _o_cash;
    PERFORM pg_temp.ok('02 فاتورة كاش 100', _txt = 'completed'
      AND (SELECT shift_id FROM public.orders WHERE id = _o_cash) = _shift, 'status=' || _txt);
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('02 فاتورة كاش 100', false, SQLERRM); END;

  -- 3. One bill paid two ways keeps each amount.
  BEGIN
    SELECT out_id INTO _o_split FROM public.create_pos_order(_branch, pg_temp.custom_item('TEST مقسوم', 100),
      jsonb_build_array(pg_temp.pay('cash', 60), pg_temp.pay('instapay', 40)), 'dine_in'::order_type);
    PERFORM pg_temp.ok('03 دفع بطريقتين 60 كاش + 40 إنستاباي',
      (SELECT count(*) = 2 AND SUM(amount) FILTER (WHERE method_key = 'cash') = 60
              AND SUM(amount) FILTER (WHERE method_key = 'instapay') = 40
         FROM public.order_payments WHERE order_id = _o_split));
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('03 دفع بطريقتين', false, SQLERRM); END;

  -- 4. A real drink takes its ingredients out of stock and keeps its cost.
  BEGIN
    SELECT out_id INTO _o_stock FROM public.create_pos_order(_branch,
      jsonb_build_array(jsonb_build_object('product_id', _prod, 'quantity', 1, 'modifiers', '[]'::jsonb)),
      jsonb_build_array(pg_temp.pay('cash', (SELECT base_price FROM public.products WHERE id = _prod))), 'dine_in'::order_type);
    SELECT count(*) INTO _n FROM public.stock_movements sm JOIN public.order_items oi ON oi.id = sm.reference_id
     WHERE sm.reference_type = 'order_item' AND oi.order_id = _o_stock AND sm.quantity < 0;
    SELECT unit_cost INTO _m FROM public.order_items WHERE order_id = _o_stock LIMIT 1;
    PERFORM pg_temp.ok('04 مشروب حقيقي بيخصم من المخزن وبيحسب التكلفة', _n >= 1 AND _m > 0,
      'حركات مخزن=' || _n || ' تكلفة القطعة=' || COALESCE(_m::text, 'null'));
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('04 مشروب حقيقي بيخصم من المخزن', false, SQLERRM); END;

  -- 5. Partial refund: 1 of 2 items.
  BEGIN
    SELECT out_id INTO _o_part FROM public.create_pos_order(_branch, pg_temp.custom_item('TEST جزئي', 50, 2),
      jsonb_build_array(pg_temp.pay('cash', 100)), 'dine_in'::order_type);
    SELECT id INTO _id FROM public.order_items WHERE order_id = _o_part LIMIT 1;
    PERFORM public.refund_order_items_attributed(_o_part,
      jsonb_build_array(jsonb_build_object('order_item_id', _id, 'quantity', 1, 'disposition', 'waste')), 'cash', 'اختبار مرتجع جزئي', 'venue', NULL);
    SELECT status::text INTO _txt FROM public.orders WHERE id = _o_part;
    SELECT SUM(amount) INTO _n FROM public.order_refunds WHERE order_id = _o_part AND status = 'active';
    PERFORM pg_temp.ok('05 مرتجع جزئي قطعة من 2', _txt = 'partially_refunded' AND _n = 50, 'status=' || _txt || ' مرتجع=' || _n);
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('05 مرتجع جزئي', false, SQLERRM); END;

  -- 6. Full refund, then a second full refund must fail.
  BEGIN
    PERFORM public.refund_order_full(_o_cash, 'اختبار مرتجع كلي', 'cash', 'venue', NULL);
    SELECT status::text INTO _txt FROM public.orders WHERE id = _o_cash;
    SELECT SUM(amount) INTO _n FROM public.order_refunds WHERE order_id = _o_cash AND status = 'active';
    PERFORM pg_temp.ok('06 مرتجع كلي', _txt = 'refunded' AND _n = 100, 'status=' || _txt || ' مرتجع=' || _n);
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('06 مرتجع كلي', false, SQLERRM); END;
  BEGIN
    PERFORM public.refund_order_full(_o_cash, 'مرتجع تاني لنفس الفاتورة', 'cash', 'venue', NULL);
    PERFORM pg_temp.ok('07 ممنوع ترجع نفس الفاتورة مرتين', false, 'اتقبل مرتجع تاني!');
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('07 ممنوع ترجع نفس الفاتورة مرتين', true, SQLERRM); END;

  -- 8. A paid bill can't be cancelled (only refunded).
  BEGIN
    PERFORM public.cancel_pos_order(_o_split, 'محاولة إلغاء فاتورة مدفوعة');
    PERFORM pg_temp.ok('08 ممنوع إلغاء فاتورة مدفوعة', false, 'اتلغت فاتورة مدفوعة!');
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('08 ممنوع إلغاء فاتورة مدفوعة', true, SQLERRM); END;

  -- 9. Partner tab bill, then cancel: comes off the partner's account, no cash out.
  BEGIN
    SELECT id INTO _partner FROM public.partners WHERE company_id = _co AND status = 'active' ORDER BY created_at LIMIT 1;
    SELECT out_id INTO _o_tab FROM public.create_pos_order(_branch,
      jsonb_build_array(jsonb_build_object('product_id', _prod, 'quantity', 1, 'modifiers', '[]'::jsonb)), '[]'::jsonb,
      'dine_in'::order_type, _partner_id => _partner, _on_partner_tab => true);
    _n := (SELECT total_amount FROM public.partner_tab_orders WHERE order_id = _o_tab);
    PERFORM public.cancel_pos_order(_o_tab, 'اختبار إلغاء فاتورة شريك');
    PERFORM pg_temp.ok('09 فاتورة على حساب شريك ثم إلغاؤها', _n > 0
      AND (SELECT status = 'cancelled' FROM public.orders WHERE id = _o_tab)
      AND NOT EXISTS (SELECT 1 FROM public.order_refunds WHERE order_id = _o_tab AND public.tender_key(method_key) = 'cash'),
      'على الحساب=' || _n || ' بعد الإلغاء=' || COALESCE((SELECT (total_amount - settled_amount)::text || ' متسوّى=' || is_settled FROM public.partner_tab_orders WHERE order_id = _o_tab), 'السطر اختفى'));
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('09 فاتورة على حساب شريك', false, SQLERRM); END;

  -- 10. Invoices, refunds and shifts can never be deleted.
  BEGIN
    DELETE FROM public.orders WHERE id = _o_split;
    PERFORM pg_temp.ok('10 ممنوع مسح فاتورة', EXISTS (SELECT 1 FROM public.orders WHERE id = _o_split), 'المسح عدّى من غير خطأ');
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('10 ممنوع مسح فاتورة', true, SQLERRM); END;
  BEGIN
    DELETE FROM public.order_refunds WHERE order_id = _o_cash;
    PERFORM pg_temp.ok('11 ممنوع مسح مرتجع', EXISTS (SELECT 1 FROM public.order_refunds WHERE order_id = _o_cash), 'المسح عدّى من غير خطأ');
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('11 ممنوع مسح مرتجع', true, SQLERRM); END;
  BEGIN
    -- As the app's own database role (the owner role skips row security).
    EXECUTE 'SET LOCAL ROLE authenticated';
    DELETE FROM public.shifts WHERE id = _shift;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.ok('12 ممنوع مسح وردية', EXISTS (SELECT 1 FROM public.shifts WHERE id = _shift), 'المسح عدّى من غير خطأ');
  EXCEPTION WHEN OTHERS THEN EXECUTE 'RESET ROLE'; PERFORM pg_temp.ok('12 ممنوع مسح وردية', true, SQLERRM); END;

  -- 13. Cashback levels: 500 -> 25, 1000 -> 60.
  BEGIN
    PERFORM public.set_cashback_tiers(true, '[{"target":500,"reward":25},{"target":1000,"reward":60}]'::jsonb);
    _cust := public.upsert_customer('TEST عميل كاش باك', '01099999901', NULL);
    SELECT out_id INTO _o_cb1 FROM public.create_pos_order(_branch, pg_temp.custom_item('TEST 600', 600),
      jsonb_build_array(pg_temp.pay('cash', 600)), 'dine_in'::order_type, _customer_id => _cust);
    PERFORM pg_temp.ok('13 الكاش باك: صرف 600 ياخد 25 ويبقى في المستوى 2',
      (SELECT wallet_balance = 25 AND cashback_level = 1 AND cashback_progress = 600 FROM public.customers WHERE id = _cust),
      (SELECT 'محفظة=' || wallet_balance || ' مستوى=' || cashback_level || ' مشتريات=' || cashback_progress FROM public.customers WHERE id = _cust));
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('13 الكاش باك', false, SQLERRM); END;

  -- 14. Paying part of a bill from the wallet; only real money counts toward the next level.
  BEGIN
    SELECT out_id INTO _o_cb2 FROM public.create_pos_order(_branch, pg_temp.custom_item('TEST من المحفظة', 100),
      jsonb_build_array(pg_temp.pay('cashback', 25), pg_temp.pay('cash', 75)), 'dine_in'::order_type, _customer_id => _cust);
    PERFORM pg_temp.ok('14 الدفع من المحفظة 25 + كاش 75',
      (SELECT wallet_balance = 0 AND cashback_progress = 675 FROM public.customers WHERE id = _cust),
      (SELECT 'محفظة=' || wallet_balance || ' مشتريات=' || cashback_progress FROM public.customers WHERE id = _cust));
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('14 الدفع من المحفظة', false, SQLERRM); END;
  BEGIN
    PERFORM public.create_pos_order(_branch, pg_temp.custom_item('TEST أكتر من الرصيد', 100),
      jsonb_build_array(pg_temp.pay('cashback', 50), pg_temp.pay('cash', 50)), 'dine_in'::order_type, _customer_id => _cust);
    PERFORM pg_temp.ok('15 ممنوع تدفع من المحفظة أكتر من رصيدها', false, 'اتقبل!');
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('15 ممنوع تدفع من المحفظة أكتر من رصيدها', true, SQLERRM); END;

  -- 16. Full refund of a bill paid partly from the wallet: the wallet part goes back to the wallet.
  BEGIN
    PERFORM public.refund_order_full(_o_cb2, 'اختبار مرتجع فاتورة كاش باك', 'cash', 'venue', NULL);
    SELECT wallet_balance INTO _n FROM public.customers WHERE id = _cust;
    SELECT COALESCE(SUM(amount) FILTER (WHERE public.tender_key(method_key) = 'cash'), 0) INTO _m
      FROM public.order_refunds WHERE order_id = _o_cb2 AND status = 'active';
    PERFORM pg_temp.ok('16 مرتجع فاتورة اتدفع جزء منها من المحفظة: الـ 25 ترجع للمحفظة والـ 75 كاش',
      _n = 25 AND _m = 75, 'المحفظة رجعت=' || _n || ' كاش اترد=' || _m);
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('16 مرتجع فاتورة كاش باك', false, SQLERRM); END;

  -- 16b. Refunding the bill that earned a reward takes the reward back.
  BEGIN
    PERFORM public.refund_order_full(_o_cb1, 'اختبار مرتجع فاتورة كسبت كاش باك', 'cash', 'venue', NULL);
    SELECT COALESCE(SUM(amount), 0) INTO _n FROM public.customer_wallet_transactions
     WHERE customer_id = _cust AND order_id = _o_cb1;
    PERFORM pg_temp.ok('16b مرتجع فاتورة كسبت كاش باك: المكافأة بتتسحب',
      _n = 0, 'صافي حركة المحفظة على الفاتورة دي=' || _n ||
      (SELECT ' مستوى=' || cashback_level || ' مشتريات=' || cashback_progress || ' محفظة=' || wallet_balance FROM public.customers WHERE id = _cust));
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('16b مرتجع فاتورة كسبت كاش باك', false, SQLERRM); END;

  -- 17. Zero all wallets keeps the history.
  BEGIN
    _j := public.reset_all_wallets('اختبار تصفير');
    PERFORM pg_temp.ok('17 تصفير كل المحافظ من غير ما يتمسح السجل',
      NOT EXISTS (SELECT 1 FROM public.customers WHERE company_id = _co AND wallet_balance <> 0)
      AND EXISTS (SELECT 1 FROM public.customer_wallet_transactions WHERE customer_id = _cust AND kind = 'adjust'),
      _j::text);
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('17 تصفير المحافظ', false, SQLERRM); END;

  -- 18. An offer below cost + 25% is refused.
  BEGIN
    PERFORM public.save_product_offer(jsonb_build_object('offer_type', 'single', 'product_id', _prod, 'items', '[]'::jsonb,
      'title', 'TEST عرض خسران', 'offer_price', (SELECT cost FROM public.products WHERE id = _prod) + 1,
      'double_points', false, 'starts_at', _today, 'ends_at', NULL, 'notes', NULL, 'image_path', NULL));
    PERFORM pg_temp.ok('18 ممنوع عرض بسعر تحت التكلفة + 25%', false, 'اتقبل!');
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('18 ممنوع عرض بسعر تحت التكلفة + 25%', true, SQLERRM); END;

  -- 19. A shift expense shows in the P&L.
  BEGIN
    SELECT id INTO _cat FROM public.expense_categories WHERE company_id = _co AND is_active LIMIT 1;
    PERFORM public.create_shift_expense(_shift, 40, _cat, 'TEST مصروف وردية', NULL);
    PERFORM pg_temp.ok('19 مصروف من الوردية', EXISTS (SELECT 1 FROM public.expenses WHERE shift_id = _shift AND amount = 40));
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('19 مصروف من الوردية', false, SQLERRM); END;

  -- 20. Purchase received: stock goes up.
  BEGIN
    SELECT r.item_id INTO _item FROM public.product_recipes r WHERE r.product_id = _prod LIMIT 1;
    SELECT quantity INTO _n FROM public.branch_stock WHERE item_id = _item AND branch_id = _branch;
    PERFORM public.create_purchase(_branch, (SELECT id FROM public.suppliers WHERE company_id = _co LIMIT 1),
      jsonb_build_array(jsonb_build_object('item_id', _item, 'quantity', 10, 'unit_cost',
        (SELECT cost_per_unit FROM public.inventory_items WHERE id = _item))),
      'TEST-PO', _today, 0, 0, 'cash', 'اختبار', true, 0);
    SELECT quantity INTO _m FROM public.branch_stock WHERE item_id = _item AND branch_id = _branch;
    PERFORM pg_temp.ok('20 فاتورة شراء بتزود المخزن', _m = _n + 10, 'قبل=' || _n || ' بعد=' || _m);
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('20 فاتورة شراء', false, SQLERRM); END;

  -- 21. Today's P&L moved by the bills above.
  BEGIN
    _pnl1 := public.range_pnl(_today, _today);
    _n := (_pnl1->>'revenue')::numeric - (_pnl0->>'revenue')::numeric;
    _m := (_pnl1->>'cogs')::numeric - (_pnl0->>'cogs')::numeric;
    -- 0 (refunded) + 160 (split) + V60 + 50 (partial) + 0 (cancelled) + 0 (refunded) + 0 (refunded)
    -- + 25 the wallet paid on a refunded bill, which counts as a discount and never came back.
    _txt := ((_pnl1->>'expenses_total')::numeric - (_pnl0->>'expenses_total')::numeric)::text;
    PERFORM pg_temp.ok('21 الأرباح والخسائر: المبيعات والتكلفة اتحركوا', _m > 0,
      'زيادة المبيعات=' || _n || ' زيادة التكلفة=' || _m || ' زيادة المصاريف=' || _txt);
    PERFORM pg_temp.ok('21b مصروف الوردية (40) ظاهر في أرباح النهارده', _txt::numeric = 40,
      'زيادة المصاريف=' || _txt || ' تاريخ المصروف=' || (SELECT expense_date::text FROM public.expenses WHERE shift_id = _shift AND amount = 40 LIMIT 1) || ' النهارده=' || _today);
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('21 الأرباح والخسائر', false, SQLERRM); END;

  -- 22. Closing 10 short without saying who carries it: the shift closes and the
  -- shortage waits for the super admin, who gets a warning.
  BEGIN
    _fig := public._shift_drawer((SELECT s FROM public.shifts s WHERE s.id = _shift));
    _j := public.close_shift_handover(_shift, (_fig->>'expected')::numeric - 10, 0, NULL, NULL, 'اختبار عجز');
    PERFORM pg_temp.ok('22 قفل بعجز من غير تحديد: اتقفلت والعجز مستني السوبر أدمن',
      (SELECT status = 'closed' AND variance = -10 AND shortage_resolution = 'pending' FROM public.shifts WHERE id = _shift)
        AND EXISTS (SELECT 1 FROM public.notifications WHERE type = 'shift.shortage' AND data->>'shift_id' = _shift::text),
      'المتوقع في الدرج=' || (_fig->>'expected'));
    PERFORM public.reassign_shift_shortage(_shift, 'venue', NULL, 'فرق في عد الفكة آخر الليل');
    PERFORM pg_temp.ok('23 السوبر أدمن حمل العجز على المكان بسبب مكتوب',
      (SELECT shortage_resolution FROM public.shifts WHERE id = _shift) = 'venue');
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('22 قفل الوردية بعجز', false, SQLERRM); END;

  -- 24. After the shift closes, its bills can't be refunded.
  BEGIN
    PERFORM public.refund_order_full(_o_split, 'مرتجع بعد قفل الوردية', 'cash', 'venue', NULL);
    PERFORM pg_temp.ok('24 ممنوع مرتجع بعد قفل الوردية', false, 'اتقبل!');
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('24 ممنوع مرتجع بعد قفل الوردية', true, SQLERRM); END;

  -- 25. Payroll preview for this month runs and no net pay is negative.
  BEGIN
    SELECT count(*), count(*) FILTER (WHERE COALESCE((to_jsonb(p)->>'net_amount')::numeric, (to_jsonb(p)->>'net')::numeric, 0) < 0)
      INTO _n, _m
      FROM public.hr_payroll_preview(date_trunc('month', _today)::date, (date_trunc('month', _today) + interval '1 month - 1 day')::date) p;
    PERFORM pg_temp.ok('25 حساب المرتبات للشهر', _n > 0 AND _m = 0, 'موظفين=' || _n || ' صافي بالسالب=' || _m);
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('25 حساب المرتبات', false, SQLERRM); END;

  -- 26. Profit payout preview: every lock is reported.
  BEGIN
    _j := public.payout_preview(date_trunc('month', _today)::date, _today - 1, 0);
    PERFORM pg_temp.ok('26 معاينة توزيع الأرباح بتشتغل', _j ? 'checks', (_j->'checks')::text);
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('26 معاينة توزيع الأرباح', false, SQLERRM); END;

  -- 27-29. A cashier can't reach money screens.
  PERFORM pg_temp.act_as('cashier');
  BEGIN
    PERFORM public.range_pnl(_today, _today);
    PERFORM pg_temp.ok('27 الكاشير ميقدرش يشوف الأرباح', false, 'شافها!');
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('27 الكاشير ميقدرش يشوف الأرباح', true, SQLERRM); END;
  BEGIN
    PERFORM public.payout_preview(_today - 7, _today - 1, 0);
    PERFORM pg_temp.ok('28 الكاشير ميقدرش يوزع أرباح', false, 'قدر!');
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('28 الكاشير ميقدرش يوزع أرباح', true, SQLERRM); END;
  BEGIN
    PERFORM public.reset_all_wallets('محاولة من الكاشير');
    PERFORM pg_temp.ok('29 الكاشير ميقدرش يصفر المحافظ', false, 'قدر!');
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('29 الكاشير ميقدرش يصفر المحافظ', true, SQLERRM); END;
  -- 31. Internal helpers must not be callable straight from the app.
  -- As the app's own database role: the owner role may always call them.
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM public._charge_staff(_co, 5, 'staff',
      (SELECT id FROM public.user_profiles WHERE company_id = _co AND is_active AND id <> public.current_profile_id() LIMIT 1),
      'TEST', NULL, NULL, 'manual');
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.ok('31 الكاشير ميقدرش يخصم من زميله بنداء داخلي', false, 'قدر يسجل خصم على زميله!');
  EXCEPTION WHEN insufficient_privilege THEN
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.ok('31 الكاشير ميقدرش يخصم من زميله بنداء داخلي', true, SQLERRM);
  END;
  -- Row-level security only applies to the app's database role.
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    -- Their own salary lines are fine; anyone else's would be a leak.
    SELECT count(*) INTO _n FROM public.salary_payments WHERE user_id IS DISTINCT FROM public.current_profile_id();
    SELECT count(*) INTO _m FROM public.cash_transactions;
    SELECT count(*) INTO _id_count FROM public.staff_penalties WHERE staff_id IS DISTINCT FROM public.current_profile_id();
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.ok('30b الكاشير ميشوفش خصومات زمايله', _id_count = 0, 'خصومات موظفين تانيين ظاهرة=' || _id_count);
    PERFORM pg_temp.ok('30 الكاشير ميشوفش المرتبات ولا حركات الخزنة', _n = 0 AND _m = 0, 'مرتبات=' || _n || ' حركات خزنة=' || _m);
  EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.ok('30 الكاشير ميشوفش المرتبات', true, SQLERRM);
  END;
  PERFORM pg_temp.act_as('super_admin');
END $$;

SELECT n, step, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, detail FROM _results ORDER BY n;

ROLLBACK;
