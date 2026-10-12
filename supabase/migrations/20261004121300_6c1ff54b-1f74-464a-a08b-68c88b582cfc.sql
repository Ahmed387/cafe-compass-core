CREATE OR REPLACE FUNCTION public.update_customer_with_points(
  _customer_id uuid,
  _name text,
  _phone text,
  _points integer DEFAULT 0,
  _reason text DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_company uuid := public.current_company_id();
  v_profile uuid := public.current_profile_id();
  v_balance integer;
  v_old jsonb;
BEGIN
  IF NOT (public.has_permission('loyalty.manage') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  IF length(btrim(coalesce(_name, ''))) < 2 OR length(btrim(_name)) > 100 THEN
    RAISE EXCEPTION 'Invalid name';
  END IF;
  IF btrim(coalesce(_phone, '')) !~ '^\+?[0-9]{6,20}$' THEN
    RAISE EXCEPTION 'Invalid phone';
  END IF;
  IF coalesce(_points, 0) <> 0 AND length(btrim(coalesce(_reason, ''))) < 3 THEN
    RAISE EXCEPTION 'Reason is required';
  END IF;

  SELECT jsonb_build_object('name', name, 'phone', phone, 'points_balance', points_balance), points_balance
  INTO v_old, v_balance
  FROM public.customers
  WHERE id = _customer_id AND company_id = v_company
  FOR UPDATE;

  IF v_balance IS NULL THEN RAISE EXCEPTION 'Customer not found'; END IF;
  IF EXISTS (
    SELECT 1 FROM public.customers
    WHERE company_id = v_company AND phone = btrim(_phone) AND id <> _customer_id
  ) THEN
    RAISE EXCEPTION 'Phone already used by another customer';
  END IF;
  IF v_balance + coalesce(_points, 0) < 0 THEN
    RAISE EXCEPTION 'Points balance cannot go negative';
  END IF;

  UPDATE public.customers
  SET name = btrim(_name),
      phone = btrim(_phone),
      points_balance = points_balance + coalesce(_points, 0),
      updated_at = now()
  WHERE id = _customer_id
  RETURNING points_balance INTO v_balance;

  IF coalesce(_points, 0) <> 0 THEN
    INSERT INTO public.customer_points_transactions
      (company_id, customer_id, kind, points, balance_after, description, created_by)
    VALUES
      (v_company, _customer_id, 'adjust', _points, v_balance, btrim(_reason), v_profile);
  END IF;

  PERFORM public.log_audit(
    'customer.update_with_points', 'loyalty', 'customers', _customer_id, v_old,
    jsonb_build_object(
      'name', btrim(_name), 'phone', btrim(_phone),
      'points_delta', coalesce(_points, 0), 'points_balance', v_balance,
      'reason', nullif(btrim(coalesce(_reason, '')), '')
    ), NULL, NULL
  );

  RETURN v_balance;
END
$function$;

REVOKE ALL ON FUNCTION public.update_customer_with_points(uuid, text, text, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_customer_with_points(uuid, text, text, integer, text) TO authenticated;