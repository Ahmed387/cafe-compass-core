CREATE OR REPLACE FUNCTION public.update_customer_details(_customer_id uuid, _name text, _phone text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_company uuid;
BEGIN
  SELECT company_id INTO v_company FROM customers WHERE id = _customer_id;
  IF v_company IS NULL OR v_company <> current_company_id() THEN RAISE EXCEPTION 'Customer not found'; END IF;
  IF NOT has_permission(auth.uid(), 'loyalty.manage') THEN RAISE EXCEPTION 'Not allowed'; END IF;
  IF length(trim(coalesce(_name,''))) < 2 OR length(trim(_name)) > 100 THEN RAISE EXCEPTION 'Invalid name'; END IF;
  IF trim(coalesce(_phone,'')) !~ '^\+?[0-9]{6,20}$' THEN RAISE EXCEPTION 'Invalid phone'; END IF;
  IF EXISTS (SELECT 1 FROM customers WHERE company_id = v_company AND phone = trim(_phone) AND id <> _customer_id) THEN
    RAISE EXCEPTION 'Phone already used by another customer';
  END IF;
  UPDATE customers SET name = trim(_name), phone = trim(_phone), updated_at = now() WHERE id = _customer_id;
END $$;
REVOKE ALL ON FUNCTION public.update_customer_details(uuid,text,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.update_customer_details(uuid,text,text) TO authenticated;