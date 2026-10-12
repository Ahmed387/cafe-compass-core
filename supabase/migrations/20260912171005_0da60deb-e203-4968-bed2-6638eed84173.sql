ALTER TABLE public.backup_history
  ADD COLUMN IF NOT EXISTS drive_link text,
  ADD COLUMN IF NOT EXISTS drive_folder_id text;

CREATE OR REPLACE FUNCTION public.company_financial_snapshot(_company_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  target uuid;
  result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
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
    'branches', COALESCE((SELECT jsonb_agg(to_jsonb(b)) FROM branches b WHERE b.company_id = target), '[]'::jsonb),
    'orders', COALESCE((SELECT jsonb_agg(to_jsonb(o)) FROM orders o WHERE o.company_id = target), '[]'::jsonb),
    'order_items', COALESCE((SELECT jsonb_agg(to_jsonb(oi)) FROM order_items oi JOIN orders o ON o.id = oi.order_id WHERE o.company_id = target), '[]'::jsonb),
    'order_payments', COALESCE((SELECT jsonb_agg(to_jsonb(op)) FROM order_payments op JOIN orders o ON o.id = op.order_id WHERE o.company_id = target), '[]'::jsonb),
    'order_refunds', COALESCE((SELECT jsonb_agg(to_jsonb(r)) FROM order_refunds r WHERE r.company_id = target), '[]'::jsonb),
    'cash_transactions', COALESCE((SELECT jsonb_agg(to_jsonb(ct)) FROM cash_transactions ct WHERE ct.company_id = target), '[]'::jsonb),
    'cash_accounts', COALESCE((SELECT jsonb_agg(to_jsonb(ca)) FROM cash_accounts ca WHERE ca.company_id = target), '[]'::jsonb),
    'stock_movements', COALESCE((SELECT jsonb_agg(to_jsonb(sm)) FROM stock_movements sm WHERE sm.company_id = target), '[]'::jsonb),
    'audit_logs', COALESCE((SELECT jsonb_agg(to_jsonb(al)) FROM audit_logs al WHERE al.company_id = target), '[]'::jsonb),
    'expenses', COALESCE((SELECT jsonb_agg(to_jsonb(e)) FROM expenses e WHERE e.company_id = target), '[]'::jsonb),
    'purchases', COALESCE((SELECT jsonb_agg(to_jsonb(p)) FROM purchases p WHERE p.company_id = target), '[]'::jsonb),
    'purchase_items', COALESCE((SELECT jsonb_agg(to_jsonb(pi)) FROM purchase_items pi JOIN purchases p ON p.id = pi.purchase_id WHERE p.company_id = target), '[]'::jsonb),
    'suppliers', COALESCE((SELECT jsonb_agg(to_jsonb(s)) FROM suppliers s WHERE s.company_id = target), '[]'::jsonb),
    'salary_payments', COALESCE((SELECT jsonb_agg(to_jsonb(sp)) FROM salary_payments sp WHERE sp.company_id = target), '[]'::jsonb),
    'partners', COALESCE((SELECT jsonb_agg(to_jsonb(pa)) FROM partners pa WHERE pa.company_id = target), '[]'::jsonb),
    'partner_ledger_transactions', COALESCE((SELECT jsonb_agg(to_jsonb(pl)) FROM partner_ledger_transactions pl WHERE pl.company_id = target), '[]'::jsonb),
    'profit_distributions', COALESCE((SELECT jsonb_agg(to_jsonb(pd)) FROM profit_distributions pd WHERE pd.company_id = target), '[]'::jsonb),
    'accounting_periods', COALESCE((SELECT jsonb_agg(to_jsonb(ap)) FROM accounting_periods ap WHERE ap.company_id = target), '[]'::jsonb),
    'shifts', COALESCE((SELECT jsonb_agg(to_jsonb(s2)) FROM shifts s2 WHERE s2.company_id = target), '[]'::jsonb),
    'products', COALESCE((SELECT jsonb_agg(to_jsonb(pr)) FROM products pr WHERE pr.company_id = target), '[]'::jsonb),
    'categories', COALESCE((SELECT jsonb_agg(to_jsonb(cg)) FROM categories cg WHERE cg.company_id = target), '[]'::jsonb),
    'inventory_items', COALESCE((SELECT jsonb_agg(to_jsonb(ii)) FROM inventory_items ii WHERE ii.company_id = target), '[]'::jsonb),
    'customers', COALESCE((SELECT jsonb_agg(to_jsonb(cu)) FROM customers cu WHERE cu.company_id = target), '[]'::jsonb),
    'app_settings', COALESCE((SELECT jsonb_agg(to_jsonb(st)) FROM app_settings st WHERE st.company_id = target), '[]'::jsonb),
    'user_profiles', COALESCE((SELECT jsonb_agg(to_jsonb(up)) FROM user_profiles up WHERE up.company_id = target), '[]'::jsonb)
  ) INTO result;

  RETURN result;
END;
$function$;

REVOKE ALL ON FUNCTION public.company_financial_snapshot(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.company_financial_snapshot(uuid) TO authenticated, service_role;