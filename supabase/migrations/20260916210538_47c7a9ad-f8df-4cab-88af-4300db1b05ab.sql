-- 1. Stop capital contributions from posting liquid cash movements
DROP TRIGGER IF EXISTS trg_capital_contribution_cash ON public.partner_capital_contributions;
DROP FUNCTION IF EXISTS public.capital_contribution_cash();

-- 2. Remove the historical capital cash entries (balances are computed on the fly)
DO $$
BEGIN
  SET LOCAL session_replication_role = 'replica';

  DELETE FROM public.cash_transactions
  WHERE category = 'capital_contribution'
     OR reference_type = 'capital_contribution';

  SET LOCAL session_replication_role = 'origin';
END $$;
