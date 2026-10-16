-- =====================================================================
-- Owner rule (2026-10-16): only a Manager or the Super Admin closes a shift;
-- a cashier never closes one or edits the drawer figures.
--   * cashier role loses shifts.close and shifts.adjust_cash
--   * manager role gains shifts.adjust_cash, which lets a manager close a
--     shift a cashier opened (closing someone else's shift needs it)
-- Applies to every company's system roles. Audited.
-- =====================================================================
WITH removed AS (
  DELETE FROM public.role_permissions rp
   USING public.roles r, public.permissions p
   WHERE rp.role_id = r.id AND rp.permission_id = p.id
     AND r.key = 'cashier' AND r.is_system_role
     AND p.key IN ('shifts.close', 'shifts.adjust_cash')
  RETURNING r.company_id, p.key)
INSERT INTO public.audit_logs (company_id, action, module, entity_type, old_values, new_values, reason)
SELECT company_id, 'roles.permission_removed', 'governance', 'roles',
       jsonb_build_object('role', 'cashier', 'permission', key), NULL,
       'الكاشير مش بيقفل وردية (قرار صاحب الكافيه 2026-10-16)'
  FROM removed;

WITH added AS (
  INSERT INTO public.role_permissions (role_id, permission_id)
  SELECT r.id, p.id FROM public.roles r CROSS JOIN public.permissions p
   WHERE r.key = 'manager' AND r.is_system_role AND p.key = 'shifts.adjust_cash'
     AND NOT EXISTS (SELECT 1 FROM public.role_permissions x WHERE x.role_id = r.id AND x.permission_id = p.id)
  RETURNING role_id)
INSERT INTO public.audit_logs (company_id, action, module, entity_type, old_values, new_values, reason)
SELECT r.company_id, 'roles.permission_added', 'governance', 'roles', NULL,
       jsonb_build_object('role', 'manager', 'permission', 'shifts.adjust_cash'),
       'المدير هو اللي بيقفل الوردية حتى لو الكاشير فتحها (قرار صاحب الكافيه 2026-10-16)'
  FROM added a JOIN public.roles r ON r.id = a.role_id;
