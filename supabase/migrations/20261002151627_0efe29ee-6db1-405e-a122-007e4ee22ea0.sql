CREATE OR REPLACE FUNCTION public.begin_stock_override(_branch_id uuid, _items jsonb, _reason text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _id uuid; _profile uuid := public.current_profile_id();
BEGIN
  IF auth.uid() IS NULL OR _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT public.can_access_branch(_branch_id) THEN RAISE EXCEPTION 'Not allowed'; END IF;
  INSERT INTO public.stock_overrides(company_id, branch_id, profile_id, items, reason, expires_at)
  VALUES (public.current_company_id(), _branch_id, _profile, COALESCE(_items,'[]'::jsonb), _reason, now() + interval '8 hours')
  RETURNING id INTO _id;
  PERFORM public.log_audit('pos.stock_override','pos','stock_overrides',_id,NULL,
    jsonb_build_object('items',_items,'cashier',_profile,'at',now()),_reason,_branch_id);
  RETURN _id;
END $function$;