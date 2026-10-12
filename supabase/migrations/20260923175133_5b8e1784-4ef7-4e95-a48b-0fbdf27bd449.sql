ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS is_managing_staff boolean NOT NULL DEFAULT false;
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS track_stock boolean NOT NULL DEFAULT true;

-- Protect the new flag from self-edits
CREATE OR REPLACE FUNCTION public.guard_profile_self_update()
 RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public'
AS $function$
BEGIN
  IF public.is_super_admin() OR public.has_permission('users.update') THEN RETURN NEW; END IF;
  IF NEW.company_id IS DISTINCT FROM OLD.company_id
     OR NEW.auth_user_id IS DISTINCT FROM OLD.auth_user_id
     OR NEW.is_active IS DISTINCT FROM OLD.is_active
     OR NEW.email IS DISTINCT FROM OLD.email
     OR NEW.employee_code IS DISTINCT FROM OLD.employee_code
     OR NEW.is_managing_staff IS DISTINCT FROM OLD.is_managing_staff THEN
    RAISE EXCEPTION 'You cannot change these profile fields';
  END IF;
  RETURN NEW;
END $function$;

-- Catalog items that are sold without stock tracking skip the recipe requirement
DO $$
DECLARE d text;
BEGIN
  d := pg_get_functiondef('public.check_order_stock(uuid,jsonb)'::regprocedure);
  d := replace(d, 'SELECT 1 FROM public.product_recipes pr WHERE pr.product_id = _pid
    ) THEN',
   'SELECT 1 FROM public.product_recipes pr WHERE pr.product_id = _pid
    ) AND NOT EXISTS (SELECT 1 FROM public.products px WHERE px.id = _pid AND NOT px.track_stock) THEN');
  IF position('px.track_stock' in d) = 0 THEN RAISE EXCEPTION 'check_order_stock patch failed'; END IF;
  EXECUTE d;

  -- Custom (manual) items in create_pos_order
  d := pg_get_functiondef('public.create_pos_order(uuid,jsonb,jsonb,order_type,numeric,text,text,text,text,uuid,text,uuid,boolean)'::regprocedure);
  d := replace(d, '    IF _qty <= 0 THEN RAISE EXCEPTION ''Item quantity must be greater than zero''; END IF;

    SELECT * INTO _product FROM public.products
    WHERE id = NULLIF(_item->>''product_id'','''')::uuid AND company_id = _company AND is_active;
    IF _product.id IS NULL THEN RAISE EXCEPTION ''Product not found or unavailable''; END IF;
    IF NOT _product.is_available',
  '    IF _qty <= 0 THEN RAISE EXCEPTION ''Item quantity must be greater than zero''; END IF;

    IF COALESCE((_item->>''custom'')::boolean, false) THEN
      IF NULLIF(btrim(COALESCE(_item->>''product_name'','''')),'''') IS NULL OR length(_item->>''product_name'') > 80 THEN
        RAISE EXCEPTION ''Custom item name is required (max 80 characters)'';
      END IF;
      _unit_price := round(COALESCE((_item->>''unit_price'')::numeric, 0), 2);
      IF _unit_price <= 0 OR _unit_price > 100000 THEN RAISE EXCEPTION ''Custom item price is invalid''; END IF;
      IF _qty > 999 THEN RAISE EXCEPTION ''Custom item quantity is too large''; END IF;
      _line := round(_unit_price * _qty, 2);
      INSERT INTO public.order_items (order_id, product_id, size_id, product_name, size_name,
        unit_price, base_price, offer_id, bundle_key, modifiers_total, quantity, line_total, unit_cost, notes)
      VALUES (_order, NULL, NULL, btrim(_item->>''product_name''), NULL,
        _unit_price, _unit_price, NULL, NULL, 0, _qty, _line, 0, ''custom'');
      _subtotal := _subtotal + _line;
      _taxable_base := _taxable_base + _line;
      CONTINUE;
    END IF;

    SELECT * INTO _product FROM public.products
    WHERE id = NULLIF(_item->>''product_id'','''')::uuid AND company_id = _company AND is_active;
    IF _product.id IS NULL THEN RAISE EXCEPTION ''Product not found or unavailable''; END IF;
    IF NOT _product.is_available');
  IF position('Custom item price is invalid' in d) = 0 THEN RAISE EXCEPTION 'create_pos_order patch failed'; END IF;
  EXECUTE d;

  -- HR: hide Super Admins unless flagged as managing staff
  d := pg_get_functiondef('public.hr_payroll_preview(date,date)'::regprocedure);
  d := replace(d, 'AND NOT pt.is_managing_staff)',
   'AND NOT pt.is_managing_staff) AND (p.is_managing_staff OR NOT EXISTS (SELECT 1 FROM public.user_roles ur JOIN public.roles r ON r.id=ur.role_id WHERE ur.user_id=p.id AND r.key=''super_admin''))');
  IF position('r.key=''super_admin''' in d) = 0 THEN RAISE EXCEPTION 'hr patch failed'; END IF;
  EXECUTE d;
END $$;

CREATE OR REPLACE FUNCTION public.set_super_admin_managing(_on boolean, _base_salary numeric DEFAULT 0, _hire_date date DEFAULT NULL, _job_title text DEFAULT 'general_manager')
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE _prof public.user_profiles;
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only the Super Admin can do this'; END IF;
  SELECT * INTO _prof FROM public.user_profiles WHERE id = public.current_profile_id();
  IF _on THEN
    IF COALESCE(_base_salary,0) < 0 THEN RAISE EXCEPTION 'Salary cannot be negative'; END IF;
    UPDATE public.user_profiles SET is_managing_staff = true, updated_at = now() WHERE id = _prof.id;
    PERFORM public.update_employee_profile(_prof.id,
      COALESCE(NULLIF(_prof.display_name,''), _prof.email), COALESCE(_job_title,'general_manager'), COALESCE(_base_salary,0), _hire_date);
  ELSE
    UPDATE public.user_profiles SET is_managing_staff = false, updated_at = now() WHERE id = _prof.id;
    UPDATE public.employee_salaries SET is_active = false, updated_at = now() WHERE user_id = _prof.id AND is_active;
  END IF;
  PERFORM public.log_audit(CASE WHEN _on THEN 'super_admin.managing_on' ELSE 'super_admin.managing_off' END,
    'hr','user_profiles',_prof.id,NULL,
    jsonb_build_object('salary',_base_salary,'hire_date',_hire_date,'job_title',_job_title),NULL,NULL);
  RETURN _prof.id;
END $$;
GRANT EXECUTE ON FUNCTION public.set_super_admin_managing(boolean,numeric,date,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.link_partner_account(_partner_id uuid, _email text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE _p public.partners; _prof uuid; _role uuid;
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Only the Super Admin can link partner accounts'; END IF;
  SELECT * INTO _p FROM public.partners WHERE id=_partner_id AND company_id=public.current_company_id() FOR UPDATE;
  IF _p.id IS NULL THEN RAISE EXCEPTION 'Partner not found'; END IF;
  SELECT id INTO _prof FROM public.user_profiles
   WHERE company_id=_p.company_id AND lower(email)=lower(btrim(_email)) LIMIT 1;
  IF _prof IS NULL THEN RAISE EXCEPTION 'No user account with this email'; END IF;
  IF EXISTS (SELECT 1 FROM public.partners WHERE user_id=_prof AND id<>_partner_id AND status<>'exited') THEN
    RAISE EXCEPTION 'This account is already linked to another partner';
  END IF;
  UPDATE public.partners SET user_id=_prof, updated_at=now() WHERE id=_partner_id;
  SELECT id INTO _role FROM public.roles WHERE key='partner' LIMIT 1;
  IF _role IS NOT NULL THEN
    INSERT INTO public.user_roles(user_id, role_id) VALUES (_prof, _role) ON CONFLICT DO NOTHING;
  END IF;
  PERFORM public.log_audit('partner.link_account','partners','partners',_partner_id,
    jsonb_build_object('user_id',_p.user_id), jsonb_build_object('user_id',_prof),NULL,NULL);
  RETURN _prof;
END $$;
GRANT EXECUTE ON FUNCTION public.link_partner_account(uuid,text) TO authenticated;