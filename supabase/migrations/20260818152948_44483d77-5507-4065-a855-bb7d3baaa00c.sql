DO $$
DECLARE t text; tables text[] := ARRAY['customer_points_transactions','customer_vouchers','order_item_modifiers','order_items','order_payments','order_refunds','orders','customers','purchase_items','purchases','stock_movements','branch_stock','expenses','employee_advances','attendance','salary_payments','profit_distribution_lines','profit_distributions','partner_ledger_transactions','partner_capital_contributions','shifts','accounting_periods','notifications','audit_logs','order_counters'];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    EXECUTE format('ALTER TABLE public.%I DISABLE TRIGGER USER', t);
  END LOOP;
  FOREACH t IN ARRAY tables LOOP
    EXECUTE format('DELETE FROM public.%I', t);
  END LOOP;
  FOREACH t IN ARRAY tables LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE TRIGGER USER', t);
  END LOOP;
END $$;