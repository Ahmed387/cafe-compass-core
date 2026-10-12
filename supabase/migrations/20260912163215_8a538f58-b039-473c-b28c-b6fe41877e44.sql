
-- ============ PHASE 4 STEP 3: TIGHTEN DIRECT WRITE PATHS ============
-- All create/update flows now run through SECURITY DEFINER RPCs, which execute
-- as the function owner and are therefore unaffected by these policy removals.
-- SELECT policies are intentionally left untouched (zero read regression).

DROP POLICY IF EXISTS expenses_insert ON public.expenses;
DROP POLICY IF EXISTS expenses_update ON public.expenses;

DROP POLICY IF EXISTS employee_salaries_insert ON public.employee_salaries;
DROP POLICY IF EXISTS employee_salaries_update ON public.employee_salaries;

DROP POLICY IF EXISTS salary_payments_insert ON public.salary_payments;
DROP POLICY IF EXISTS salary_payments_update ON public.salary_payments;

DROP POLICY IF EXISTS partners_insert ON public.partners;
DROP POLICY IF EXISTS partners_update ON public.partners;

DROP POLICY IF EXISTS pcc_insert ON public.partner_capital_contributions;
DROP POLICY IF EXISTS pcc_update ON public.partner_capital_contributions;

DROP POLICY IF EXISTS ap_insert ON public.accounting_periods;
DROP POLICY IF EXISTS ap_update ON public.accounting_periods;

DROP POLICY IF EXISTS suppliers_insert ON public.suppliers;
DROP POLICY IF EXISTS suppliers_update ON public.suppliers;

-- Belt-and-braces: the Data API roles never need direct write privileges here.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.expenses FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.employee_salaries FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.salary_payments FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.partners FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.partner_capital_contributions FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.accounting_periods FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.suppliers FROM anon, authenticated;

-- Reads stay exactly as before (RLS SELECT policies remain the gate).
GRANT SELECT ON public.expenses TO authenticated;
GRANT SELECT ON public.employee_salaries TO authenticated;
GRANT SELECT ON public.salary_payments TO authenticated;
GRANT SELECT ON public.partners TO authenticated;
GRANT SELECT ON public.partner_capital_contributions TO authenticated;
GRANT SELECT ON public.accounting_periods TO authenticated;
GRANT SELECT ON public.suppliers TO authenticated;

GRANT ALL ON public.expenses TO service_role;
GRANT ALL ON public.employee_salaries TO service_role;
GRANT ALL ON public.salary_payments TO service_role;
GRANT ALL ON public.partners TO service_role;
GRANT ALL ON public.partner_capital_contributions TO service_role;
GRANT ALL ON public.accounting_periods TO service_role;
GRANT ALL ON public.suppliers TO service_role;
