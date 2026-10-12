import { Link, useRouterState } from "@tanstack/react-router";

import { useI18n } from "@/lib/i18n";

import { hubForPath, isTabActive } from "./hubs";
import { useHubAccess } from "./use-hub-access";

/** Sub-tab bar for the hub that owns the current page. Client-side links only. */
export function HubTabs() {
  const { t } = useI18n();
  const pathname = useRouterState({ select: (s) => s.location.pathname });
  const { hubs } = useHubAccess();
  const owner = hubForPath(pathname);
  const hub = owner ? hubs.find((h) => h.id === owner.id) : undefined;
  if (!hub || hub.tabs.length < 2) return null;

  return (
    <nav
      aria-label={t(hub.labelKey)}
      className="scrollbar-thin mb-5 flex animate-fade-in gap-1 overflow-x-auto rounded-2xl border bg-card p-1.5 shadow-sm"
    >
      {hub.tabs.map((tab) => {
        const Icon = tab.icon;
        const active = isTabActive(pathname, tab);
        return (
          <Link
            key={tab.to}
            to={tab.to}
            className={`group inline-flex min-h-11 shrink-0 items-center gap-2 rounded-xl px-3.5 py-2 text-sm font-semibold transition-all duration-300 ${
              active
                ? "bg-gradient-module text-white shadow-glow"
                : "text-muted-foreground hover:bg-tint hover:text-foreground"
            }`}
          >
            <Icon
              className={`size-4 transition-transform duration-300 ${active ? "scale-110" : "group-hover:-translate-y-0.5 group-hover:scale-110"}`}
            />
            {t(tab.labelKey)}
          </Link>
        );
      })}
    </nav>
  );
}
