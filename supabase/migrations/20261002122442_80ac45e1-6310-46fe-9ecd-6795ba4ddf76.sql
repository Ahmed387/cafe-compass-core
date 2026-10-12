ALTER TABLE public.partners
  ADD COLUMN IF NOT EXISTS management_salary_type text NOT NULL DEFAULT 'fixed',
  ADD COLUMN IF NOT EXISTS management_salary_pct numeric NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION public.set_partner_salary_type(_partner_id uuid, _type text, _pct numeric)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _old public.partners;
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Super Admin only'; END IF;
  IF _type NOT IN ('fixed','percent') THEN RAISE EXCEPTION 'invalid salary type'; END IF;
  IF _pct IS NULL OR _pct < 0 OR _pct > 100 THEN RAISE EXCEPTION 'percentage must be 0-100'; END IF;
  SELECT * INTO _old FROM public.partners WHERE id = _partner_id AND company_id = public.current_company_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'partner not found'; END IF;
  UPDATE public.partners SET management_salary_type = _type, management_salary_pct = CASE WHEN _type='percent' THEN _pct ELSE 0 END, updated_at = now() WHERE id = _partner_id;
  PERFORM public.log_audit('set_salary_type','partners','partner',_partner_id,
    jsonb_build_object('type',_old.management_salary_type,'pct',_old.management_salary_pct),
    jsonb_build_object('type',_type,'pct',_pct), NULL, NULL);
END $$;
REVOKE ALL ON FUNCTION public.set_partner_salary_type(uuid,text,numeric) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.set_partner_salary_type(uuid,text,numeric) TO authenticated;