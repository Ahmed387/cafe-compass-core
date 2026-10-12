ALTER TABLE public.partners ADD COLUMN IF NOT EXISTS is_managing_staff boolean NOT NULL DEFAULT false;

DO $$ DECLARE d text; BEGIN
 d := pg_get_functiondef('public.hr_payroll_preview(date,date)'::regprocedure);
 d := replace(d, 'WHERE p.company_id = v_company AND p.is_active',
   'WHERE p.company_id = v_company AND p.is_active AND NOT EXISTS (SELECT 1 FROM public.partners pt WHERE pt.company_id=v_company AND pt.user_id=p.auth_user_id AND pt.status<>''exited'' AND NOT pt.is_managing_staff)');
 EXECUTE d;
 d := pg_get_functiondef('public.update_employee_profile(uuid,text,text,numeric,date)'::regprocedure);
 d := replace(d, $x$('cashier','barista','floor_staff','manager')$x$, $x$('cashier','barista','floor_staff','manager','general_manager')$x$);
 EXECUTE d;
END $$;

CREATE OR REPLACE FUNCTION public.set_partner_managing(_partner_id uuid, _on boolean, _base_salary numeric DEFAULT 0, _hire_date date DEFAULT NULL, _job_title text DEFAULT 'general_manager')
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE _p public.partners; _prof public.user_profiles;
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only the Super Admin can assign a managing partner'; END IF;
  SELECT * INTO _p FROM public.partners WHERE id=_partner_id AND company_id=public.current_company_id() FOR UPDATE;
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Partner not found'; END IF;
  IF _on THEN
    IF _p.user_id IS NULL THEN RAISE EXCEPTION 'This partner has no login account. Create one first.'; END IF;
    SELECT * INTO _prof FROM public.user_profiles WHERE auth_user_id=_p.user_id AND company_id=_p.company_id;
    IF _prof.id IS NULL THEN RAISE EXCEPTION 'No staff profile found for this partner'; END IF;
    UPDATE public.partners SET is_managing_staff=true, updated_at=now() WHERE id=_partner_id;
    PERFORM public.update_employee_profile(_prof.id, COALESCE(NULLIF(_prof.display_name,''), _p.name), COALESCE(_job_title,'general_manager'), COALESCE(_base_salary,0), _hire_date);
  ELSE
    UPDATE public.partners SET is_managing_staff=false, updated_at=now() WHERE id=_partner_id;
    SELECT * INTO _prof FROM public.user_profiles WHERE auth_user_id=_p.user_id AND company_id=_p.company_id;
    IF _prof.id IS NOT NULL THEN
      UPDATE public.employee_salaries SET is_active=false, updated_at=now() WHERE user_id=_prof.id AND is_active;
    END IF;
  END IF;
  PERFORM public.log_audit(CASE WHEN _on THEN 'partner.managing_on' ELSE 'partner.managing_off' END,'partners','partners',_partner_id,NULL,
    jsonb_build_object('salary',_base_salary,'hire_date',_hire_date,'job_title',_job_title),NULL,NULL);
  RETURN _prof.id;
END $function$;

CREATE OR REPLACE FUNCTION public.payout_partner_combined(_period_id uuid, _partner_id uuid, _salary_payment_id uuid, _method text DEFAULT 'cash')
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only the Super Admin can pay out'; END IF;
  PERFORM public.pay_salary(_salary_payment_id, NULL, _method);
  PERFORM public.payout_partner_dividend(_period_id, _partner_id, _method, NULL);
END $function$;

REVOKE EXECUTE ON FUNCTION public.set_partner_managing(uuid,boolean,numeric,date,text), public.payout_partner_combined(uuid,uuid,uuid,text) FROM anon;