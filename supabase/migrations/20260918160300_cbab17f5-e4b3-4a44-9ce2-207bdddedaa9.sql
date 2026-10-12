REVOKE ALL ON FUNCTION public.delete_modifier_option(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.delete_modifier_option(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_modifier_option(uuid) TO authenticated, service_role;