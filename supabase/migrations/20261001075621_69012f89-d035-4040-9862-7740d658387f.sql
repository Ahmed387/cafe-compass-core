ALTER TABLE public.purchases ADD COLUMN IF NOT EXISTS payment_terms text NOT NULL DEFAULT 'cash',
  ADD COLUMN IF NOT EXISTS attachment_path text;
ALTER TABLE public.purchases ADD CONSTRAINT purchases_payment_terms_check CHECK (payment_terms IN ('cash','bank','credit'));
UPDATE public.purchases SET payment_terms = CASE WHEN paid_amount < total - returned_amount THEN 'credit' WHEN payment_method IN ('bank','visa','instapay','transfer') THEN 'bank' ELSE 'cash' END;
ALTER TABLE public.purchase_payments ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'treasury',
  ADD COLUMN IF NOT EXISTS shift_id uuid REFERENCES public.shifts(id);
ALTER TABLE public.purchase_payments ADD CONSTRAINT purchase_payments_source_check CHECK (source IN ('treasury','drawer','bank'));
CREATE INDEX IF NOT EXISTS purchase_payments_shift_idx ON public.purchase_payments(shift_id);

CREATE OR REPLACE FUNCTION public.shift_expense_total(_shift_id uuid)
 RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT COALESCE((SELECT SUM(amount) FROM public.expenses WHERE shift_id = _shift_id AND status = 'active'),0)
       + COALESCE((SELECT SUM(amount) FROM public.purchase_payments WHERE shift_id = _shift_id AND source = 'drawer'),0);
$$;

CREATE OR REPLACE FUNCTION public.pay_purchase(_purchase_id uuid, _amount numeric, _source text DEFAULT 'treasury', _paid_at date DEFAULT CURRENT_DATE, _notes text DEFAULT NULL)
 RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE _profile uuid := public.current_profile_id(); _p public.purchases; _due numeric; _id uuid; _shift uuid; _exp numeric;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('purchases.create') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  IF _source NOT IN ('treasury','drawer','bank') THEN RAISE EXCEPTION 'Invalid payment source'; END IF;
  IF _source <> 'drawer' THEN
    _id := public.record_purchase_payment(_purchase_id, _amount, CASE WHEN _source='bank' THEN 'bank' ELSE 'cash' END, _paid_at, _notes);
    UPDATE public.purchase_payments SET source = _source WHERE id = _id;
    RETURN _id;
  END IF;
  SELECT * INTO _p FROM public.purchases WHERE id = _purchase_id AND company_id = public.current_company_id() FOR UPDATE;
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Purchase not found'; END IF;
  IF _p.status = 'cancelled' THEN RAISE EXCEPTION 'This purchase is cancelled'; END IF;
  IF COALESCE(_amount,0) <= 0 THEN RAISE EXCEPTION 'Amount must be greater than zero'; END IF;
  _due := round(_p.total - _p.returned_amount - _p.paid_amount, 2);
  IF round(_amount,2) > _due THEN RAISE EXCEPTION 'Payment exceeds the remaining balance (%)', _due; END IF;
  SELECT id INTO _shift FROM public.shifts WHERE branch_id = _p.branch_id AND status = 'open' ORDER BY opened_at DESC LIMIT 1;
  IF _shift IS NULL THEN RAISE EXCEPTION 'No open shift in this branch to pay from the drawer'; END IF;
  INSERT INTO public.purchase_payments (company_id, purchase_id, amount, method, paid_at, notes, created_by, source, shift_id)
  VALUES (_p.company_id, _purchase_id, round(_amount,2), 'cash', CURRENT_DATE, NULLIF(_notes,''), _profile, 'drawer', _shift)
  RETURNING id INTO _id;
  UPDATE public.purchases SET paid_amount = round(paid_amount + round(_amount,2), 2) WHERE id = _purchase_id;
  PERFORM public.log_audit('purchase.payment_drawer','purchases','purchases',_purchase_id,NULL,
    jsonb_build_object('amount',round(_amount,2),'shift_id',_shift),_notes,_p.branch_id);
  RETURN _id;
END $$;

CREATE OR REPLACE FUNCTION public.set_purchase_meta(_purchase_id uuid, _terms text DEFAULT NULL, _attachment_path text DEFAULT NULL)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE _p public.purchases;
BEGIN
  IF NOT (public.has_permission('purchases.create') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  SELECT * INTO _p FROM public.purchases WHERE id = _purchase_id AND company_id = public.current_company_id();
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Purchase not found'; END IF;
  IF _terms IS NOT NULL AND _terms NOT IN ('cash','bank','credit') THEN RAISE EXCEPTION 'Invalid payment terms'; END IF;
  IF _attachment_path IS NOT NULL AND split_part(_attachment_path,'/',1) <> _p.company_id::text THEN RAISE EXCEPTION 'Invalid attachment path'; END IF;
  UPDATE public.purchases SET payment_terms = COALESCE(_terms, payment_terms),
    attachment_path = COALESCE(_attachment_path, attachment_path) WHERE id = _purchase_id;
  PERFORM public.log_audit('purchase.meta','purchases','purchases',_purchase_id,NULL,
    jsonb_build_object('terms',_terms,'attachment',_attachment_path),NULL,_p.branch_id);
END $$;

CREATE OR REPLACE FUNCTION public.supplier_payables()
 RETURNS TABLE(supplier_id uuid, supplier_name text, open_count int, total numeric, paid numeric, due numeric)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT s.id, s.name, COUNT(p.id)::int, COALESCE(SUM(p.total - p.returned_amount),0), COALESCE(SUM(p.paid_amount),0),
         COALESCE(SUM(p.total - p.returned_amount - p.paid_amount),0)
  FROM public.purchases p JOIN public.suppliers s ON s.id = p.supplier_id
  WHERE p.company_id = public.current_company_id() AND p.status <> 'cancelled'
    AND public.can_access_branch(p.branch_id)
    AND (public.has_permission('purchases.view') OR public.is_super_admin())
    AND round(p.total - p.returned_amount - p.paid_amount,2) > 0
  GROUP BY s.id, s.name ORDER BY 6 DESC;
$$;

REVOKE EXECUTE ON FUNCTION public.pay_purchase(uuid,numeric,text,date,text), public.set_purchase_meta(uuid,text,text), public.supplier_payables() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pay_purchase(uuid,numeric,text,date,text), public.set_purchase_meta(uuid,text,text), public.supplier_payables() TO authenticated;

CREATE POLICY "purchase_attach_read" ON storage.objects FOR SELECT TO authenticated
USING (bucket_id = 'purchase-attachments' AND (storage.foldername(name))[1] = public.current_company_id()::text
  AND (public.has_permission('purchases.view') OR public.is_super_admin()));
CREATE POLICY "purchase_attach_insert" ON storage.objects FOR INSERT TO authenticated
WITH CHECK (bucket_id = 'purchase-attachments' AND (storage.foldername(name))[1] = public.current_company_id()::text
  AND (public.has_permission('purchases.create') OR public.is_super_admin()));