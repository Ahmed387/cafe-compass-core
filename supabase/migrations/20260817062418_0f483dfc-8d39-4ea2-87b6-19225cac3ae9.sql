INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM public.roles r, public.permissions p
WHERE r.name = 'Accountant' AND p.key IN ('products.view','inventory.view')
ON CONFLICT DO NOTHING;

DELETE FROM public.role_permissions
WHERE permission_id IN (SELECT id FROM public.permissions WHERE key = 'inventory.transfer');
DELETE FROM public.permissions WHERE key = 'inventory.transfer';