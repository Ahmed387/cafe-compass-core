-- Phase 1: revoke privileged function execution from guests (anon / PUBLIC)
DO $$
DECLARE
  r record;
  keep_anon text[] := ARRAY['public_menu', 'customer_card'];
  auth_ok boolean;
BEGIN
  FOR r IN
    SELECT p.oid, p.oid::regprocedure::text AS sig, p.proname
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.prokind = 'f'
  LOOP
    -- preserve current effective access for signed-in users
    auth_ok := has_function_privilege('authenticated', r.oid, 'EXECUTE');

    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', r.sig);
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM anon', r.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', r.sig);

    IF auth_ok THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', r.sig);
    END IF;

    IF r.proname = ANY(keep_anon) THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon', r.sig);
    END IF;
  END LOOP;
END $$;

-- order_counters is written only inside SECURITY DEFINER order functions.
REVOKE ALL ON TABLE public.order_counters FROM anon;
REVOKE ALL ON TABLE public.order_counters FROM authenticated;
GRANT ALL ON TABLE public.order_counters TO service_role;

ALTER TABLE public.order_counters ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "order_counters service role only" ON public.order_counters;
CREATE POLICY "order_counters service role only"
  ON public.order_counters
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);