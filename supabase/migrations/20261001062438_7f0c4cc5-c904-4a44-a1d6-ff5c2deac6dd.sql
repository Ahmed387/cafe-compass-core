-- Root super admin
CREATE OR REPLACE FUNCTION public.is_root_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles
    WHERE auth_user_id = auth.uid() AND is_active AND lower(email) = 'assemsalah19@icloud.com')
$$;
GRANT EXECUTE ON FUNCTION public.is_root_admin() TO authenticated;

CREATE OR REPLACE FUNCTION public.guard_root_and_super_roles()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_row public.user_roles; v_key text; v_email text;
BEGIN
  v_row := CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  SELECT key INTO v_key FROM public.roles WHERE id = COALESCE(OLD.role_id, NEW.role_id);
  IF TG_OP = 'UPDATE' AND OLD.role_id IS DISTINCT FROM NEW.role_id THEN
    SELECT key INTO v_key FROM public.roles WHERE id = OLD.role_id;
    IF v_key IS DISTINCT FROM 'super_admin' THEN SELECT key INTO v_key FROM public.roles WHERE id = NEW.role_id; END IF;
  END IF;
  IF v_key = 'super_admin' THEN
    SELECT lower(email) INTO v_email FROM public.user_profiles WHERE id = COALESCE(OLD.user_id, NEW.user_id);
    IF TG_OP <> 'INSERT' AND v_email = 'assemsalah19@icloud.com' THEN
      RAISE EXCEPTION 'لا يمكن سحب صلاحية المالك الأساسي / Root Super Admin cannot be demoted';
    END IF;
    IF auth.uid() IS NOT NULL AND NOT public.is_root_admin() THEN
      RAISE EXCEPTION 'منح أو سحب السوبر أدمن للمالك الأساسي فقط / Only the Root Super Admin can grant or revoke Super Admin';
    END IF;
  END IF;
  RETURN v_row;
END $$;
DROP TRIGGER IF EXISTS trg_guard_super_roles ON public.user_roles;
CREATE TRIGGER trg_guard_super_roles BEFORE INSERT OR UPDATE OR DELETE ON public.user_roles
FOR EACH ROW EXECUTE FUNCTION public.guard_root_and_super_roles();

CREATE OR REPLACE FUNCTION public.guard_root_profile()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF lower(OLD.email) = 'assemsalah19@icloud.com' THEN
    IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'لا يمكن حذف المالك الأساسي / Root Super Admin cannot be deleted'; END IF;
    IF NOT NEW.is_active OR lower(NEW.email) <> lower(OLD.email) OR NEW.auth_user_id IS DISTINCT FROM OLD.auth_user_id THEN
      RAISE EXCEPTION 'لا يمكن تعطيل أو تغيير المالك الأساسي / Root Super Admin is immutable';
    END IF;
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;
DROP TRIGGER IF EXISTS trg_guard_root_profile ON public.user_profiles;
CREATE TRIGGER trg_guard_root_profile BEFORE UPDATE OR DELETE ON public.user_profiles
FOR EACH ROW EXECUTE FUNCTION public.guard_root_profile();

CREATE OR REPLACE FUNCTION public.set_user_super_admin(_profile_id uuid, _on boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_role uuid; v_company uuid;
BEGIN
  IF NOT public.is_root_admin() THEN RAISE EXCEPTION 'Root Super Admin only'; END IF;
  SELECT company_id INTO v_company FROM public.user_profiles WHERE id = _profile_id AND company_id = public.current_company_id();
  IF v_company IS NULL THEN RAISE EXCEPTION 'User not found'; END IF;
  SELECT id INTO v_role FROM public.roles WHERE key = 'super_admin' AND company_id = v_company LIMIT 1;
  IF v_role IS NULL THEN RAISE EXCEPTION 'Super Admin role missing'; END IF;
  IF _on THEN
    INSERT INTO public.user_roles (user_id, role_id) SELECT _profile_id, v_role
    WHERE NOT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _profile_id AND role_id = v_role);
  ELSE
    DELETE FROM public.user_roles WHERE user_id = _profile_id AND role_id = v_role;
  END IF;
  PERFORM public.log_audit(CASE WHEN _on THEN 'user.super_admin_grant' ELSE 'user.super_admin_revoke' END, 'users', 'user_profiles', _profile_id);
END $$;
GRANT EXECUTE ON FUNCTION public.set_user_super_admin(uuid, boolean) TO authenticated;

-- Partner tiers
ALTER TABLE public.partners ADD COLUMN IF NOT EXISTS tier text NOT NULL DEFAULT 'silent';
UPDATE public.partners SET tier = 'manager' WHERE is_managing_staff AND tier = 'silent';
ALTER TABLE public.partners DROP CONSTRAINT IF EXISTS partners_tier_check;
ALTER TABLE public.partners ADD CONSTRAINT partners_tier_check CHECK (tier IN ('silent','manager','manager_employee'));

CREATE OR REPLACE FUNCTION public.set_partner_tier(_partner_id uuid, _tier text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Super Admin only'; END IF;
  IF _tier NOT IN ('silent','manager','manager_employee') THEN RAISE EXCEPTION 'Invalid tier'; END IF;
  UPDATE public.partners SET tier = _tier, updated_at = now()
  WHERE id = _partner_id AND company_id = public.current_company_id();
  IF NOT FOUND THEN RAISE EXCEPTION 'Partner not found'; END IF;
  PERFORM public.log_audit('partner.tier_change', 'partners', 'partners', _partner_id);
END $$;
GRANT EXECUTE ON FUNCTION public.set_partner_tier(uuid, text) TO authenticated;

-- Managerial compensation
CREATE TABLE IF NOT EXISTS public.manager_compensation (
  profile_id uuid PRIMARY KEY REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  company_id uuid NOT NULL REFERENCES public.companies(id),
  mode text NOT NULL DEFAULT 'fixed' CHECK (mode IN ('fixed','percent','hybrid')),
  fixed_amount numeric NOT NULL DEFAULT 0 CHECK (fixed_amount >= 0),
  percent numeric NOT NULL DEFAULT 0 CHECK (percent >= 0 AND percent <= 100),
  basis text NOT NULL DEFAULT 'profit' CHECK (basis IN ('profit','sales')),
  updated_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.manager_compensation TO authenticated;
GRANT ALL ON public.manager_compensation TO service_role;
ALTER TABLE public.manager_compensation ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Own or super admin can view compensation" ON public.manager_compensation
FOR SELECT TO authenticated USING (profile_id = public.current_profile_id() OR (public.is_super_admin() AND company_id = public.current_company_id()));

CREATE OR REPLACE FUNCTION public.set_manager_compensation(_profile_id uuid, _mode text, _fixed numeric, _percent numeric, _basis text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_company uuid;
BEGIN
  IF NOT public.is_root_admin() THEN RAISE EXCEPTION 'Root Super Admin only'; END IF;
  SELECT company_id INTO v_company FROM public.user_profiles WHERE id = _profile_id AND company_id = public.current_company_id();
  IF v_company IS NULL THEN RAISE EXCEPTION 'User not found'; END IF;
  INSERT INTO public.manager_compensation (profile_id, company_id, mode, fixed_amount, percent, basis, updated_by)
  VALUES (_profile_id, v_company, _mode,
          CASE WHEN _mode = 'percent' THEN 0 ELSE COALESCE(_fixed,0) END,
          CASE WHEN _mode = 'fixed' THEN 0 ELSE COALESCE(_percent,0) END, _basis, public.current_profile_id())
  ON CONFLICT (profile_id) DO UPDATE SET mode = EXCLUDED.mode, fixed_amount = EXCLUDED.fixed_amount,
    percent = EXCLUDED.percent, basis = EXCLUDED.basis, updated_by = EXCLUDED.updated_by, updated_at = now();
  PERFORM public.log_audit('compensation.update', 'payroll', 'user_profiles', _profile_id);
END $$;
GRANT EXECUTE ON FUNCTION public.set_manager_compensation(uuid, text, numeric, numeric, text) TO authenticated;

-- Navigation overrides
CREATE TABLE IF NOT EXISTS public.user_nav_overrides (
  profile_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  path text NOT NULL,
  visible boolean NOT NULL,
  company_id uuid NOT NULL REFERENCES public.companies(id),
  updated_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (profile_id, path)
);
GRANT SELECT ON public.user_nav_overrides TO authenticated;
GRANT ALL ON public.user_nav_overrides TO service_role;
ALTER TABLE public.user_nav_overrides ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Own or super admin can view nav overrides" ON public.user_nav_overrides
FOR SELECT TO authenticated USING (profile_id = public.current_profile_id() OR (public.is_super_admin() AND company_id = public.current_company_id()));

CREATE OR REPLACE FUNCTION public.set_nav_override(_profile_id uuid, _path text, _visible boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_company uuid;
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'Super Admin only'; END IF;
  IF _path !~ '^/[a-z0-9\-]+$' THEN RAISE EXCEPTION 'Invalid path'; END IF;
  SELECT company_id INTO v_company FROM public.user_profiles WHERE id = _profile_id AND company_id = public.current_company_id();
  IF v_company IS NULL THEN RAISE EXCEPTION 'User not found'; END IF;
  IF _visible IS NULL THEN
    DELETE FROM public.user_nav_overrides WHERE profile_id = _profile_id AND path = _path;
  ELSE
    INSERT INTO public.user_nav_overrides (profile_id, path, visible, company_id, updated_by)
    VALUES (_profile_id, _path, _visible, v_company, public.current_profile_id())
    ON CONFLICT (profile_id, path) DO UPDATE SET visible = EXCLUDED.visible, updated_by = EXCLUDED.updated_by, updated_at = now();
  END IF;
  PERFORM public.log_audit('nav.override', 'users', 'user_profiles', _profile_id);
END $$;
GRANT EXECUTE ON FUNCTION public.set_nav_override(uuid, text, boolean) TO authenticated;

-- Personal owner statement (always scoped to the caller)
CREATE OR REPLACE FUNCTION public.my_owner_statement()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_profile uuid := public.current_profile_id(); v_p public.partners; v_comp public.manager_compensation;
  v_capital numeric := 0; v_total_capital numeric := 0; v_unpaid numeric := 0; v_unpaid_count int := 0;
  v_month_sales numeric := 0;
BEGIN
  IF v_profile IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO v_p FROM public.partners WHERE user_id = v_profile AND status = 'active' LIMIT 1;
  SELECT * INTO v_comp FROM public.manager_compensation WHERE profile_id = v_profile;
  IF v_p.id IS NOT NULL THEN
    SELECT COALESCE(SUM(amount),0) INTO v_capital FROM public.partner_capital_contributions WHERE partner_id = v_p.id AND status = 'active';
    SELECT COALESCE(SUM(c.amount),0) INTO v_total_capital FROM public.partner_capital_contributions c JOIN public.partners p ON p.id = c.partner_id
      WHERE c.company_id = v_p.company_id AND c.status = 'active' AND p.status = 'active';
    SELECT COALESCE(SUM(total_amount),0), COUNT(*) INTO v_unpaid, v_unpaid_count FROM public.partner_tab_orders WHERE partner_id = v_p.id AND NOT is_settled;
  END IF;
  SELECT COALESCE(SUM(total),0) INTO v_month_sales FROM public.orders
    WHERE company_id = public.current_company_id() AND status IN ('completed','partially_refunded')
      AND created_at >= date_trunc('month', now());
  RETURN jsonb_build_object(
    'partner', CASE WHEN v_p.id IS NULL THEN NULL ELSE jsonb_build_object(
      'id', v_p.id, 'name', v_p.name, 'tier', v_p.tier, 'share', v_p.profit_share_percentage,
      'capital', v_capital, 'total_capital', v_total_capital,
      'unpaid_tabs', v_unpaid, 'unpaid_count', v_unpaid_count) END,
    'compensation', CASE WHEN v_comp.profile_id IS NULL THEN NULL ELSE jsonb_build_object(
      'mode', v_comp.mode, 'fixed', v_comp.fixed_amount, 'percent', v_comp.percent, 'basis', v_comp.basis) END,
    'month_sales', v_month_sales,
    'profit', CASE WHEN v_p.id IS NULL THEN NULL ELSE public.get_my_partner_profit_summary() END
  );
END $$;
GRANT EXECUTE ON FUNCTION public.my_owner_statement() TO authenticated;