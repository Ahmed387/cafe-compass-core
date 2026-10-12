DO $$ DECLARE d text; BEGIN
 d := pg_get_functiondef('public.pay_salary(uuid,uuid,text)'::regprocedure);
 d := replace(d, $x$'salary_payment', _salary_id, 'Salary payment');$x$, $x$'salary_payment', _salary_id, 'Salary payment', NULL, _method <> 'bank');$x$);
 EXECUTE d;
END $$;