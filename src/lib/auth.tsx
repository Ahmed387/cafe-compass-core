import { useQuery, useQueryClient } from "@tanstack/react-query";
import type { Session } from "@supabase/supabase-js";
import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from "react";

import { supabase } from "@/integrations/supabase/client";

export type Company = {
  id: string;
  name: string;
  currency: string;
  timezone: string;
  default_language: "ar" | "en";
  tax_enabled: boolean;
  tax_rate: number;
  logo_url: string | null;
  legal_name: string | null;
};

export type Branch = { id: string; name: string; code: string; is_active: boolean };

export type Me = {
  profile: {
    id: string;
    first_name: string;
    last_name: string | null;
    display_name: string | null;
    email: string;
    is_active: boolean;
    company_id: string;
    preferred_language: "ar" | "en";
  };
  company: Company | null;
  roleNames: string[];
  permissions: string[];
  branches: Branch[];
  /** Permanent owner account; enforced again in the database. */
  isRoot: boolean;
  partnerTier: PartnerTier | null;
  /** Per-user hub/tab visibility set by a Super Admin (path → visible). */
  navOverrides: Record<string, boolean>;
};

export type PartnerTier = "silent" | "manager" | "manager_employee";
export { ROOT_ADMIN_EMAIL } from "@/lib/root-admin";
import { ROOT_ADMIN_EMAIL } from "@/lib/root-admin";

type AuthValue = {
  session: Session | null;
  sessionLoaded: boolean;
  me: Me | null;
  meLoading: boolean;
  can: (permission: string) => boolean;
  currentBranchId: string | null;
  setCurrentBranchId: (id: string | null) => void;
  signOut: () => Promise<void>;
};

const AuthContext = createContext<AuthValue | null>(null);

async function loadMe(): Promise<Me | null> {
  // Links the signed-in account to a company profile on first login.
  await supabase.rpc("bootstrap_current_user", {});

  const { data: authData } = await supabase.auth.getUser();
  const authUserId = authData.user?.id;
  if (!authUserId) return null;

  const { data: profile, error } = await supabase
    .from("user_profiles")
    .select(
      "id, first_name, last_name, display_name, email, is_active, company_id, preferred_language",
    )
    .eq("auth_user_id", authUserId)
    .maybeSingle();
  if (error) throw error;
  if (!profile) return null;

  const [{ data: company }, { data: roles }, { data: userBranches }] = await Promise.all([
    supabase
      .from("companies")
      .select(
        "id, name, currency, timezone, default_language, tax_enabled, tax_rate, logo_url, legal_name",
      )
      .eq("id", profile.company_id)
      .maybeSingle(),
    supabase
      .from("user_roles")
      .select("role_id, branch_id, roles(name, key, role_permissions(permissions(key)))")
      .eq("user_id", profile.id),
    supabase
      .from("user_branches")
      .select("branch_id, branches(id, name, code, is_active)")
      .eq("user_id", profile.id),
  ]);

  const roleNames: string[] = [];
  const permissions = new Set<string>();
  type RoleRow = {
    roles: {
      name: string;
      key: string | null;
      role_permissions: Array<{ permissions: { key: string } | null }> | null;
    } | null;
  };
  for (const row of (roles ?? []) as unknown as RoleRow[]) {
    if (!row.roles) continue;
    if (!roleNames.includes(row.roles.name)) roleNames.push(row.roles.name);
    for (const rp of row.roles.role_permissions ?? []) {
      if (rp.permissions?.key) permissions.add(rp.permissions.key);
    }
  }

  type BranchRow = { branches: Branch | null };
  let branches = ((userBranches ?? []) as unknown as BranchRow[])
    .map((row) => row.branches)
    .filter((b): b is Branch => Boolean(b));

  if (branches.length === 0) {
    const { data: all } = await supabase
      .from("branches")
      .select("id, name, code, is_active")
      .order("created_at");
    branches = (all ?? []) as Branch[];
  }

  const [{ data: partnerRow }, { data: overrides }] = await Promise.all([
    supabase
      .from("partners")
      .select("tier")
      .eq("user_id", profile.id)
      .eq("status", "active")
      .maybeSingle(),
    supabase.from("user_nav_overrides").select("path, visible").eq("profile_id", profile.id),
  ]);

  return {
    profile: profile as Me["profile"],
    company: (company ?? null) as Company | null,
    roleNames,
    permissions: [...permissions],
    branches,
    isRoot: profile.email?.toLowerCase() === ROOT_ADMIN_EMAIL,
    partnerTier: (partnerRow?.tier ?? null) as PartnerTier | null,
    navOverrides: Object.fromEntries((overrides ?? []).map((o) => [o.path, o.visible])),
  };
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const queryClient = useQueryClient();
  const [session, setSession] = useState<Session | null>(null);
  const [sessionLoaded, setSessionLoaded] = useState(false);
  const [currentBranchId, setCurrentBranchId] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    supabase.auth.getSession().then(({ data }) => {
      if (!active) return;
      setSession(data.session);
      setSessionLoaded(true);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((event, next) => {
      setSession(next);
      setSessionLoaded(true);
      if (event === "SIGNED_OUT") queryClient.removeQueries({ queryKey: ["me"] });
    });
    return () => {
      active = false;
      sub.subscription.unsubscribe();
    };
  }, [queryClient]);

  const { data: me, isLoading: meLoading } = useQuery({
    queryKey: ["me", session?.user.id ?? null],
    queryFn: loadMe,
    enabled: Boolean(session),
    staleTime: 60_000,
  });

  useEffect(() => {
    if (!me) return;
    setCurrentBranchId((prev) => prev ?? me.branches[0]?.id ?? null);
  }, [me]);

  const value = useMemo<AuthValue>(
    () => ({
      session,
      sessionLoaded,
      me: me ?? null,
      meLoading,
      can: (permission: string) => Boolean(me?.permissions.includes(permission)),
      currentBranchId,
      setCurrentBranchId,
      signOut: async () => {
        await queryClient.cancelQueries();
        await supabase.rpc("log_audit", {
          _action: "auth.logout",
          _module: "auth",
        });
        queryClient.clear();
        await supabase.auth.signOut();
      },
    }),
    [session, sessionLoaded, me, meLoading, currentBranchId, queryClient],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth() {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth must be used inside AuthProvider");
  return ctx;
}
