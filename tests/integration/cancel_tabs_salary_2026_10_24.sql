-- =====================================================================
-- 2026-10-24 test: a cancelled item is not a refund, removing an item from a
-- partner-tab invoice comes off the tab, partner tab settlement (payment /
-- deduct / reverse), salary profit month and the payout salary check.
-- Runs on the real "20s" database in ONE transaction that ends in ROLLBACK.
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
CREATE OR REPLACE FUNCTION pg_temp.menu_item(_name text, _qty int DEFAULT 1) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_array(jsonb_build_object('product_id',
    (SELECT id FROM public.products WHERE name = _name AND is_active AND company_id = public.current_company_id() LIMIT 1),
    'quantity', _qty, 'modifiers', '[]'::jsonb))
$$;
CREATE OR REPLACE FUNCTION pg_temp.line(_order uuid, _name text) RETURNS uuid LANGUAGE sql AS $$
  SELECT id FROM public.order_items WHERE order_id = _order AND product_name = _name AND status = 'active' LIMIT 1
$$;
CREATE OR REPLACE FUNCTION pg_temp.cash_tender(_branch uuid, _shift uuid) RETURNS numeric LANGUAGE sql AS $$
  SELECT COALESCE((public.orders_period_summary(_branch, public.business_today(public.current_company_id()) - 3,
    public.business_today(public.current_company_id()), 'all', 'all', 'all', _shift, NULL)->'tenders'->>'cash')::numeric, 0)
$$;
CREATE OR REPLACE FUNCTION pg_temp.expected(_shift uuid) RETURNS numeric LANGUAGE sql AS $$
  SELECT (public.shift_expected_cash(_shift)->>'expected_cash')::numeric
$$;
CREATE OR REPLACE FUNCTION pg_temp.tab_open(_partner uuid) RETURNS numeric LANGUAGE sql AS $$
  SELECT COALESCE(SUM(total_amount - settled_amount), 0) FROM public.partner_tab_orders WHERE partner_id = _partner AND NOT is_settled
$$;

SELECT pg_temp.act_as('super_admin');

DO $$
DECLARE
  _co uuid := public.current_company_id(); _branch uuid; _shift uuid; _today date; _partner uuid;
  _o uuid; _o2 uuid; _o3 uuid; _id uuid; _n numeric; _m numeric; _k numeric; _txt text; _j jsonb; _r record;
  _batch uuid; _batch2 uuid; _user uuid; _sal uuid; _m0 date; _m1 date; _p0 numeric; _p1 numeric;
BEGIN
  IF public.current_profile_id() IS NULL THEN RAISE EXCEPTION 'setup: no super admin'; END IF;
  _today := public.business_today(_co);
  SELECT id INTO _branch FROM public.branches WHERE company_id = _co AND is_active ORDER BY created_at LIMIT 1;
  SELECT id INTO _shift FROM public.shifts WHERE branch_id = _branch AND status = 'open' ORDER BY opened_at DESC LIMIT 1;
  IF _shift IS NULL THEN _shift := public.open_shift_with_roster(_branch, 0, ARRAY[]::uuid[]); END IF;
  SELECT id INTO _partner FROM public.partners WHERE company_id = _co AND status = 'active' ORDER BY created_at LIMIT 1;

  -- 1. Old auto-refunds keep their meaning; nothing is switched on its own.
  PERFORM pg_temp.ok('01 old auto-refunds stay refunds',
    NOT EXISTS (SELECT 1 FROM public.order_refunds WHERE is_cancellation AND created_at < now() - interval '1 minute'
                AND reason NOT LIKE 'تصحيح:%'),
    (SELECT count(*) FROM public.order_refunds WHERE origin = 'void')::text || ' void rows');

  -- 2. Paid 115 cash, then the 85 item is cancelled: a cancellation, not a refund.
  BEGIN
    _n := pg_temp.cash_tender(_branch, _shift);
    _k := pg_temp.expected(_shift);
    SELECT out_id INTO _o FROM public.create_pos_order(_branch,
      pg_temp.custom_item('TEST Red Tea', 30) || pg_temp.custom_item('TEST Iced Americano', 85),
      jsonb_build_array(pg_temp.pay('cash', 115)), 'dine_in'::order_type);
    PERFORM public.void_order_item(pg_temp.line(_o, 'TEST Iced Americano'), 'ملغي');
    SELECT * INTO _r FROM public.order_refunds WHERE order_id = _o AND status = 'active';
    PERFORM pg_temp.ok('02 cancel after payment = cancellation row', _r.is_cancellation AND _r.amount = 85 AND _r.origin = 'void',
      'is_cancellation=' || _r.is_cancellation || ' amount=' || _r.amount);
    PERFORM pg_temp.ok('02b nobody has to bear it at close',
      NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.shift_refunds_to_decide(_shift)) e WHERE (e->>'refund_id')::uuid = _r.id));
    _m := pg_temp.cash_tender(_branch, _shift);
    PERFORM pg_temp.ok('02c cash card counts 30, not 115', _m - _n = 30, 'before=' || _n || ' after=' || _m);
    PERFORM pg_temp.ok('02d drawer expects 30 more', pg_temp.expected(_shift) - _k = 30,
      'before=' || _k || ' after=' || pg_temp.expected(_shift));
    PERFORM pg_temp.ok('02e invoice total 30, still completed',
      (SELECT total = 30 AND status = 'completed' FROM public.orders WHERE id = _o));
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('02 cancel after payment', false, SQLERRM); END;

  -- 3. Nobody can be charged for a cancellation.
  BEGIN
    PERFORM public.set_refund_bearer(_r.id, 'staff', public.current_profile_id());
    PERFORM pg_temp.ok('03 bearer refused on cancellation', false, 'accepted!');
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('03 bearer refused on cancellation', SQLERRM LIKE '%ملغي%', SQLERRM); END;

  -- 4. Cancel the last item too: the order is cancelled, drawer back to where it was.
  BEGIN
    PERFORM public.void_order_item(pg_temp.line(_o, 'TEST Red Tea'), 'ملغي');
    PERFORM pg_temp.ok('04 all lines cancelled -> order cancelled, drawer unchanged',
      (SELECT status = 'cancelled' FROM public.orders WHERE id = _o) AND pg_temp.expected(_shift) = _k
      AND (SELECT bool_and(is_cancellation) FROM public.order_refunds WHERE order_id = _o),
      'expected=' || pg_temp.expected(_shift) || ' vs ' || _k);
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('04 cancel last line', false, SQLERRM); END;

  -- 5. A real refund (refund button) still needs a bearer.
  BEGIN
    SELECT out_id INTO _o2 FROM public.create_pos_order(_branch, pg_temp.custom_item('TEST مرتجع', 50, 2),
      jsonb_build_array(pg_temp.pay('cash', 100)), 'dine_in'::order_type);
    PERFORM public.refund_order_items(_o2,
      jsonb_build_array(jsonb_build_object('order_item_id', pg_temp.line(_o2, 'TEST مرتجع'), 'quantity', 1, 'disposition', 'restock')),
      'cash', 'اختبار مرتجع حقيقي');
    SELECT * INTO _r FROM public.order_refunds WHERE order_id = _o2 AND status = 'active';
    PERFORM pg_temp.ok('05 manual refund stays a refund and needs a bearer', NOT _r.is_cancellation
      AND EXISTS (SELECT 1 FROM jsonb_array_elements(public.shift_refunds_to_decide(_shift)) e WHERE (e->>'refund_id')::uuid = _r.id),
      'is_cancellation=' || _r.is_cancellation || ' fault=' || COALESCE(_r.fault, 'null'));
    _j := public.refund_reclassify_preview(_r.id);
    PERFORM pg_temp.ok('05b a real refund cannot be switched', NOT (_j->>'can_change')::boolean, _j->>'blocker');
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('05 manual refund', false, SQLERRM); END;

  -- 6. Switch an old auto-refund by hand: preview, switch, switch back, all audited.
  BEGIN
    SELECT * INTO _r FROM public.order_refunds
     WHERE origin = 'void' AND status = 'active' AND NOT is_cancellation AND COALESCE(fault, 'venue') = 'venue'
     ORDER BY created_at LIMIT 1;
    IF _r.id IS NULL THEN
      PERFORM pg_temp.ok('06 no old auto-refund to switch', true, 'skipped');
    ELSE
      _j := public.refund_reclassify_preview(_r.id);
      PERFORM pg_temp.ok('06 preview lists the effect', (_j->>'can_change')::boolean AND (_j->>'to_cancellation')::boolean
        AND jsonb_array_length(_j->'effects') >= 3, (_j->'effects')::text);
      _n := (public._range_pnl(_co, _r.business_date, _r.business_date)->>'net_profit')::numeric;
      BEGIN
        PERFORM public.reclassify_refund(_r.id, true, '');
        PERFORM pg_temp.ok('06b a reason is required', false);
      EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('06b a reason is required', true, SQLERRM); END;
      PERFORM public.reclassify_refund(_r.id, true, 'اختبار تحويل لإلغاء');
      PERFORM pg_temp.ok('06c switched + recorded who/why',
        (SELECT is_cancellation AND reclassified_by IS NOT NULL AND reclassify_note = 'اختبار تحويل لإلغاء'
           FROM public.order_refunds WHERE id = _r.id)
        AND EXISTS (SELECT 1 FROM public.audit_logs WHERE entity_id = _r.id AND action = 'refund.reclassified'));
      PERFORM pg_temp.ok('06d net profit of that day unchanged',
        (public._range_pnl(_co, _r.business_date, _r.business_date)->>'net_profit')::numeric = _n);
      PERFORM public.reclassify_refund(_r.id, false, 'اختبار رجوع لمرتجع');
      PERFORM pg_temp.ok('06e switched back', (SELECT NOT is_cancellation FROM public.order_refunds WHERE id = _r.id));
    END IF;
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('06 switch old auto-refund', false, SQLERRM); END;

  -- 7. Partner tab (custom items are not allowed on a tab, so menu items with no recipe, to skip the stock check):
  --    removing items comes off the partner's account.
  BEGIN
    _n := pg_temp.tab_open(_partner);
    SELECT out_id INTO _o3 FROM public.create_pos_order(_branch,
      pg_temp.menu_item('Nutella Waffle') || pg_temp.menu_item('Mint Tea'), '[]'::jsonb,
      'dine_in'::order_type, _partner_id => _partner, _on_partner_tab => true);
    _m := (SELECT line_total FROM public.order_items WHERE id = pg_temp.line(_o3, 'Nutella Waffle'));
    _k := (SELECT line_total FROM public.order_items WHERE id = pg_temp.line(_o3, 'Mint Tea'));
    PERFORM pg_temp.ok('07 tab owes both items', pg_temp.tab_open(_partner) - _n = _m + _k, (_m + _k)::text);
    PERFORM public.void_order_item(pg_temp.line(_o3, 'Nutella Waffle'), 'ملغي');
    PERFORM pg_temp.ok('07b removed waffle comes off the tab', pg_temp.tab_open(_partner) - _n = _k
      AND (SELECT total_amount FROM public.partner_tab_orders WHERE order_id = _o3) = _k,
      'tab now ' || (pg_temp.tab_open(_partner) - _n));
    PERFORM public.void_order_item(pg_temp.line(_o3, 'Mint Tea'), 'ملغي');
    PERFORM pg_temp.ok('07c last item too: nothing owed, order cancelled, no cash out',
      pg_temp.tab_open(_partner) = _n AND (SELECT status = 'cancelled' FROM public.orders WHERE id = _o3)
      AND NOT EXISTS (SELECT 1 FROM public.order_refunds WHERE order_id = _o3 AND public.tender_key(method_key) <> 'partner_tab'),
      'tab delta ' || (pg_temp.tab_open(_partner) - _n));
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('07 partner tab void', false, SQLERRM); END;

  -- 8. The 261024-0002 fix: no tab owes more than its invoice because of a removed item.
  PERFORM pg_temp.ok('08 no tab owes a removed item',
    NOT EXISTS (SELECT 1 FROM public.partner_tab_orders t JOIN public.orders o ON o.id = t.order_id
                 WHERE NOT t.is_settled AND t.total_amount > o.total
                   AND EXISTS (SELECT 1 FROM public.order_items i WHERE i.order_id = o.id AND i.status = 'voided')));

  -- 9. Settle a tab: partial payment in cash, then deduct from the balance, then reverse.
  BEGIN
    SELECT out_id INTO _o3 FROM public.create_pos_order(_branch, pg_temp.menu_item('Nutella Waffle', 3), '[]'::jsonb,
      'dine_in'::order_type, _partner_id => _partner, _on_partner_tab => true);
    _n := pg_temp.tab_open(_partner);
    _p0 := (public._range_pnl(_co, _today, _today)->>'revenue')::numeric;
    PERFORM pg_temp.ok('09 shows in partner_tabs_due',
      EXISTS (SELECT 1 FROM jsonb_array_elements(public.partner_tabs_due()->'partners') p
               WHERE (p->>'partner_id')::uuid = _partner AND (p->>'open')::numeric = _n));
    _j := public.settle_partner_tab(_partner, 200, 'payment', 'cash', NULL, 'اختبار سداد');
    _batch := (_j->>'batch_id')::uuid;
    PERFORM pg_temp.ok('09b paid 200 cash: owes 200 less', pg_temp.tab_open(_partner) = _n - 200, _j::text);
    PERFORM pg_temp.ok('09c treasury got 200 in',
      EXISTS (SELECT 1 FROM public.cash_transactions WHERE reference_id = _batch AND direction = 'in' AND amount = 200
               AND category = 'partner_tab_settlement'));
    PERFORM pg_temp.ok('09d revenue unchanged (sale already counted)',
      (public._range_pnl(_co, _today, _today)->>'revenue')::numeric = _p0);
    _k := public.partner_balance(_partner);
    _j := public.settle_partner_tab(_partner, 50, 'deduct', NULL, NULL, 'اختبار خصم');
    _batch2 := (_j->>'batch_id')::uuid;
    PERFORM pg_temp.ok('09e deduct 50: owes 50 less, balance 50 less',
      pg_temp.tab_open(_partner) = _n - 250 AND public.partner_balance(_partner) = _k - 50, _j::text);
    BEGIN
      PERFORM public.settle_partner_tab(_partner, _n, 'payment', 'cash', NULL, NULL);
      PERFORM pg_temp.ok('09f more than owed is refused', false);
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('09f more than owed is refused', SQLERRM LIKE '%أكبر من المستحق%', SQLERRM); END;
    PERFORM pg_temp.ok('09g next payout deducts only what is left',
      COALESCE((SELECT (l->>'tab_open')::numeric FROM jsonb_array_elements(public._payout_calc(_co, _today, _today, 0)->'lines') l
                 WHERE (l->>'partner_id')::uuid = _partner), pg_temp.tab_open(_partner)) = pg_temp.tab_open(_partner));
    PERFORM public.reverse_partner_tab_settlement(_batch, 'اختبار إلغاء السداد');
    PERFORM pg_temp.ok('09h reverse payment: owed again, money out, rows kept',
      pg_temp.tab_open(_partner) = _n - 50
      AND EXISTS (SELECT 1 FROM public.cash_transactions WHERE reference_id = _batch AND direction = 'out' AND amount = 200)
      AND (SELECT bool_and(status = 'reversed') FROM public.partner_tab_settlements WHERE batch_id = _batch));
    PERFORM public.reverse_partner_tab_settlement(_batch2, 'اختبار إلغاء الخصم');
    PERFORM pg_temp.ok('09i reverse deduct: balance back', public.partner_balance(_partner) = _k AND pg_temp.tab_open(_partner) = _n);
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('09 settle tab', false, SQLERRM); END;

  -- 10. Cashier cannot settle or switch.
  PERFORM pg_temp.act_as('cashier');
  BEGIN
    PERFORM public.settle_partner_tab(_partner, 1, 'payment', 'cash', NULL, NULL);
    PERFORM pg_temp.ok('10 cashier cannot settle', false);
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('10 cashier cannot settle', true, SQLERRM); END;
  PERFORM pg_temp.act_as('super_admin');

  -- 11. Salary profit month + payout salary check.
  BEGIN
    _m0 := (date_trunc('month', _today) - interval '1 month')::date;
    _m1 := (_m0 + interval '1 month' - interval '1 day')::date;
    SELECT x.user_id INTO _user FROM public._payroll_lines(_co, _m0, _m1) x
     WHERE NOT x.already_generated AND x.prorated_salary > 0 ORDER BY x.employee_name LIMIT 1;
    IF _user IS NULL THEN
      PERFORM pg_temp.ok('11 no unpaid employee last month', true, 'skipped');
    ELSE
      _j := public._payout_calc(_co, _m0, _m1, 0);
      PERFORM pg_temp.ok('11 payout blocked while salaries are missing',
        NOT (_j->'checks'->>'payroll_recorded')::boolean
        AND EXISTS (SELECT 1 FROM jsonb_array_elements(_j->'payroll_missing'->'lines') l WHERE (l->>'user_id')::uuid = _user),
        (_j->'payroll_missing')::text);
      _sal := public._issue_salary_line(_co, public.current_profile_id(), _user, _m0, _m1);
      PERFORM pg_temp.ok('11b issued employee leaves the missing list',
        NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public._payout_calc(_co, _m0, _m1, 0)->'payroll_missing'->'lines') l
                     WHERE (l->>'user_id')::uuid = _user));
      _p0 := (public._range_pnl(_co, _m0, _m1)->>'payroll_total')::numeric;
      _p1 := (public._range_pnl(_co, _m1 + 1, (_m1 + 1 + interval '1 month' - interval '1 day')::date)->>'payroll_total')::numeric;
      _n := public.salary_line_cost((SELECT s FROM public.salary_payments s WHERE id = _sal));
      _j := public.salary_pnl_month_preview(_sal, _m1 + 1);
      PERFORM pg_temp.ok('11c preview shows the move', (_j->>'changed')::boolean AND (_j->>'can_change')::boolean
        AND (_j->>'new_from')::date = _m1 + 1, _j::text);
      PERFORM public.set_salary_pnl_month(_sal, _m1 + 1, 'اختبار');
      PERFORM pg_temp.ok('11d cost moved to the chosen month',
        round((public._range_pnl(_co, _m0, _m1)->>'payroll_total')::numeric, 2) = round(_p0 - _n, 2)
        AND round((public._range_pnl(_co, _m1 + 1, (_m1 + 1 + interval '1 month' - interval '1 day')::date)->>'payroll_total')::numeric, 2) = round(_p1 + _n, 2),
        'cost=' || _n || ' old ' || _p0 || ' new ' || _p1);
      PERFORM public.set_salary_pnl_month(_sal, _m0, 'رجوع');
      PERFORM pg_temp.ok('11e back to its own month = empty', (SELECT pnl_month IS NULL FROM public.salary_payments WHERE id = _sal));
    END IF;
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('11 salary month', false, SQLERRM); END;

  -- 12. Nothing can be deleted.
  BEGIN
    DELETE FROM public.order_refunds WHERE order_id = _o;
    PERFORM pg_temp.ok('12 refunds cannot be deleted', EXISTS (SELECT 1 FROM public.order_refunds WHERE order_id = _o));
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('12 refunds cannot be deleted', true, SQLERRM); END;

  -- 13. A new partner can be added (the share-snapshot trigger used to fail on INSERT).
  BEGIN
    _id := public.create_partner_entry('شريك تجربة', NULL, '01000000000', NULL);
    UPDATE public.partners SET name = 'شريك تجربة ٢' WHERE id = _id;
    PERFORM pg_temp.ok('13 add then rename a partner', (SELECT name = 'شريك تجربة ٢' FROM public.partners WHERE id = _id));
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.ok('13 add then rename a partner', false, SQLERRM); END;
END $$;

SELECT n, step, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, detail FROM _results ORDER BY n;

ROLLBACK;
