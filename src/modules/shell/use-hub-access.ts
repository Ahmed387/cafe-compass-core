import { useMemo } from "react";

import { useAuth } from "@/lib/auth";
import { personalAccess, routeAccessFor } from "@/lib/nav-access";

import { HUBS, type Hub, type HubTab } from "./hubs";

/** Hubs and tabs filtered by role route-map, partner tier, overrides and permissions (single rule for sidebar + tabs). */
export function useHubAccess() {
  const { me, can } = useAuth();
  const access = useMemo(() => routeAccessFor(me?.roleNames), [me?.roleNames]);
  const isSuperAdmin = me?.roleNames.includes("Super Admin") ?? false;
  const isPartner = me?.roleNames.includes("Partner") ?? false;

  return useMemo(() => {
    const allowedTab = (hub: Hub) => (tab: HubTab) => {
      if (!me) return false;
      if (me.navOverrides[tab.to] === true) return true;
      return (
        personalAccess(me, access, tab.to, hub.path) &&
        (access.governed || !tab.permission || can(tab.permission) || (tab.anyPermission ?? []).some(can) || (tab.partnerVisible && isPartner)) &&
        (!tab.superAdminOnly || isSuperAdmin)
      );
    };
    const hubs: Hub[] = HUBS.map((hub) => ({ ...hub, tabs: hub.tabs.filter(allowedTab(hub)) })).filter(
      (hub) => hub.tabs.length > 0,
    );
    return { hubs, ready: Boolean(me) };
  }, [access, can, isPartner, isSuperAdmin, me]);
}
