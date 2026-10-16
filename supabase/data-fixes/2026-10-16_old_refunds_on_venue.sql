-- =====================================================================
-- One-off data fix for the 20s cafe database (owner decision 2026-10-16):
-- refunds in shifts that closed without anyone choosing who bears them are
-- on the cafe ("venue"). 43 refunds, 3,092 EGP. No amount changes and no
-- salary is touched; only the bearer is filled in. Audited.
-- =====================================================================
WITH upd AS (
  UPDATE public.order_refunds r SET fault = 'venue'
    FROM public.shifts s
   WHERE s.id = r.shift_id AND s.status = 'closed' AND r.status = 'active' AND r.fault IS NULL
  RETURNING r.id, r.company_id, r.branch_id, r.amount)
INSERT INTO public.audit_logs (company_id, branch_id, action, module, entity_type, entity_id, old_values, new_values, reason)
SELECT company_id, branch_id, 'refund.bearer_set', 'pos', 'order_refunds', id,
       jsonb_build_object('fault', NULL), jsonb_build_object('fault', 'venue', 'amount', amount),
       'مرتجع في وردية اتقفلت من غير قرار: على الكافيه (قرار صاحب الكافيه 2026-10-16)'
  FROM upd;
