-- One-off data fix (owner decision 2026-10-15): October salaries were issued twice on
-- 6 Oct (periods 30 Sep–30 Oct and 1–31 Oct), none paid. Both sets are cancelled
-- (kept for the record), advances they had recovered are reopened, and each employee
-- is paid once with the Pay button, which deducts advances at payment time.
DO $$
DECLARE _ids uuid[];
BEGIN
  SELECT array_agg(id) INTO _ids FROM public.salary_payments
   WHERE status = 'active' AND salary_kind = 'regular' AND paid_at IS NULL
     AND period_start IN ('2026-09-30', '2026-10-01');
  IF array_length(_ids, 1) <> 12 THEN RAISE EXCEPTION 'expected 12 duplicate salary rows, found %', array_length(_ids, 1); END IF;
  INSERT INTO public.audit_logs (company_id, action, module, entity_type, entity_id, old_values, new_values, reason)
  SELECT ea.company_id, 'payroll.advance_reopen', 'payroll', 'employee_advances', ea.id,
         jsonb_build_object('deducted_amount', ea.deducted_amount, 'settled_payment_id', ea.settled_payment_id),
         jsonb_build_object('deducted_amount', 0), 'رجوع السلفة مفتوحة بعد إلغاء مرتبات أكتوبر المكررة'
    FROM public.employee_advances ea WHERE ea.settled_payment_id = ANY (_ids);
  UPDATE public.employee_advances SET deducted_amount = 0, settled_payment_id = NULL, settled_at = NULL, updated_at = now()
   WHERE settled_payment_id = ANY (_ids);
  INSERT INTO public.audit_logs (company_id, action, module, entity_type, entity_id, old_values, new_values, reason)
  SELECT sp.company_id, 'payroll.cancel_duplicate', 'payroll', 'salary_payments', sp.id,
         jsonb_build_object('period_start', sp.period_start, 'period_end', sp.period_end, 'net_amount', sp.net_amount),
         jsonb_build_object('status', 'cancelled'), 'مرتبات أكتوبر اتسجلت مرتين يوم 6 أكتوبر — اتلغت ويتصرف كل موظف مرة واحدة'
    FROM public.salary_payments sp WHERE sp.id = ANY (_ids);
  UPDATE public.salary_payments SET status = 'cancelled', updated_at = now() WHERE id = ANY (_ids);
END $$;
