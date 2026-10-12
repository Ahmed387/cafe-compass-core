import type { ReactNode } from "react";

import { useAuth } from "@/lib/auth";

/**
 * Declarative replacement for inline `{can("x") && ...}` checks.
 * `permission` accepts one key or a list; `mode` decides how a list is combined.
 */
export function PermissionGate({
  permission,
  mode = "any",
  superAdminOnly = false,
  fallback = null,
  children,
}: {
  permission?: string | string[] | undefined;
  mode?: "any" | "all";
  superAdminOnly?: boolean;
  fallback?: ReactNode;
  children: ReactNode;
}) {
  const { can, me } = useAuth();
  const isSuperAdmin = me?.roleNames.includes("Super Admin") ?? false;

  if (superAdminOnly && !isSuperAdmin) return <>{fallback}</>;

  const keys = permission == null ? [] : Array.isArray(permission) ? permission : [permission];
  if (keys.length > 0) {
    const allowed = mode === "all" ? keys.every((key) => can(key)) : keys.some((key) => can(key));
    if (!allowed) return <>{fallback}</>;
  }

  return <>{children}</>;
}
