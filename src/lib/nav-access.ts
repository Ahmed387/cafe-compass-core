/**
 * Central declarative route access map (strict RBAC).
 *
 * Keys are role names exactly as stored in `roles.name`.
 * Values are route path prefixes the role may reach; "*" means unlimited.
 * A user holding several roles gets the union of their roles' paths.
 * Roles that are not listed here fall back to permission-driven visibility,
 * so custom roles created later are never accidentally locked out.
 */
export const NAV_PERMISSIONS: Record<string, string[] | ["*"]> = {
  "Super Admin": ["*"],

  // Cashier: operational POS and own shift drawer only.
  Cashier: ["/operations", "/pos", "/orders", "/shifts", "/qr"],

  // Manager: operational floor, catalog, inventory, purchases, staff and reports.
  Manager: [
    "/operations",
    "/supply",
    "/finance",
    "/menu-studio",
    "/governance",
    "/pos",
    "/orders",
    "/shifts",
    "/refunds",
    "/menu-studio",
    "/inventory",
    "/warehouse",
    "/recipes",
    "/stocktake",
    "/purchases",
    "/returns",
    "/offers",
    "/addons",
    "/qr",
    "/loyalty",
    "/expenses",
    "/pnl",
    "/reports",
    "/insights",
    "/analytics",
    "/users",
    "/staff",
    "/hr",
    "/guide",
  ],

  // Partner: financial performance, P&L, partner tabs and profit payouts.
  Partner: [
    "/governance",
    "/dashboard",
    "/orders",
    "/shifts",
    "/expenses",
    "/money",
    "/finance",
    "/treasury",
    "/partners",
    "/partner-tabs",
    "/hr",
    "/pnl",
    "/reports",
    "/insights",
    "/analytics",
    "/audit",
    "/qr",
    "/guide",
  ],
};

export type RouteAccess = { unlimited: boolean; paths: string[]; governed: boolean };

export function routeAccessFor(roleNames: string[] | undefined): RouteAccess {
  // A signed-in account with no role at all (e.g. floor staff kept only for
  // attendance) may open nothing but its own home screen.
  if (!roleNames || roleNames.length === 0) return { unlimited: false, paths: [], governed: true };
  const known = (roleNames ?? []).filter((role) => role in NAV_PERMISSIONS);
  if (known.length === 0) return { unlimited: true, paths: [], governed: false };
  if (known.some((role) => NAV_PERMISSIONS[role]?.[0] === "*")) {
    return { unlimited: true, paths: [], governed: true };
  }
  const paths = new Set<string>();
  for (const role of known) for (const path of NAV_PERMISSIONS[role] ?? []) paths.add(path);
  return { unlimited: false, paths: [...paths], governed: true };
}

/** Prefix match so detail routes (/orders/123, /staff/abc) follow their parent. */
export function canAccessRoute(access: RouteAccess, path: string): boolean {
  if (access.unlimited) return true;
  return access.paths.some((allowed) => path === allowed || path.startsWith(`${allowed}/`));
}

/** Where to send a user who lands on a page their roles cannot open. */
export function landingRouteFor(access: RouteAccess, blockedPath?: string): string {
  if (access.unlimited) return "/dashboard";
  // Sensitive financial screens fall back to plain operating expenses when allowed.
  const sensitive = ["/money", "/treasury"];
  if (
    blockedPath &&
    sensitive.some((p) => blockedPath === p || blockedPath.startsWith(`${p}/`)) &&
    access.paths.includes("/expenses")
  ) {
    return "/expenses";
  }
  if (access.paths.includes("/pos")) return "/pos";
  return access.paths[0] ?? "/dashboard";
}

/** Pages partners never reach by tier (unless also Super Admin). Data is guarded again in the database. */
const TIER_BLOCKED: Record<string, string[]> = {
  silent: ["/hr", "/staff", "/users", "/money", "/treasury", "/finance", "/expenses", "/audit"],
  manager: ["/hr", "/staff", "/users", "/money", "/treasury", "/finance", "/expenses", "/audit"],
  manager_employee: ["/money", "/treasury", "/finance", "/expenses", "/audit"],
};

const under = (path: string, prefix: string) => path === prefix || path.startsWith(`${prefix}/`);

type PersonalMe = {
  roleNames: string[];
  partnerTier: string | null;
  navOverrides: Record<string, boolean>;
};

/**
 * Final access decision for one user: Super Admin overrides win first,
 * then the partner tier, then the role map.
 * `hubPath` lets a hub-level override hide or show every tab in it.
 */
export function personalAccess(
  me: PersonalMe,
  access: RouteAccess,
  path: string,
  hubPath?: string,
): boolean {
  const overrideKey = Object.keys(me.navOverrides)
    .filter((key) => under(path, key))
    .sort((a, b) => b.length - a.length)[0];
  if (overrideKey !== undefined) return me.navOverrides[overrideKey] === true;
  if (hubPath && me.navOverrides[hubPath] === false) return false;
  const isSuper = me.roleNames.includes("Super Admin");
  if (
    !isSuper &&
    me.partnerTier &&
    (TIER_BLOCKED[me.partnerTier] ?? []).some((p) => under(path, p))
  ) {
    return false;
  }
  return canAccessRoute(access, path);
}
