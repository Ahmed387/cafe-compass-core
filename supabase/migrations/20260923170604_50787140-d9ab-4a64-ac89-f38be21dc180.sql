INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM public.roles r CROSS JOIN public.permissions p
WHERE r.name = 'Partner' AND p.key = 'payroll.view'
ON CONFLICT DO NOTHING;