CREATE POLICY "modifier_groups_delete" ON public.modifier_groups
  FOR DELETE TO authenticated
  USING (company_id = public.current_company_id() AND public.has_permission('products.update'));

CREATE OR REPLACE FUNCTION public.delete_modifier_group(_group_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _company uuid;
  _used boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  SELECT company_id INTO _company FROM public.modifier_groups WHERE id = _group_id;
  IF _company IS NULL OR _company <> public.current_company_id() THEN
    RAISE EXCEPTION 'group not found';
  END IF;
  IF NOT public.has_permission('products.update') THEN
    RAISE EXCEPTION 'permission denied';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.order_item_modifiers oim
    JOIN public.modifier_options o ON o.id = oim.option_id
    WHERE o.group_id = _group_id
  ) INTO _used;

  IF _used THEN
    UPDATE public.modifier_groups SET is_active = false, updated_at = now() WHERE id = _group_id;
    PERFORM public.log_audit('modifier_group.deactivate', 'products', 'modifier_groups', _group_id);
    RETURN jsonb_build_object('deleted', false, 'deactivated', true);
  END IF;

  DELETE FROM public.product_modifier_groups WHERE group_id = _group_id;
  DELETE FROM public.modifier_groups WHERE id = _group_id;
  PERFORM public.log_audit('modifier_group.delete', 'products', 'modifier_groups', _group_id);
  RETURN jsonb_build_object('deleted', true, 'deactivated', false);
END;
$$;

REVOKE ALL ON FUNCTION public.delete_modifier_group(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_modifier_group(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_modifier_group(uuid) TO service_role;

CREATE POLICY "product images public read" ON storage.objects
  FOR SELECT TO anon
  USING (bucket_id = 'product-images');
