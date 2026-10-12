CREATE OR REPLACE FUNCTION public.delete_modifier_option(_option_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  _profile uuid := public.current_profile_id();
  _opt public.modifier_options;
  _company uuid;
  _used int := 0;
  _lines int := 0;
  _mode text;
BEGIN
  IF _profile IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT (public.has_permission('products.update') OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT * INTO _opt FROM public.modifier_options WHERE id = _option_id;
  IF _opt.id IS NULL THEN RAISE EXCEPTION 'Modifier option not found'; END IF;

  SELECT g.company_id INTO _company FROM public.modifier_groups g WHERE g.id = _opt.group_id;
  IF _company IS DISTINCT FROM public.current_company_id() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT count(*) INTO _used FROM public.order_item_modifiers WHERE option_id = _option_id;
  SELECT count(*) INTO _lines FROM public.modifier_option_recipes WHERE option_id = _option_id;

  DELETE FROM public.modifier_option_recipes WHERE option_id = _option_id;

  IF _used > 0 THEN
    UPDATE public.modifier_options SET is_active = false, updated_at = now() WHERE id = _option_id;
    _mode := 'deactivated';
  ELSE
    DELETE FROM public.modifier_options WHERE id = _option_id;
    _mode := 'deleted';
  END IF;

  PERFORM public.log_audit('modifier_option.' || _mode, 'catalog', 'modifier_options', _option_id,
    jsonb_build_object('name', _opt.name, 'price_delta', _opt.price_delta),
    jsonb_build_object('mode', _mode, 'sales_lines', _used, 'recipe_lines_removed', _lines),
    NULL, NULL);

  RETURN jsonb_build_object('mode', _mode, 'sales_lines', _used, 'recipe_lines_removed', _lines);
END
$fn$;

REVOKE ALL ON FUNCTION public.delete_modifier_option(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_modifier_option(uuid) TO authenticated, service_role;