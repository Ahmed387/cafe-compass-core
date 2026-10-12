DO $$
DECLARE t text; tabs text[] := ARRAY['order_item_modifiers','order_refunds','order_payments','order_items','orders','order_counters','customer_points_transactions','customer_vouchers','customers','stock_movements','purchase_return_items','purchase_returns','purchase_payments','purchase_items','purchases','cash_transactions','expenses','salary_payments','employee_advances','employee_salaries','attendance','shifts','partner_ledger_transactions','partner_capital_contributions','partner_withdrawal_requests','profit_distribution_lines','profit_distributions','partners','audit_logs','notifications'];
BEGIN
  FOREACH t IN ARRAY tabs LOOP
    EXECUTE format('ALTER TABLE public.%I DISABLE TRIGGER USER', t);
  END LOOP;

  DELETE FROM public.customer_points_transactions;
  DELETE FROM public.customer_vouchers;
  DELETE FROM public.order_item_modifiers;
  DELETE FROM public.order_refunds;
  DELETE FROM public.order_payments;
  DELETE FROM public.order_items;
  DELETE FROM public.orders;
  DELETE FROM public.order_counters;
  DELETE FROM public.customers;
  DELETE FROM public.stock_movements;
  DELETE FROM public.purchase_return_items;
  DELETE FROM public.purchase_returns;
  DELETE FROM public.purchase_payments;
  DELETE FROM public.purchase_items;
  DELETE FROM public.purchases;
  DELETE FROM public.cash_transactions;
  DELETE FROM public.expenses;
  DELETE FROM public.salary_payments;
  DELETE FROM public.employee_advances;
  DELETE FROM public.employee_salaries;
  DELETE FROM public.attendance;
  DELETE FROM public.shifts;
  DELETE FROM public.partner_ledger_transactions;
  DELETE FROM public.partner_capital_contributions;
  DELETE FROM public.partner_withdrawal_requests;
  DELETE FROM public.profit_distribution_lines;
  DELETE FROM public.profit_distributions;
  DELETE FROM public.partners;
  DELETE FROM public.audit_logs;
  DELETE FROM public.notifications;
  UPDATE public.branch_stock SET quantity = 0;

  FOREACH t IN ARRAY tabs LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE TRIGGER USER', t);
  END LOOP;
END $$;