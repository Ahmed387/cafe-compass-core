CREATE OR REPLACE FUNCTION public.pos_partners()
RETURNS TABLE(id uuid, name text, customer_id uuid)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT p.id, p.name, p.customer_id
  FROM public.partners p
  WHERE p.company_id = public.current_company_id()
    AND p.status = 'active'
    AND (public.has_permission('pos.create_order') OR public.is_super_admin()
         OR public.has_permission('partners.view'))
  ORDER BY p.name
$$;

REVOKE ALL ON FUNCTION public.pos_partners() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pos_partners() TO authenticated;