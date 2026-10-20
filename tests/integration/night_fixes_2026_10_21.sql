-- =====================================================================
-- Integration tests for the 2026-10-21 fixes. Run against a database that
-- has the 20261021* migrations applied, e.g. in the Supabase SQL editor.
-- Everything runs in ONE transaction that ends in ROLLBACK: no invoice,
-- shift, refund or treasury line created here is kept.
-- Every check raises an exception on failure; success ends with
-- NOTICE 'ALL NIGHT-FIX TESTS PASSED'.
-- =====================================================================
BEGIN;

-- Act as the super admin (auth.uid() reads the JWT claims).
SELECT set_config('request.jwt.claims',
  json_build_object('sub', up.auth_user_id, 'role', 'authenticated')::text, true)
  FROM public.user_profiles up
  JOIN public.user_roles ur ON ur.user_id = up.id
  JOIN public.roles r ON r.id = ur.role_id
 WHERE r.key = 'super_admin' AND up.is_active AND up.auth_user_id IS NOT NULL
 LIMIT 1;

DO $$
DECLARE
  _branch uuid; _shift uuid; _order uuid; _num text; _tab_order uuid; _partner uuid;
  _fig jsonb; _cash_in numeric; _insta numeric; _open_day date; _tab public.partner_tab_orders;
  _cust uuid; _n int; _salary uuid; _paid_day date; _txn_day date;
  _item jsonb := jsonb_build_array(jsonb_build_object('custom', true, 'product_id', NULL, 'size_id', NULL,
    'product_name', 'TEST نايت', 'size_name', NULL, 'unit_price', 100, 'quantity', 1, 'is_taxable', false, 'modifiers', '[]'::jsonb));
BEGIN
  IF public.current_profile_id() IS NULL THEN RAISE EXCEPTION 'setup: no super admin to act as'; END IF;
  SELECT b.id INTO _branch FROM public.branches b WHERE b.company_id = public.current_company_id() LIMIT 1;

  -- A shift of our own (close any open one of this branch inside the rolled-back transaction).
  SELECT id INTO _shift FROM public.shifts WHERE branch_id = _branch AND status = 'open' LIMIT 1;
  IF _shift IS NULL THEN
    _shift := public.open_shift_with_roster(_branch, 200, ARRAY[]::uuid[]);
  END IF;

  ---------------------------------------------------------------------
  -- 1) One bill paid two ways lands in two accounts.
  ---------------------------------------------------------------------
  SELECT out_id, out_number INTO _order, _num FROM public.create_pos_order(_branch, _item,
    jsonb_build_array(
      jsonb_build_object('method_key', 'cash', 'amount', 60,
        'payment_method_id', (SELECT id FROM public.payment_methods WHERE key = 'cash' LIMIT 1)),
      jsonb_build_object('method_key', 'instapay', 'amount', 40,
        'payment_method_id', (SELECT id FROM public.payment_methods WHERE key = 'instapay' LIMIT 1))));
  IF (SELECT count(*) FROM public.order_payments WHERE order_id = _order) <> 2 THEN
    RAISE EXCEPTION '1: expected 2 payment lines';
  END IF;
  IF (SELECT SUM(amount) FILTER (WHERE method_key = 'cash') FROM public.order_payments WHERE order_id = _order) <> 60
     OR (SELECT SUM(amount) FILTER (WHERE method_key = 'instapay') FROM public.order_payments WHERE order_id = _order) <> 40 THEN
    RAISE EXCEPTION '1: amounts not kept per method';
  END IF;

  ---------------------------------------------------------------------
  -- 2) Cancelling a partner-tab invoice takes it off the partner's account.
  ---------------------------------------------------------------------
  SELECT id INTO _partner FROM public.partners WHERE company_id = public.current_company_id() AND status = 'active' LIMIT 1;
  IF _partner IS NOT NULL THEN
    SELECT out_id INTO _tab_order FROM public.create_pos_order(_branch, _item, '[]'::jsonb,
      _partner_id => _partner, _on_partner_tab => true);
    SELECT * INTO _tab FROM public.partner_tab_orders WHERE order_id = _tab_order;
    IF _tab.id IS NULL OR _tab.total_amount <> 100 THEN RAISE EXCEPTION '2: tab not created for 100'; END IF;
    PERFORM public.cancel_pos_order(_tab_order, 'اختبار إلغاء فاتورة شريك');
    SELECT * INTO _tab FROM public.partner_tab_orders WHERE order_id = _tab_order;
    IF _tab.total_amount <> 0 THEN RAISE EXCEPTION '2: tab still owes % after cancel', _tab.total_amount; END IF;
    IF (SELECT status FROM public.orders WHERE id = _tab_order) <> 'cancelled' THEN RAISE EXCEPTION '2: not cancelled'; END IF;
    IF EXISTS (SELECT 1 FROM public.order_refunds WHERE order_id = _tab_order AND public.tender_key(method_key) = 'cash') THEN
      RAISE EXCEPTION '2: a partner-tab cancel must never refund cash';
    END IF;
  ELSE
    RAISE NOTICE '2: skipped (no active partner)';
  END IF;

  ---------------------------------------------------------------------
  -- 3) The shift's treasury lines are dated to the day it opened.
  ---------------------------------------------------------------------
  -- Pretend the shift opened yesterday evening so the close crosses midnight.
  UPDATE public.shifts SET opened_at = now() - interval '1 day' WHERE id = _shift;
  _open_day := public.business_date(now() - interval '1 day', public.current_company_id());
  _fig := public._shift_drawer((SELECT s FROM public.shifts s WHERE s.id = _shift));
  PERFORM public.close_shift_handover(_shift, (_fig->>'expected')::numeric, 0, NULL, NULL, 'اختبار');
  SELECT SUM(amount) INTO _cash_in FROM public.cash_transactions
   WHERE reference_type = 'shift' AND reference_id = _shift AND category = 'shift_deposit';
  SELECT SUM(amount) INTO _insta FROM public.cash_transactions
   WHERE reference_type = 'shift' AND reference_id = _shift AND category = 'electronic_settlement' AND method = 'instapay';
  IF COALESCE(_insta, 0) < 40 THEN RAISE EXCEPTION '3: InstaPay 40 did not reach its account (got %)', _insta; END IF;
  IF COALESCE(_cash_in, 0) < 60 THEN RAISE EXCEPTION '3: cash 60 did not reach the treasury (got %)', _cash_in; END IF;
  IF EXISTS (SELECT 1 FROM public.cash_transactions WHERE reference_type = 'shift' AND reference_id = _shift
              AND txn_date <> _open_day) THEN
    RAISE EXCEPTION '3: shift money not dated to the opening day %', _open_day;
  END IF;

  ---------------------------------------------------------------------
  -- 4) Cashback target restart: one customer, then everyone. Wallets untouched.
  ---------------------------------------------------------------------
  SELECT id INTO _cust FROM public.customers WHERE company_id = public.current_company_id() LIMIT 1;
  IF _cust IS NOT NULL THEN
    UPDATE public.customers SET cashback_progress = 123 WHERE id = _cust;
    _n := public.reset_cashback_progress(_cust, 'اختبار');
    IF _n <> 1 OR (SELECT cashback_progress FROM public.customers WHERE id = _cust) <> 0 THEN
      RAISE EXCEPTION '4: single reset failed';
    END IF;
    UPDATE public.customers SET cashback_progress = 50 WHERE company_id = public.current_company_id();
    PERFORM public.reset_cashback_progress(NULL, 'اختبار');
    IF EXISTS (SELECT 1 FROM public.customers WHERE company_id = public.current_company_id() AND cashback_progress <> 0) THEN
      RAISE EXCEPTION '4: reset-all left progress';
    END IF;
  END IF;

  ---------------------------------------------------------------------
  -- 5) Customer lookup from 3 phone digits.
  ---------------------------------------------------------------------
  IF _cust IS NOT NULL AND (SELECT phone FROM public.customers WHERE id = _cust) IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM public.pos_customer_lookup(
         right(regexp_replace((SELECT phone FROM public.customers WHERE id = _cust), '\D', '', 'g'), 4)) l
         WHERE l.id = _cust) THEN
      RAISE EXCEPTION '5: lookup by the last 4 digits did not find the customer';
    END IF;
  END IF;
  IF EXISTS (SELECT 1 FROM public.pos_customer_lookup('01')) THEN RAISE EXCEPTION '5: 2 characters must not search'; END IF;

  ---------------------------------------------------------------------
  -- 6) Salary paid on a chosen past day.
  ---------------------------------------------------------------------
  SELECT id INTO _salary FROM public.salary_payments
   WHERE company_id = public.current_company_id() AND status = 'active' AND paid_at IS NULL LIMIT 1;
  IF _salary IS NOT NULL THEN
    _paid_day := public.business_date(now(), public.current_company_id()) - 3;
    PERFORM public.pay_salary(_salary, NULL, 'cash', _paid_day);
    SELECT txn_date INTO _txn_day FROM public.cash_transactions WHERE reference_type = 'salary_payment' AND reference_id = _salary;
    IF _txn_day <> _paid_day THEN RAISE EXCEPTION '6: treasury dated % not %', _txn_day, _paid_day; END IF;
    IF public.business_date((SELECT paid_at FROM public.salary_payments WHERE id = _salary), public.current_company_id()) <> _paid_day THEN
      RAISE EXCEPTION '6: paid_at not on the chosen day';
    END IF;
    BEGIN
      PERFORM public.pay_salary(_salary, NULL, 'cash', _paid_day + 10);
      RAISE EXCEPTION '6: a future / repeated payment must fail';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE '6:%' THEN RAISE; END IF;
    END;
  ELSE
    RAISE NOTICE '6: skipped (no unpaid salary)';
  END IF;

  ---------------------------------------------------------------------
  -- 7) Cashiers have shifts.close again.
  ---------------------------------------------------------------------
  IF NOT EXISTS (SELECT 1 FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id
                   JOIN public.permissions p ON p.id = rp.permission_id
                  WHERE r.key = 'cashier' AND p.key = 'shifts.close') THEN
    RAISE EXCEPTION '7: cashier cannot close shifts';
  END IF;

  RAISE NOTICE 'ALL NIGHT-FIX TESTS PASSED';
END $$;

ROLLBACK;
