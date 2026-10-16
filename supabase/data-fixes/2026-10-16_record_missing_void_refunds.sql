-- =====================================================================
-- One-off data fix for the 20s cafe database (owner decision 2026-10-16):
-- "طالما الفاتورة عليها مرتجع يبقى الفلوس رجعت لأصحابها".
--
-- 12 invoices kept money after lines were removed (the void-refund bug fixed
-- in migration 20261015130000): 9 cancelled (780) + 3 completed (165) = 945.
-- For each invoice:
--   * one refund row for exactly the missing amount, same payment method as
--     the invoice, on the invoice's own shift, origin 'void' (lines already
--     left the sale, so revenue does not change)
--   * one treasury "out" for that invoice from the account that received the
--     money (cash 915, card 30), dated today, naming the invoice number
-- Closed shifts keep their frozen expected cash and variance.
-- No order, line or payment is changed or deleted. Every step is audited.
-- =====================================================================
DO $$
DECLARE
  _numbers text[] := ARRAY['SO-260918-0045','20S-260923-0014','20S-260925-0044','261002-0001','261002-0037',
    '261002-0045','261006-0009','261006-0016','261007-0008','261007-0018','261008-0038','261009-0046'];
  _o record; _ref uuid; _acc uuid; _total numeric := 0; _n int := 0;
BEGIN
  PERFORM set_config('app.shift_rpc_edit', 'on', true);
  FOR _o IN
    WITH p AS (SELECT order_id, SUM(amount) paid, MIN(method_key) method, COUNT(DISTINCT method_key) n_methods
                 FROM public.order_payments GROUP BY 1),
         r AS (SELECT order_id, SUM(amount) refunded FROM public.order_refunds WHERE status = 'active' GROUP BY 1)
    SELECT o.id, o.company_id, o.branch_id, o.shift_id, o.order_number, o.status, p.method, p.n_methods,
           round(p.paid - COALESCE(r.refunded, 0) - CASE WHEN o.status = 'cancelled' THEN 0 ELSE o.total END, 2) AS gap
      FROM public.orders o JOIN p ON p.order_id = o.id LEFT JOIN r ON r.order_id = o.id
     WHERE o.order_number = ANY (_numbers)
  LOOP
    IF _o.n_methods <> 1 THEN RAISE EXCEPTION 'Invoice % was paid with several methods', _o.order_number; END IF;
    IF _o.gap <= 0 THEN RAISE NOTICE 'Invoice % has nothing missing, skipped', _o.order_number; CONTINUE; END IF;

    INSERT INTO public.order_refunds (company_id, branch_id, order_id, shift_id, kind, amount, method_key, reason, origin)
    VALUES (_o.company_id, _o.branch_id, _o.id, _o.shift_id,
            CASE WHEN _o.status = 'cancelled' THEN 'full' ELSE 'partial' END, _o.gap, _o.method,
            'تسجيل مرتجع ناقص لسطور اتشالت (قرار صاحب الكافيه 2026-10-16)', 'void')
    RETURNING id INTO _ref;

    _acc := public.default_cash_account(_o.company_id, _o.method);
    IF _acc IS NULL THEN RAISE EXCEPTION 'No treasury account for method %', _o.method; END IF;
    PERFORM public.post_cash_txn(_o.company_id, _acc, 'out', _o.gap, 'refund', _o.method,
      public.business_today(_o.company_id), 'order_refund', _ref,
      'مرتجع ناقص — فاتورة #' || _o.order_number, NULL, false);

    INSERT INTO public.audit_logs (company_id, branch_id, action, module, entity_type, entity_id, old_values, new_values, reason)
    VALUES (_o.company_id, _o.branch_id, 'order.record_missing_refund', 'pos', 'orders', _o.id, NULL,
      jsonb_build_object('refund_id', _ref, 'amount', _o.gap, 'method', _o.method),
      'الفلوس رجعت للعميل لما السطور اتشالت؛ المرتجع ماكانش متسجل');
    _total := _total + _o.gap; _n := _n + 1;
  END LOOP;
  IF _n <> 12 OR _total <> 945 THEN RAISE EXCEPTION 'Expected 12 invoices / 945, got % / %', _n, _total; END IF;
  RAISE NOTICE 'Recorded % refunds, % EGP', _n, _total;
END $$;
