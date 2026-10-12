ALTER TABLE public.audit_logs DISABLE TRIGGER USER;
DELETE FROM public.audit_logs WHERE module IN ('pos','kitchen');
ALTER TABLE public.audit_logs ENABLE TRIGGER USER;