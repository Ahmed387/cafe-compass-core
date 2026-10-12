
-- ============ ENUMS ============
CREATE TYPE public.partner_status AS ENUM ('active','inactive','exited');
CREATE TYPE public.ledger_txn_type AS ENUM ('profit_distribution','withdrawal','capital_contribution','adjustment');
CREATE TYPE public.period_type AS ENUM ('monthly','quarterly','yearly','custom');
CREATE TYPE public.period_status AS ENUM ('open','closed');
CREATE TYPE public.record_status AS ENUM ('active','cancelled','voided','reversed');
CREATE TYPE public.app_language AS ENUM ('ar','en');

CREATE OR REPLACE FUNCTION public.set_updated_at() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END $$;

CREATE OR REPLACE FUNCTION public.forbid_hard_delete() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN RAISE EXCEPTION 'Records in % are append-only and cannot be deleted', TG_TABLE_NAME; END $$;

-- ============ CORE ============
CREATE TABLE public.companies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  legal_name text,
  logo_url text,
  currency text NOT NULL DEFAULT 'EGP',
  timezone text NOT NULL DEFAULT 'Africa/Cairo',
  default_language public.app_language NOT NULL DEFAULT 'en',
  tax_enabled boolean NOT NULL DEFAULT false,
  tax_rate numeric(6,3) NOT NULL DEFAULT 0 CHECK (tax_rate >= 0 AND tax_rate <= 100),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.branches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  name text NOT NULL,
  code text NOT NULL,
  address text,
  phone text,
  timezone text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (company_id, code)
);
CREATE INDEX idx_branches_company ON public.branches(company_id);

CREATE TABLE public.user_profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_user_id uuid NOT NULL UNIQUE,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  first_name text NOT NULL,
  last_name text,
  display_name text,
  email text NOT NULL,
  phone text,
  employee_code text,
  avatar_url text,
  preferred_language public.app_language NOT NULL DEFAULT 'en',
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (company_id, employee_code)
);
CREATE INDEX idx_user_profiles_company ON public.user_profiles(company_id);

CREATE TABLE public.roles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  key text,
  name text NOT NULL,
  description text,
  is_system_role boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (company_id, name)
);

CREATE TABLE public.permissions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key text NOT NULL UNIQUE,
  name text NOT NULL,
  description text,
  module text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_permissions_module ON public.permissions(module);

CREATE TABLE public.role_permissions (
  role_id uuid NOT NULL REFERENCES public.roles(id) ON DELETE CASCADE,
  permission_id uuid NOT NULL REFERENCES public.permissions(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (role_id, permission_id)
);

CREATE TABLE public.user_roles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  role_id uuid NOT NULL REFERENCES public.roles(id) ON DELETE CASCADE,
  branch_id uuid REFERENCES public.branches(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX idx_user_roles_unique ON public.user_roles(user_id, role_id, COALESCE(branch_id, '00000000-0000-0000-0000-000000000000'::uuid));

CREATE TABLE public.user_branches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  is_default boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, branch_id)
);

-- ============ SECURITY HELPERS (SECURITY DEFINER, bypass RLS) ============
CREATE OR REPLACE FUNCTION public.current_profile_id() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT id FROM public.user_profiles WHERE auth_user_id = auth.uid() AND is_active LIMIT 1
$$;

CREATE OR REPLACE FUNCTION public.current_company_id() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT company_id FROM public.user_profiles WHERE auth_user_id = auth.uid() AND is_active LIMIT 1
$$;

CREATE OR REPLACE FUNCTION public.has_permission(_key text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_profiles up
    JOIN public.user_roles ur ON ur.user_id = up.id
    JOIN public.role_permissions rp ON rp.role_id = ur.role_id
    JOIN public.permissions p ON p.id = rp.permission_id
    WHERE up.auth_user_id = auth.uid() AND up.is_active AND p.key = _key
  )
$$;

CREATE OR REPLACE FUNCTION public.is_super_admin() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_profiles up
    JOIN public.user_roles ur ON ur.user_id = up.id
    JOIN public.roles r ON r.id = ur.role_id
    WHERE up.auth_user_id = auth.uid() AND up.is_active AND r.key = 'super_admin'
  )
$$;

CREATE OR REPLACE FUNCTION public.can_access_branch(_branch_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT _branch_id IS NULL
    OR public.is_super_admin()
    OR EXISTS (
      SELECT 1 FROM public.user_branches ub
      WHERE ub.user_id = public.current_profile_id() AND ub.branch_id = _branch_id
    )
$$;

-- ============ PARTNERS ============
CREATE TABLE public.partners (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  user_id uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  name text NOT NULL,
  email text,
  phone text,
  status public.partner_status NOT NULL DEFAULT 'active',
  notes text,
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_partners_company ON public.partners(company_id);

CREATE OR REPLACE FUNCTION public.current_partner_id() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT id FROM public.partners WHERE user_id = public.current_profile_id() LIMIT 1
$$;

CREATE TABLE public.partner_capital_contributions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  partner_id uuid NOT NULL REFERENCES public.partners(id) ON DELETE RESTRICT,
  amount numeric(14,2) NOT NULL CHECK (amount > 0),
  currency text NOT NULL DEFAULT 'EGP',
  contribution_date date NOT NULL DEFAULT CURRENT_DATE,
  payment_method text,
  reference text,
  notes text,
  status public.record_status NOT NULL DEFAULT 'active',
  reversal_of uuid REFERENCES public.partner_capital_contributions(id),
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_pcc_partner ON public.partner_capital_contributions(partner_id);

CREATE TABLE public.partner_ledger_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  partner_id uuid NOT NULL REFERENCES public.partners(id) ON DELETE RESTRICT,
  transaction_type public.ledger_txn_type NOT NULL,
  amount numeric(14,2) NOT NULL,
  currency text NOT NULL DEFAULT 'EGP',
  reference_type text,
  reference_id uuid,
  description text,
  transaction_date date NOT NULL DEFAULT CURRENT_DATE,
  status public.record_status NOT NULL DEFAULT 'active',
  reversal_of uuid REFERENCES public.partner_ledger_transactions(id),
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_plt_partner ON public.partner_ledger_transactions(partner_id);

CREATE TABLE public.accounting_periods (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  period_type public.period_type NOT NULL DEFAULT 'monthly',
  start_date date NOT NULL,
  end_date date NOT NULL,
  status public.period_status NOT NULL DEFAULT 'open',
  closed_at timestamptz,
  closed_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (end_date >= start_date),
  UNIQUE (company_id, period_type, start_date, end_date)
);

CREATE TABLE public.profit_distributions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  period_id uuid NOT NULL REFERENCES public.accounting_periods(id) ON DELETE RESTRICT,
  net_profit numeric(14,2) NOT NULL DEFAULT 0,
  currency text NOT NULL DEFAULT 'EGP',
  status public.record_status NOT NULL DEFAULT 'active',
  distributed_at timestamptz,
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.profit_distribution_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  distribution_id uuid NOT NULL REFERENCES public.profit_distributions(id) ON DELETE CASCADE,
  partner_id uuid NOT NULL REFERENCES public.partners(id) ON DELETE RESTRICT,
  ownership_percentage numeric(7,4) NOT NULL CHECK (ownership_percentage >= 0 AND ownership_percentage <= 100),
  amount numeric(14,2) NOT NULL,
  ledger_transaction_id uuid REFERENCES public.partner_ledger_transactions(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (distribution_id, partner_id)
);

-- derived views (no editable derived columns)
CREATE OR REPLACE VIEW public.partner_ownership WITH (security_invoker = true) AS
SELECT p.id AS partner_id, p.company_id, p.name,
  COALESCE(c.total, 0) AS total_contributions,
  CASE WHEN SUM(COALESCE(c.total,0)) OVER (PARTITION BY p.company_id) > 0
    THEN ROUND(COALESCE(c.total,0) * 100.0 / SUM(COALESCE(c.total,0)) OVER (PARTITION BY p.company_id), 4)
    ELSE 0 END AS ownership_percentage
FROM public.partners p
LEFT JOIN (
  SELECT partner_id, SUM(amount) AS total
  FROM public.partner_capital_contributions WHERE status = 'active' GROUP BY partner_id
) c ON c.partner_id = p.id
WHERE p.status <> 'exited';

CREATE OR REPLACE VIEW public.partner_balances WITH (security_invoker = true) AS
SELECT p.id AS partner_id, p.company_id, p.name,
  COALESCE(SUM(CASE WHEN t.status = 'active' THEN t.amount ELSE 0 END), 0) AS balance
FROM public.partners p
LEFT JOIN public.partner_ledger_transactions t ON t.partner_id = p.id
GROUP BY p.id, p.company_id, p.name;

-- ============ AUDIT / NOTIFICATIONS / SETTINGS ============
CREATE TABLE public.audit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid REFERENCES public.companies(id) ON DELETE CASCADE,
  branch_id uuid REFERENCES public.branches(id) ON DELETE SET NULL,
  user_id uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  action text NOT NULL,
  module text NOT NULL,
  entity_type text,
  entity_id uuid,
  old_values jsonb,
  new_values jsonb,
  reason text,
  ip_address text,
  user_agent text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_audit_company_created ON public.audit_logs(company_id, created_at DESC);

CREATE TABLE public.notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  branch_id uuid REFERENCES public.branches(id) ON DELETE SET NULL,
  user_id uuid REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  required_permission text,
  type text NOT NULL,
  severity text NOT NULL DEFAULT 'info' CHECK (severity IN ('info','warning','critical')),
  title text NOT NULL,
  body text,
  data jsonb,
  read_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_notifications_company ON public.notifications(company_id, created_at DESC);

CREATE TABLE public.app_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  branch_id uuid REFERENCES public.branches(id) ON DELETE CASCADE,
  scope text NOT NULL DEFAULT 'company',
  key text NOT NULL,
  value jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX idx_app_settings_unique ON public.app_settings(company_id, COALESCE(branch_id,'00000000-0000-0000-0000-000000000000'::uuid), key);

CREATE TABLE public.payment_methods (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  key text NOT NULL,
  name text NOT NULL,
  kind text NOT NULL CHECK (kind IN ('cash','wallet','instapay','card','other')),
  requires_reference boolean NOT NULL DEFAULT false,
  requires_sender_number boolean NOT NULL DEFAULT false,
  requires_receiver_number boolean NOT NULL DEFAULT false,
  provider text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (company_id, key)
);

-- ============ TRIGGERS ============
CREATE TRIGGER t_companies_upd BEFORE UPDATE ON public.companies FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER t_branches_upd BEFORE UPDATE ON public.branches FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER t_profiles_upd BEFORE UPDATE ON public.user_profiles FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER t_roles_upd BEFORE UPDATE ON public.roles FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER t_partners_upd BEFORE UPDATE ON public.partners FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER t_settings_upd BEFORE UPDATE ON public.app_settings FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER t_pm_upd BEFORE UPDATE ON public.payment_methods FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER t_audit_no_delete BEFORE DELETE ON public.audit_logs FOR EACH ROW EXECUTE FUNCTION public.forbid_hard_delete();
CREATE TRIGGER t_pcc_no_delete BEFORE DELETE ON public.partner_capital_contributions FOR EACH ROW EXECUTE FUNCTION public.forbid_hard_delete();
CREATE TRIGGER t_plt_no_delete BEFORE DELETE ON public.partner_ledger_transactions FOR EACH ROW EXECUTE FUNCTION public.forbid_hard_delete();
CREATE TRIGGER t_pd_no_delete BEFORE DELETE ON public.profit_distributions FOR EACH ROW EXECUTE FUNCTION public.forbid_hard_delete();

-- protect closed accounting periods
CREATE OR REPLACE FUNCTION public.protect_closed_period() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF OLD.status = 'closed' AND NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Closed accounting periods cannot be modified';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER t_period_protect BEFORE UPDATE ON public.accounting_periods FOR EACH ROW EXECUTE FUNCTION public.protect_closed_period();

-- ============ GRANTS ============
GRANT SELECT, INSERT, UPDATE ON public.companies TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.branches TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.user_profiles TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.roles TO authenticated;
GRANT SELECT ON public.permissions TO authenticated;
GRANT SELECT, INSERT, DELETE ON public.role_permissions TO authenticated;
GRANT SELECT, INSERT, DELETE ON public.user_roles TO authenticated;
GRANT SELECT, INSERT, DELETE ON public.user_branches TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.partners TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.partner_capital_contributions TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.partner_ledger_transactions TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.accounting_periods TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.profit_distributions TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.profit_distribution_lines TO authenticated;
GRANT SELECT, INSERT ON public.audit_logs TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.notifications TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.app_settings TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.payment_methods TO authenticated;
GRANT SELECT ON public.partner_ownership TO authenticated;
GRANT SELECT ON public.partner_balances TO authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;

-- ============ RLS ============
ALTER TABLE public.companies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.branches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.role_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_branches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.partners ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.partner_capital_contributions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.partner_ledger_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.accounting_periods ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profit_distributions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profit_distribution_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.app_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_methods ENABLE ROW LEVEL SECURITY;

CREATE POLICY companies_select ON public.companies FOR SELECT TO authenticated USING (id = public.current_company_id());
CREATE POLICY companies_update ON public.companies FOR UPDATE TO authenticated USING (id = public.current_company_id() AND public.has_permission('settings.manage')) WITH CHECK (id = public.current_company_id());

CREATE POLICY branches_select ON public.branches FOR SELECT TO authenticated USING (company_id = public.current_company_id());
CREATE POLICY branches_write ON public.branches FOR INSERT TO authenticated WITH CHECK (company_id = public.current_company_id() AND public.has_permission('settings.manage'));
CREATE POLICY branches_update ON public.branches FOR UPDATE TO authenticated USING (company_id = public.current_company_id() AND public.has_permission('settings.manage')) WITH CHECK (company_id = public.current_company_id());

CREATE POLICY profiles_select_self ON public.user_profiles FOR SELECT TO authenticated USING (auth_user_id = auth.uid());
CREATE POLICY profiles_select_perm ON public.user_profiles FOR SELECT TO authenticated USING (company_id = public.current_company_id() AND public.has_permission('users.view'));
CREATE POLICY profiles_insert ON public.user_profiles FOR INSERT TO authenticated WITH CHECK (company_id = public.current_company_id() AND public.has_permission('users.create'));
CREATE POLICY profiles_update_self ON public.user_profiles FOR UPDATE TO authenticated USING (auth_user_id = auth.uid()) WITH CHECK (auth_user_id = auth.uid());
CREATE POLICY profiles_update_perm ON public.user_profiles FOR UPDATE TO authenticated USING (company_id = public.current_company_id() AND public.has_permission('users.update')) WITH CHECK (company_id = public.current_company_id());

CREATE POLICY permissions_select ON public.permissions FOR SELECT TO authenticated USING (true);

CREATE POLICY roles_select ON public.roles FOR SELECT TO authenticated USING (company_id = public.current_company_id());
CREATE POLICY roles_insert ON public.roles FOR INSERT TO authenticated WITH CHECK (company_id = public.current_company_id() AND public.has_permission('users.manage_roles'));
CREATE POLICY roles_update ON public.roles FOR UPDATE TO authenticated USING (company_id = public.current_company_id() AND public.has_permission('users.manage_roles') AND NOT is_system_role) WITH CHECK (company_id = public.current_company_id());
CREATE POLICY roles_delete ON public.roles FOR DELETE TO authenticated USING (company_id = public.current_company_id() AND public.is_super_admin() AND NOT is_system_role);

CREATE POLICY rp_select ON public.role_permissions FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.roles r WHERE r.id = role_id AND r.company_id = public.current_company_id()));
CREATE POLICY rp_insert ON public.role_permissions FOR INSERT TO authenticated WITH CHECK (public.has_permission('users.manage_roles') AND EXISTS (SELECT 1 FROM public.roles r WHERE r.id = role_id AND r.company_id = public.current_company_id() AND (NOT r.is_system_role OR public.is_super_admin())));
CREATE POLICY rp_delete ON public.role_permissions FOR DELETE TO authenticated USING (public.has_permission('users.manage_roles') AND EXISTS (SELECT 1 FROM public.roles r WHERE r.id = role_id AND r.company_id = public.current_company_id() AND (NOT r.is_system_role OR public.is_super_admin())));

CREATE POLICY ur_select_self ON public.user_roles FOR SELECT TO authenticated USING (user_id = public.current_profile_id());
CREATE POLICY ur_select_perm ON public.user_roles FOR SELECT TO authenticated USING (public.has_permission('users.view') AND EXISTS (SELECT 1 FROM public.user_profiles up WHERE up.id = user_id AND up.company_id = public.current_company_id()));
CREATE POLICY ur_insert ON public.user_roles FOR INSERT TO authenticated WITH CHECK (public.has_permission('users.manage_roles') AND EXISTS (SELECT 1 FROM public.user_profiles up WHERE up.id = user_id AND up.company_id = public.current_company_id()));
CREATE POLICY ur_delete ON public.user_roles FOR DELETE TO authenticated USING (public.has_permission('users.manage_roles') AND EXISTS (SELECT 1 FROM public.user_profiles up WHERE up.id = user_id AND up.company_id = public.current_company_id()));

CREATE POLICY ub_select_self ON public.user_branches FOR SELECT TO authenticated USING (user_id = public.current_profile_id());
CREATE POLICY ub_select_perm ON public.user_branches FOR SELECT TO authenticated USING (public.has_permission('users.view') AND EXISTS (SELECT 1 FROM public.user_profiles up WHERE up.id = user_id AND up.company_id = public.current_company_id()));
CREATE POLICY ub_insert ON public.user_branches FOR INSERT TO authenticated WITH CHECK (public.has_permission('users.manage_roles') AND EXISTS (SELECT 1 FROM public.user_profiles up WHERE up.id = user_id AND up.company_id = public.current_company_id()));
CREATE POLICY ub_delete ON public.user_branches FOR DELETE TO authenticated USING (public.has_permission('users.manage_roles') AND EXISTS (SELECT 1 FROM public.user_profiles up WHERE up.id = user_id AND up.company_id = public.current_company_id()));

CREATE POLICY partners_select ON public.partners FOR SELECT TO authenticated USING (company_id = public.current_company_id() AND (public.has_permission('partners.view') OR user_id = public.current_profile_id()));
CREATE POLICY partners_insert ON public.partners FOR INSERT TO authenticated WITH CHECK (company_id = public.current_company_id() AND public.has_permission('partners.manage'));
CREATE POLICY partners_update ON public.partners FOR UPDATE TO authenticated USING (company_id = public.current_company_id() AND public.has_permission('partners.manage')) WITH CHECK (company_id = public.current_company_id());

CREATE POLICY pcc_select ON public.partner_capital_contributions FOR SELECT TO authenticated USING (company_id = public.current_company_id() AND (public.has_permission('partners.view_profit') OR partner_id = public.current_partner_id()));
CREATE POLICY pcc_insert ON public.partner_capital_contributions FOR INSERT TO authenticated WITH CHECK (company_id = public.current_company_id() AND public.has_permission('partners.manage'));
CREATE POLICY pcc_update ON public.partner_capital_contributions FOR UPDATE TO authenticated USING (company_id = public.current_company_id() AND public.has_permission('partners.manage')) WITH CHECK (company_id = public.current_company_id());

CREATE POLICY plt_select ON public.partner_ledger_transactions FOR SELECT TO authenticated USING (company_id = public.current_company_id() AND (public.has_permission('partners.view_profit') OR partner_id = public.current_partner_id()));
CREATE POLICY plt_insert ON public.partner_ledger_transactions FOR INSERT TO authenticated WITH CHECK (company_id = public.current_company_id() AND (public.has_permission('partners.manage_profit_distribution') OR public.has_permission('partners.manage_withdrawals')));
CREATE POLICY plt_update ON public.partner_ledger_transactions FOR UPDATE TO authenticated USING (company_id = public.current_company_id() AND public.has_permission('partners.manage_profit_distribution')) WITH CHECK (company_id = public.current_company_id());

CREATE POLICY ap_select ON public.accounting_periods FOR SELECT TO authenticated USING (company_id = public.current_company_id() AND (public.has_permission('reports.profit') OR public.has_permission('settings.view')));
CREATE POLICY ap_insert ON public.accounting_periods FOR INSERT TO authenticated WITH CHECK (company_id = public.current_company_id() AND public.has_permission('settings.manage'));
CREATE POLICY ap_update ON public.accounting_periods FOR UPDATE TO authenticated USING (company_id = public.current_company_id() AND public.has_permission('settings.manage')) WITH CHECK (company_id = public.current_company_id());

CREATE POLICY pd_select ON public.profit_distributions FOR SELECT TO authenticated USING (company_id = public.current_company_id() AND public.has_permission('partners.view_profit'));
CREATE POLICY pd_insert ON public.profit_distributions FOR INSERT TO authenticated WITH CHECK (company_id = public.current_company_id() AND public.has_permission('partners.manage_profit_distribution'));
CREATE POLICY pd_update ON public.profit_distributions FOR UPDATE TO authenticated USING (company_id = public.current_company_id() AND public.has_permission('partners.manage_profit_distribution')) WITH CHECK (company_id = public.current_company_id());

CREATE POLICY pdl_select ON public.profit_distribution_lines FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.profit_distributions d WHERE d.id = distribution_id AND d.company_id = public.current_company_id() AND (public.has_permission('partners.view_profit') OR partner_id = public.current_partner_id())));
CREATE POLICY pdl_insert ON public.profit_distribution_lines FOR INSERT TO authenticated WITH CHECK (public.has_permission('partners.manage_profit_distribution') AND EXISTS (SELECT 1 FROM public.profit_distributions d WHERE d.id = distribution_id AND d.company_id = public.current_company_id()));
CREATE POLICY pdl_update ON public.profit_distribution_lines FOR UPDATE TO authenticated USING (public.has_permission('partners.manage_profit_distribution')) WITH CHECK (true);

CREATE POLICY audit_select ON public.audit_logs FOR SELECT TO authenticated USING (company_id = public.current_company_id() AND public.has_permission('audit.view'));
CREATE POLICY audit_insert ON public.audit_logs FOR INSERT TO authenticated WITH CHECK (company_id = public.current_company_id() AND user_id = public.current_profile_id());

CREATE POLICY notif_select ON public.notifications FOR SELECT TO authenticated USING (company_id = public.current_company_id() AND (user_id = public.current_profile_id() OR (user_id IS NULL AND (required_permission IS NULL OR public.has_permission(required_permission)))));
CREATE POLICY notif_insert ON public.notifications FOR INSERT TO authenticated WITH CHECK (company_id = public.current_company_id());
CREATE POLICY notif_update ON public.notifications FOR UPDATE TO authenticated USING (company_id = public.current_company_id() AND (user_id = public.current_profile_id() OR public.is_super_admin())) WITH CHECK (company_id = public.current_company_id());

CREATE POLICY settings_select ON public.app_settings FOR SELECT TO authenticated USING (company_id = public.current_company_id() AND public.has_permission('settings.view'));
CREATE POLICY settings_write ON public.app_settings FOR ALL TO authenticated USING (company_id = public.current_company_id() AND public.has_permission('settings.manage')) WITH CHECK (company_id = public.current_company_id() AND public.has_permission('settings.manage'));

CREATE POLICY pm_select ON public.payment_methods FOR SELECT TO authenticated USING (company_id = public.current_company_id());
CREATE POLICY pm_write ON public.payment_methods FOR ALL TO authenticated USING (company_id = public.current_company_id() AND public.has_permission('settings.manage')) WITH CHECK (company_id = public.current_company_id() AND public.has_permission('settings.manage'));
