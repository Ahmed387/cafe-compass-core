DO $$ DECLARE d text; BEGIN
 d := pg_get_functiondef('public.hr_payroll_preview(date,date)'::regprocedure);
 d := replace(d, 'pt.user_id=p.auth_user_id', 'pt.user_id=p.id');
 EXECUTE d;
 d := pg_get_functiondef('public.set_partner_managing(uuid,boolean,numeric,date,text)'::regprocedure);
 d := replace(d, 'WHERE auth_user_id=_p.user_id AND company_id=_p.company_id', 'WHERE id=_p.user_id AND company_id=_p.company_id');
 EXECUTE d;
END $$;