UPDATE public.companies
SET tax_enabled = false,
    tax_rate = 0,
    updated_at = now()
WHERE tax_enabled IS DISTINCT FROM false
   OR tax_rate IS DISTINCT FROM 0;