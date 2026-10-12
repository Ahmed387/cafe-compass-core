CREATE TABLE IF NOT EXISTS public.backup_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  status text NOT NULL CHECK (status IN ('success', 'failed')),
  file_name text,
  file_size_bytes bigint,
  drive_file_id text,
  error_message text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_backup_history_company_created
  ON public.backup_history (company_id, created_at DESC);

GRANT SELECT ON public.backup_history TO authenticated;
GRANT ALL ON public.backup_history TO service_role;

ALTER TABLE public.backup_history ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS backup_history_select ON public.backup_history;
CREATE POLICY backup_history_select ON public.backup_history
  FOR SELECT TO authenticated
  USING (company_id = public.current_company_id() AND public.is_super_admin());

CREATE OR REPLACE FUNCTION public.company_financial_snapshot(_company_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  target uuid;
  result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    -- Called by the automated backup system (service_role): company must be explicit.
    IF _company_id IS NULL THEN
      RAISE EXCEPTION 'company_id is required';
    END IF;
    target := _company_id;
  ELSE
    IF NOT public.is_super_admin() THEN
      RAISE EXCEPTION 'Only super admins can generate snapshots';
    END IF;
    target := public.current_company_id();
    IF _company_id IS NOT NULL AND _company_id <> target THEN
      RAISE EXCEPTION 'Not authorized for this company';
    END IF;
  END IF;

  SELECT jsonb_build_object(
    'generated_at', now(),
    'company_id', target,
    'company', (SELECT to_jsonb(c) FROM companies c WHERE c.id = target),
    'orders', COALESCE((SELECT jsonb_agg(to_jsonb(o)) FROM orders o WHERE o.company_id = target), '[]'::jsonb),
    'order_items', COALESCE((SELECT jsonb_agg(to_jsonb(oi)) FROM order_items oi JOIN orders o ON o.id = oi.order_id WHERE o.company_id = target), '[]'::jsonb),
    'order_payments', COALESCE((SELECT jsonb_agg(to_jsonb(op)) FROM order_payments op JOIN orders o ON o.id = op.order_id WHERE o.company_id = target), '[]'::jsonb),
    'order_refunds', COALESCE((SELECT jsonb_agg(to_jsonb(r)) FROM order_refunds r WHERE r.company_id = target), '[]'::jsonb),
    'cash_transactions', COALESCE((SELECT jsonb_agg(to_jsonb(ct)) FROM cash_transactions ct WHERE ct.company_id = target), '[]'::jsonb),
    'cash_accounts', COALESCE((SELECT jsonb_agg(to_jsonb(ca)) FROM cash_accounts ca WHERE ca.company_id = target), '[]'::jsonb),
    'expenses', COALESCE((SELECT jsonb_agg(to_jsonb(e)) FROM expenses e WHERE e.company_id = target), '[]'::jsonb),
    'stock_movements', COALESCE((SELECT jsonb_agg(to_jsonb(sm)) FROM stock_movements sm WHERE sm.company_id = target), '[]'::jsonb),
    'purchases', COALESCE((SELECT jsonb_agg(to_jsonb(p)) FROM purchases p WHERE p.company_id = target), '[]'::jsonb),
    'purchase_items', COALESCE((SELECT jsonb_agg(to_jsonb(pi)) FROM purchase_items pi JOIN purchases p ON p.id = pi.purchase_id WHERE p.company_id = target), '[]'::jsonb),
    'salary_payments', COALESCE((SELECT jsonb_agg(to_jsonb(sp)) FROM salary_payments sp WHERE sp.company_id = target), '[]'::jsonb),
    'partner_ledger_transactions', COALESCE((SELECT jsonb_agg(to_jsonb(pl)) FROM partner_ledger_transactions pl WHERE pl.company_id = target), '[]'::jsonb),
    'profit_distributions', COALESCE((SELECT jsonb_agg(to_jsonb(pd)) FROM profit_distributions pd WHERE pd.company_id = target), '[]'::jsonb),
    'accounting_periods', COALESCE((SELECT jsonb_agg(to_jsonb(ap)) FROM accounting_periods ap WHERE ap.company_id = target), '[]'::jsonb),
    'shifts', COALESCE((SELECT jsonb_agg(to_jsonb(s)) FROM shifts s WHERE s.company_id = target), '[]'::jsonb)
  ) INTO result;

  RETURN result;
END;
$$;

REVOKE ALL ON FUNCTION public.company_financial_snapshot(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.company_financial_snapshot(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.company_financial_snapshot(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.company_financial_snapshot(uuid) TO service_role;