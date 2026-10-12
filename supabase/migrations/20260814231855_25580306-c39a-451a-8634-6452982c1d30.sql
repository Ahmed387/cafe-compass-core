REVOKE EXECUTE ON FUNCTION public.clock_in(uuid) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.clock_out() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.upsert_attendance(uuid, date, timestamptz, timestamptz, uuid, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.create_advance(uuid, numeric, date, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.cancel_advance(uuid, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.run_payroll(date, date) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.set_order_item_station() FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.clock_in(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.clock_out() TO authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_attendance(uuid, date, timestamptz, timestamptz, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_advance(uuid, numeric, date, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_advance(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.run_payroll(date, date) TO authenticated;