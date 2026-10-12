DO $$ DECLARE d text; BEGIN
 d := pg_get_functiondef('public.hr_payroll_preview(date,date)'::regprocedure);
 d := replace(d, 'sh.opened_by=b.uid', 'sh.user_id=b.uid');
 EXECUTE d;
END $$;