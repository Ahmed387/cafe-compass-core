REVOKE ALL ON FUNCTION public.refund_target_shift(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refund_target_shift(uuid, text) TO authenticated, service_role;