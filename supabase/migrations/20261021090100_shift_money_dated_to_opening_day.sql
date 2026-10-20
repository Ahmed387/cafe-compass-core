-- =====================================================================
-- Owner rule (2026-10-20): everything a shift sends to the treasury is dated
-- to the day the shift OPENED, even when it closes after midnight. Before
-- this, a shift opened on the 20th at 17:00 and closed on the 21st at 02:00
-- put its cash drop and its card / InstaPay / wallet takings on the 21st, so
-- the 20th showed sales with no deposit and the 21st a deposit with no sales.
-- Checked on 2026-10-21: 29 closed shifts crossed midnight, every one of them
-- dated its treasury lines to the closing day.
--   1) _finalize_shift_close posts with business_date(opened_at)
--   2) data fix: those shifts' deposit / electronic lines move to the opening
--      day (txn_date only, amounts untouched), each change audited
-- =====================================================================
DO $$
DECLARE _def text := pg_get_functiondef('public._finalize_shift_close(uuid, numeric, numeric, text, uuid, text, text, uuid)'::regprocedure);
  _old text := 'public.business_date(_closed_at, _s.company_id)';
BEGIN
  IF position(_old IN _def) = 0 THEN
    IF position('public.business_date(_s.opened_at, _s.company_id)' IN _def) > 0 THEN RETURN; END IF;
    RAISE EXCEPTION '_finalize_shift_close: expected business_date(_closed_at) not found';
  END IF;
  EXECUTE replace(_def, _old, 'public.business_date(_s.opened_at, _s.company_id)');
END $$;

WITH moved AS (
  UPDATE public.cash_transactions t
     SET txn_date = public.business_date(s.opened_at, s.company_id)
    FROM public.shifts s
   WHERE t.reference_type = 'shift' AND t.reference_id = s.id
     AND t.category IN ('shift_deposit', 'electronic_settlement')
     AND s.closed_at IS NOT NULL
     AND t.txn_date <> public.business_date(s.opened_at, s.company_id)
  RETURNING t.id, t.company_id, t.txn_date, s.id AS shift_id)
INSERT INTO public.audit_logs (company_id, action, module, entity_type, entity_id, old_values, new_values, reason)
SELECT company_id, 'cash_txn.redated', 'finance', 'cash_transactions', id, NULL,
       jsonb_build_object('txn_date', txn_date, 'shift_id', shift_id),
       'توريد الوردية يتسجل بتاريخ يوم فتحها (قرار صاحب الكافيه 2026-10-20)'
  FROM moved;
