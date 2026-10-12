CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon;
GRANT USAGE ON SCHEMA private TO authenticated, service_role;

ALTER FUNCTION public.financial_self_sustainability() SET SCHEMA private;
ALTER FUNCTION public.distribute_period_profit(uuid, numeric) SET SCHEMA private;

REVOKE ALL ON FUNCTION private.financial_self_sustainability() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION private.distribute_period_profit(uuid, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.financial_self_sustainability() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.distribute_period_profit(uuid, numeric) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.financial_self_sustainability()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO 'public', 'private'
AS $$
  SELECT private.financial_self_sustainability()
$$;

REVOKE ALL ON FUNCTION public.financial_self_sustainability() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.financial_self_sustainability() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.distribute_period_profit(_period_id uuid, _development_fund_amount numeric)
RETURNS uuid
LANGUAGE sql
SECURITY INVOKER
SET search_path TO 'public', 'private'
AS $$
  SELECT private.distribute_period_profit(_period_id, _development_fund_amount)
$$;

CREATE OR REPLACE FUNCTION public.distribute_period_profit(_period_id uuid)
RETURNS uuid
LANGUAGE sql
SECURITY INVOKER
SET search_path TO 'public', 'private'
AS $$
  SELECT private.distribute_period_profit(_period_id, 0::numeric)
$$;

REVOKE ALL ON FUNCTION public.distribute_period_profit(uuid, numeric) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.distribute_period_profit(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.distribute_period_profit(uuid, numeric) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.distribute_period_profit(uuid) TO authenticated, service_role;