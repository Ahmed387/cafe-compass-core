REVOKE EXECUTE ON FUNCTION public.initialize_accounting_period(date, date, period_type, boolean) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.close_accounting_period(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.initialize_accounting_period(date, date, period_type, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.close_accounting_period(uuid, date) TO authenticated;