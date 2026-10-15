-- =====================================================================
-- Customers: editing names / phones actually works, and customers can be
-- removed (client request).
--
-- Bug: update_customer_details() called has_permission(auth.uid(), ...),
-- an overload that does not exist, so every edit failed. Phones typed with
-- spaces or dashes ("010 1234 5678") were also rejected.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.normalize_phone(_phone text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO 'public' AS $$
  SELECT NULLIF(regexp_replace(btrim(COALESCE(_phone, '')), '[\s\-\(\)\.]', '', 'g'), '')
$$;

CREATE OR REPLACE FUNCTION public.update_customer_details(_customer_id uuid, _name text, _phone text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_old public.customers; v_phone text := public.normalize_phone(_phone);
BEGIN
  IF NOT (public.has_permission('loyalty.manage') OR public.has_permission('pos.view') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  SELECT * INTO v_old FROM public.customers WHERE id = _customer_id FOR UPDATE;
  IF v_old.id IS NULL OR v_old.company_id <> public.current_company_id() THEN RAISE EXCEPTION 'Customer not found'; END IF;
  IF length(btrim(COALESCE(_name, ''))) < 2 OR length(btrim(_name)) > 100 THEN RAISE EXCEPTION 'الاسم لازم يكون من حرفين لـ 100 حرف'; END IF;
  IF v_phone IS NULL OR v_phone !~ '^\+?[0-9]{6,20}$' THEN RAISE EXCEPTION 'رقم الموبايل لازم يكون أرقام بس (من 6 لـ 20 رقم)'; END IF;
  IF EXISTS (SELECT 1 FROM public.customers WHERE company_id = v_old.company_id AND phone = v_phone AND id <> _customer_id) THEN
    RAISE EXCEPTION 'الرقم ده مسجل لعميل تاني';
  END IF;
  UPDATE public.customers SET name = btrim(_name), phone = v_phone, updated_at = now() WHERE id = _customer_id;
  -- Keep open invoices showing the corrected name/phone.
  UPDATE public.orders SET customer_name = btrim(_name), customer_phone = v_phone
   WHERE customer_id = _customer_id AND status IN ('open', 'pending');
  PERFORM public.log_audit('customer.update', 'loyalty', 'customers', _customer_id,
    jsonb_build_object('name', v_old.name, 'phone', v_old.phone),
    jsonb_build_object('name', btrim(_name), 'phone', v_phone), NULL, NULL);
END $$;
REVOKE ALL ON FUNCTION public.update_customer_details(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_customer_details(uuid, text, text) TO authenticated;

-- Remove a customer. No history → deleted. With orders / points / wallet
-- history → archived (hidden everywhere, history kept). A positive wallet
-- balance must be settled first so no customer money disappears.
CREATE OR REPLACE FUNCTION public.delete_customer(_customer_id uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_c public.customers; v_history boolean;
BEGIN
  IF NOT (public.has_permission('loyalty.manage') OR public.is_super_admin()) THEN RAISE EXCEPTION 'Not authorized'; END IF;
  SELECT * INTO v_c FROM public.customers WHERE id = _customer_id FOR UPDATE;
  IF v_c.id IS NULL OR v_c.company_id <> public.current_company_id() THEN RAISE EXCEPTION 'Customer not found'; END IF;
  IF COALESCE(v_c.wallet_balance, 0) > 0 THEN
    RAISE EXCEPTION 'العميل ليه رصيد % — صفّر الرصيد الأول قبل الحذف', v_c.wallet_balance;
  END IF;

  v_history := EXISTS (SELECT 1 FROM public.orders WHERE customer_id = _customer_id)
            OR COALESCE(v_c.points_balance, 0) <> 0 OR COALESCE(v_c.visits, 0) > 0;
  BEGIN
    IF NOT v_history THEN
      DELETE FROM public.customers WHERE id = _customer_id;
      PERFORM public.log_audit('customer.delete', 'loyalty', 'customers', _customer_id, to_jsonb(v_c), NULL, NULL, NULL);
      RETURN 'deleted';
    END IF;
  EXCEPTION WHEN foreign_key_violation THEN
    v_history := true;  -- referenced somewhere (points/wallet ledger): archive instead
  END;

  UPDATE public.customers SET is_active = false, updated_at = now() WHERE id = _customer_id;
  PERFORM public.log_audit('customer.archive', 'loyalty', 'customers', _customer_id, to_jsonb(v_c), NULL, NULL, NULL);
  RETURN 'archived';
END $$;
REVOKE ALL ON FUNCTION public.delete_customer(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_customer(uuid) TO authenticated;
