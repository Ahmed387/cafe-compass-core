-- =====================================================================
-- One-off data fix for the 20s cafe database (owner decision 2026-10-15):
-- "الفواتير هي الفيصل" — the invoices decide what was in the drawer.
--
-- 14 shifts (18 Sep – 4 Oct) were closed with the drawer typed as 0 or less
-- than the invoices, which booked 61,525 EGP of fake cash shortage in the P&L.
-- For each one:
--   expected = closing = opening + cash payments − cash refunds − drawer expenses
--   variance = 0, cash dropped to the main safe = closing
--   treasury: only the part not already deposited is posted (shifts 16/19
--   were already deposited when force-closed), dated on the closing day.
-- Every change is written to the audit log. No order or payment is touched.
-- Not a schema migration: kept here for the record; ids are this tenant's.
-- =====================================================================
DO $$
DECLARE
  _ids uuid[] := ARRAY['73f2143b-ec3a-4897-a077-c0341cfe3a3f','0b4d3bdd-e69a-4faf-9730-959a8a7ef0c1',
    'e12bfd37-2e31-4816-b4af-09c69efa5075','ba4259fd-7a12-4ab4-9d66-9d7766936142','6d3311a4-62b4-45d1-ae41-ff74ca510af8',
    '544f17b2-b729-4bf0-ab43-51e0724ade36','22af916b-4aa0-41a9-bcbd-28ad70b4a358','15a46bfb-966e-4825-a825-e70a2fd9c3ce',
    'a8eaa1d7-3e28-43cb-8a64-9d1b7424610f','36eb40f9-da71-4466-8f1a-b189af83fd08','eab2a756-0ef2-4602-96b0-d9f5f3fd4454',
    '969c7847-c04d-4014-a813-488aff7483df','6b2e4333-d25c-49dc-aca0-1736fe68065a','4ea8db46-dee9-4bd9-b475-1152b264d374']::uuid[];
  _s public.shifts; _in numeric; _out numeric; _exp numeric; _cash numeric; _posted numeric; _acc uuid; _day date;
BEGIN
  PERFORM set_config('app.shift_rpc_edit', 'on', true);
  FOREACH _s.id IN ARRAY _ids LOOP
    SELECT * INTO _s FROM public.shifts WHERE id = _s.id AND status = 'closed' FOR UPDATE;
    CONTINUE WHEN _s.id IS NULL;
    SELECT COALESCE(SUM(p.amount), 0) INTO _in FROM public.orders o JOIN public.order_payments p ON p.order_id = o.id
     WHERE o.shift_id = _s.id AND p.method_key = 'cash';
    SELECT COALESCE(SUM(r.amount), 0) INTO _out FROM public.order_refunds r
     WHERE r.shift_id = _s.id AND r.status = 'active' AND COALESCE(r.method_key, 'cash') = 'cash';
    _exp := public.shift_expense_total(_s.id);
    _cash := round(_s.opening_cash + _in - _out - _exp, 2);
    _day := public.business_date(_s.closed_at, _s.company_id);

    INSERT INTO public.audit_logs (company_id, branch_id, action, module, entity_type, entity_id, old_values, new_values, reason)
    VALUES (_s.company_id, _s.branch_id, 'shift.close_from_invoices', 'pos', 'shifts', _s.id,
      jsonb_build_object('expected_cash', _s.expected_cash, 'closing_cash', _s.closing_cash, 'variance', _s.variance),
      jsonb_build_object('expected_cash', _cash, 'closing_cash', _cash, 'variance', 0),
      'تقفيل وردية قديمة على الفواتير (قرار صاحب الكافيه 2026-10-15)');

    UPDATE public.shifts SET expected_cash = _cash, closing_cash = _cash, variance = 0,
      retained_float = 0, cash_drop = _cash, shortage_resolution = NULL, shortage_staff_id = NULL, updated_at = now()
     WHERE id = _s.id;

    SELECT COALESCE(SUM(CASE WHEN ct.direction = 'in' THEN ct.amount ELSE -ct.amount END), 0) INTO _posted
      FROM public.cash_transactions ct
     WHERE ct.reference_type = 'shift' AND ct.reference_id = _s.id AND ct.status = 'active' AND ct.category = 'shift_deposit';
    _acc := public.default_cash_account(_s.company_id, 'cash');
    IF _acc IS NOT NULL AND round(_cash - _posted, 2) <> 0 THEN
      PERFORM public.post_cash_txn(_s.company_id, _acc, CASE WHEN _cash > _posted THEN 'in' ELSE 'out' END,
        abs(round(_cash - _posted, 2)), 'shift_deposit', 'cash', _day, 'shift', _s.id,
        'تقفيل وردية قديمة على الفواتير', NULL, false);
    END IF;
  END LOOP;
END $$;
