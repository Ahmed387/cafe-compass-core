CREATE OR REPLACE FUNCTION public.refund_target_shift(_branch_id uuid, _method_key text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE _s uuid;
BEGIN
  SELECT id INTO _s FROM public.shifts
  WHERE branch_id = _branch_id AND status = 'open'
  ORDER BY opened_at DESC LIMIT 1;

  IF COALESCE(NULLIF(_method_key,''),'cash') = 'cash' AND _s IS NULL THEN
    RAISE EXCEPTION 'لا يمكن صرف مرتجع نقدي لعدم وجود وردية مفتوحة حالياً — يرجى فتح وردية أولاً لصرف المبلغ من درجها.';
  END IF;

  RETURN _s;
END
$fn$;

REVOKE ALL ON FUNCTION public.refund_target_shift(uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.refund_target_shift(uuid, text) TO authenticated, service_role;

DO $mig$
DECLARE d text; n int;
BEGIN
  FOREACH d IN ARRAY ARRAY[
    pg_get_functiondef('public.refund_order(uuid,numeric,text,text)'::regprocedure),
    pg_get_functiondef('public.refund_order_items(uuid,jsonb,text,text)'::regprocedure)
  ] LOOP
    n := (length(d) - length(replace(d, '_o.id, _o.shift_id,', ''))) / length('_o.id, _o.shift_id,');
    IF n <> 1 THEN RAISE EXCEPTION 'unexpected shift attribution occurrences: %', n; END IF;
    d := replace(d, '_o.id, _o.shift_id,', '_o.id, public.refund_target_shift(_o.branch_id, _method_key),');
    EXECUTE d;
  END LOOP;
END
$mig$;