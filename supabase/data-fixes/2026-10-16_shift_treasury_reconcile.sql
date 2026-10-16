-- =====================================================================
-- One-off data fix for the 20s cafe database (2026-10-16), found by checking
-- every shift's invoices against what reached the treasury.
--
-- 1) Undo part of this morning's fix (2026-10-16_record_missing_void_refunds):
--    four cancelled invoices were in shifts that were force-closed on 6–8 Oct
--    (261006-0016, 261007-0008, 261007-0018, 261008-0038). That force close
--    already left their cash out of the deposit, so the per-invoice treasury
--    "out" (515 EGP) took the same money out twice. Those four treasury moves
--    are voided; the refund rows stay (the money did go back to customers).
-- 2) The force close of the 7 Oct shift also subtracted 230 EGP of refunds on
--    those cancelled invoices whose cash it had already left out: the drawer by
--    the invoices was 3,805, the deposit 3,575. 230 EGP goes into the main cash.
-- 3) InstaPay money from four force-closed shifts (6–10 Oct) never reached the
--    treasury: 2,685 EGP goes into the InstaPay account, one move per shift,
--    dated the day each shift closed.
-- No invoice, payment or refund is changed or deleted. Audited.
-- =====================================================================
DO $$
DECLARE
  _co uuid := '11111111-1111-1111-1111-111111111111';
  _voided int; _r record; _acc uuid; _n int := 0; _sum numeric := 0;
BEGIN
  -- 1) void the four double treasury outs
  WITH v AS (
    UPDATE public.cash_transactions ct SET status = 'voided'
      FROM public.order_refunds r JOIN public.orders o ON o.id = r.order_id
     WHERE ct.reference_type = 'order_refund' AND ct.reference_id = r.id AND ct.status = 'active'
       AND o.order_number IN ('261006-0016', '261007-0008', '261007-0018', '261008-0038')
    RETURNING ct.id, ct.amount)
  SELECT count(*), COALESCE(SUM(amount), 0) INTO _voided, _sum FROM v;
  IF _voided <> 4 OR _sum <> 515 THEN RAISE EXCEPTION 'Expected 4 / 515 voided, got % / %', _voided, _sum; END IF;
  INSERT INTO public.audit_logs (company_id, action, module, entity_type, old_values, new_values, reason)
  VALUES (_co, 'treasury.void_double_refund_out', 'finance', 'cash_transactions', NULL,
    jsonb_build_object('count', 4, 'amount', 515),
    'الوردية اتقفلت قفل إجباري ومكانتش حاطة فلوس الفواتير الملغية في الخزنة أصلاً؛ الخروج اتعمل مرتين');

  -- 2) the 7 Oct shift: 230 under-deposited
  PERFORM public.post_cash_txn(_co, public.default_cash_account(_co, 'cash'), 'in', 230, 'shift_deposit', 'cash',
    DATE '2026-10-08', 'shift', 'af633070-304b-474a-ab7a-64a1369082ea',
    'تصحيح قفل وردية 7 أكتوبر: مرتجعات الفواتير الملغية اتخصمت مرتين', NULL, false);
  INSERT INTO public.audit_logs (company_id, action, module, entity_type, entity_id, old_values, new_values, reason)
  VALUES (_co, 'shift.deposit_fix', 'finance', 'shifts', 'af633070-304b-474a-ab7a-64a1369082ea',
    jsonb_build_object('deposited', 3575), jsonb_build_object('deposited', 3805),
    'درج الوردية حسب الفواتير 3,805 والمتورد 3,575');

  -- 3) InstaPay never posted from force-closed shifts
  _acc := public.default_cash_account(_co, 'instapay');
  IF _acc IS NULL THEN RAISE EXCEPTION 'No InstaPay account'; END IF;
  _sum := 0;
  FOR _r IN
    SELECT s.id, public.business_date(s.closed_at, s.company_id) AS d,
           SUM(op.amount) - COALESCE((SELECT SUM(amount) FROM public.order_refunds WHERE shift_id = s.id AND status = 'active' AND method_key = 'instapay'), 0) AS due
      FROM public.shifts s JOIN public.orders o ON o.shift_id = s.id JOIN public.order_payments op ON op.order_id = o.id
     WHERE s.status = 'closed' AND op.method_key = 'instapay'
       AND NOT EXISTS (SELECT 1 FROM public.cash_transactions ct WHERE ct.reference_id = s.id AND ct.status = 'active' AND ct.method = 'instapay')
     GROUP BY s.id
  LOOP
    PERFORM public.post_cash_txn(_co, _acc, 'in', _r.due, 'electronic_settlement', 'instapay', _r.d, 'shift', _r.id,
      'إنستاباي وردية اتقفلت قفل إجباري ومتسجلش في الخزنة', NULL, false);
    INSERT INTO public.audit_logs (company_id, action, module, entity_type, entity_id, old_values, new_values, reason)
    VALUES (_co, 'shift.electronic_fix', 'finance', 'shifts', _r.id, NULL, jsonb_build_object('instapay', _r.due),
      'فلوس إنستاباي من الفواتير ماوصلتش للخزنة');
    _n := _n + 1; _sum := _sum + _r.due;
  END LOOP;
  IF _n <> 4 OR _sum <> 2685 THEN RAISE EXCEPTION 'Expected 4 shifts / 2685 InstaPay, got % / %', _n, _sum; END IF;
END $$;
