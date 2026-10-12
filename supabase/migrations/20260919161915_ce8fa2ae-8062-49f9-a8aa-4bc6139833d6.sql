INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM public.roles r
CROSS JOIN public.permissions p
WHERE r.key = 'partner'
  AND p.key IN ('shifts.view', 'reports.sales')
ON CONFLICT (role_id, permission_id) DO NOTHING;