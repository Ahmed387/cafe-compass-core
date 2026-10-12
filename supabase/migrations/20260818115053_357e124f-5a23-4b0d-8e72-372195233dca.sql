CREATE OR REPLACE FUNCTION public.upsert_customer(_name text, _phone text, _customer_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _company uuid := public.current_company_id();
  _profile uuid := public.current_profile_id();
  _id uuid;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('loyalty.manage') OR public.has_permission('pos.create_order')
          OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF COALESCE(btrim(_name),'') = '' THEN RAISE EXCEPTION 'Customer name is required'; END IF;
  IF COALESCE(btrim(_phone),'') = '' THEN RAISE EXCEPTION 'Customer phone is required'; END IF;

  IF _customer_id IS NOT NULL THEN
    UPDATE public.customers SET name = btrim(_name), phone = btrim(_phone)
    WHERE id = _customer_id AND company_id = _company
    RETURNING id INTO _id;
    IF _id IS NULL THEN RAISE EXCEPTION 'Customer not found'; END IF;
    PERFORM public.log_audit('customer.update','loyalty','customers',_id,NULL,
      jsonb_build_object('name',btrim(_name),'phone',btrim(_phone)),NULL,NULL);
    RETURN _id;
  END IF;

  SELECT id INTO _id FROM public.customers WHERE company_id = _company AND phone = btrim(_phone);
  IF _id IS NOT NULL THEN RETURN _id; END IF;

  INSERT INTO public.customers (company_id, code, name, phone, barcode, created_by)
  VALUES (_company, 'C-' || lpad(nextval('public.customer_code_seq')::text, 5, '0'),
    btrim(_name), btrim(_phone),
    upper(substring(replace(gen_random_uuid()::text,'-','') from 1 for 12)), _profile)
  RETURNING id INTO _id;

  PERFORM public.log_audit('customer.create','loyalty','customers',_id,NULL,
    jsonb_build_object('name',btrim(_name),'phone',btrim(_phone)),NULL,NULL);
  RETURN _id;
END $function$;

CREATE OR REPLACE FUNCTION public.issue_customer_voucher(_customer_id uuid, _amount numeric, _points_cost integer DEFAULT 0, _expires_at date DEFAULT NULL::date, _notes text DEFAULT NULL::text)
 RETURNS TABLE(out_id uuid, out_code text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _company uuid := public.current_company_id();
  _profile uuid := public.current_profile_id();
  _balance integer;
  _code text;
  _id uuid;
BEGIN
  IF NOT (public.has_permission('loyalty.manage') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF COALESCE(_amount,0) <= 0 THEN RAISE EXCEPTION 'Voucher amount must be greater than zero'; END IF;
  IF COALESCE(_points_cost,0) < 0 THEN RAISE EXCEPTION 'Points cost cannot be negative'; END IF;

  SELECT points_balance INTO _balance FROM public.customers
  WHERE id = _customer_id AND company_id = _company FOR UPDATE;
  IF _balance IS NULL THEN RAISE EXCEPTION 'Customer not found'; END IF;
  IF COALESCE(_points_cost,0) > _balance THEN
    RAISE EXCEPTION 'Customer does not have enough points (% available)', _balance;
  END IF;

  _code := 'V-' || upper(substring(replace(gen_random_uuid()::text,'-','') from 1 for 8));
  INSERT INTO public.customer_vouchers
    (company_id, customer_id, code, amount, points_cost, expires_at, notes, created_by)
  VALUES (_company, _customer_id, _code, round(_amount,2), COALESCE(_points_cost,0), _expires_at,
    NULLIF(btrim(COALESCE(_notes,'')),''), _profile)
  RETURNING id INTO _id;

  IF COALESCE(_points_cost,0) > 0 THEN
    UPDATE public.customers SET points_balance = points_balance - _points_cost
    WHERE id = _customer_id RETURNING points_balance INTO _balance;
    INSERT INTO public.customer_points_transactions
      (company_id, customer_id, voucher_id, kind, points, balance_after, description, created_by)
    VALUES (_company, _customer_id, _id, 'voucher', -_points_cost, _balance, _code, _profile);
  END IF;

  PERFORM public.log_audit('voucher.issue','loyalty','customer_vouchers',_id,NULL,
    jsonb_build_object('code',_code,'amount',_amount,'points_cost',_points_cost),NULL,NULL);
  RETURN QUERY SELECT _id, _code;
END $function$;