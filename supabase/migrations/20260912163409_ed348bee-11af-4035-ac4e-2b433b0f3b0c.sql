
CREATE OR REPLACE FUNCTION public.save_supplier(
  _name text DEFAULT NULL,
  _id uuid DEFAULT NULL,
  _contact_person text DEFAULT NULL,
  _phone text DEFAULT NULL,
  _email text DEFAULT NULL,
  _address text DEFAULT NULL,
  _payment_terms text DEFAULT NULL,
  _notes text DEFAULT NULL,
  _is_active boolean DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _profile uuid := public.current_profile_id();
        _company uuid := public.current_company_id();
        _existing public.suppliers;
        _out uuid;
BEGIN
  IF _profile IS NULL OR _company IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;

  IF _id IS NULL THEN
    IF NOT (public.has_permission('suppliers.create') OR public.has_permission('purchases.create')
            OR public.is_super_admin()) THEN
      RAISE EXCEPTION 'Not authorized';
    END IF;
    IF _name IS NULL OR btrim(_name) = '' THEN RAISE EXCEPTION 'Supplier name is required'; END IF;

    INSERT INTO public.suppliers (company_id, name, contact_person, phone, email, address,
      payment_terms, notes, is_active, created_by)
    VALUES (_company, btrim(_name), NULLIF(btrim(COALESCE(_contact_person, '')), ''),
      NULLIF(btrim(COALESCE(_phone, '')), ''), NULLIF(btrim(COALESCE(_email, '')), ''),
      NULLIF(btrim(COALESCE(_address, '')), ''), NULLIF(btrim(COALESCE(_payment_terms, '')), ''),
      NULLIF(_notes, ''), COALESCE(_is_active, true), _profile)
    RETURNING id INTO _out;

    PERFORM public.log_audit('supplier.create', 'purchases', 'suppliers', _out, NULL,
      jsonb_build_object('name', btrim(_name)), NULL, NULL);
    RETURN _out;
  END IF;

  IF NOT (public.has_permission('suppliers.update') OR public.has_permission('purchases.create')
          OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT * INTO _existing FROM public.suppliers WHERE id = _id AND company_id = _company;
  IF _existing.id IS NULL THEN RAISE EXCEPTION 'Supplier not found'; END IF;

  -- NULL argument = leave the column untouched. Empty string = clear the column.
  UPDATE public.suppliers SET
    name           = CASE WHEN _name IS NULL OR btrim(_name) = '' THEN name ELSE btrim(_name) END,
    contact_person = CASE WHEN _contact_person IS NULL THEN contact_person
                          ELSE NULLIF(btrim(_contact_person), '') END,
    phone          = CASE WHEN _phone IS NULL THEN phone ELSE NULLIF(btrim(_phone), '') END,
    email          = CASE WHEN _email IS NULL THEN email ELSE NULLIF(btrim(_email), '') END,
    address        = CASE WHEN _address IS NULL THEN address ELSE NULLIF(btrim(_address), '') END,
    payment_terms  = CASE WHEN _payment_terms IS NULL THEN payment_terms
                          ELSE NULLIF(btrim(_payment_terms), '') END,
    notes          = CASE WHEN _notes IS NULL THEN notes ELSE NULLIF(btrim(_notes), '') END,
    is_active      = COALESCE(_is_active, is_active),
    updated_at     = now()
  WHERE id = _id;

  PERFORM public.log_audit('supplier.update', 'purchases', 'suppliers', _id,
    jsonb_build_object('name', _existing.name, 'is_active', _existing.is_active),
    jsonb_build_object('name', COALESCE(NULLIF(btrim(COALESCE(_name, '')), ''), _existing.name),
      'is_active', COALESCE(_is_active, _existing.is_active)), NULL, NULL);
  RETURN _id;
END $$;

REVOKE ALL ON FUNCTION public.save_supplier(text, uuid, text, text, text, text, text, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_supplier(text, uuid, text, text, text, text, text, text, boolean) TO authenticated, service_role;
