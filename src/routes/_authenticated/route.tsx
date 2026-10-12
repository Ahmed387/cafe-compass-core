import { createFileRoute, Outlet, redirect, useRouter } from "@tanstack/react-router";
import { useEffect, useMemo } from "react";

import { AppShell } from "@/components/layout/AppShell";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { useI18n } from "@/lib/i18n";
import { landingRouteFor, personalAccess, routeAccessFor } from "@/lib/nav-access";
import { hubForPath } from "@/modules/shell/hubs";

export const Route = createFileRoute("/_authenticated")({
  ssr: false,
  beforeLoad: async () => {
    const { data, error } = await supabase.auth.getUser();
    if (error || !data.user) throw redirect({ to: "/auth" });
    return { user: data.user };
  },
  component: AuthenticatedLayout,
});

function AuthenticatedLayout() {
  const { me, meLoading } = useAuth();
  const { t } = useI18n();
  const router = useRouter();
  const pathname = router.state.location.pathname;
  const access = useMemo(() => routeAccessFor(me?.roleNames), [me?.roleNames]);
  const blocked =
    Boolean(me) &&
    pathname !== "/dashboard" &&
    !personalAccess(me!, access, pathname, hubForPath(pathname)?.path);

  // A role that cannot open this page is sent to its own home screen.
  useEffect(() => {
    if (!blocked) return;
    router.navigate({ to: landingRouteFor(access, pathname), replace: true });
  }, [blocked, access, pathname, router]);

  useEffect(() => {
    if (!me || me.profile.is_active) return;
    window.sessionStorage.setItem("csm.disabled-account", "1");
    void supabase.auth.signOut().finally(() => router.navigate({ to: "/auth", replace: true }));
  }, [me, router]);


  if ((meLoading && !me) || blocked) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-background">
        <p className="text-sm text-muted-foreground">{t("common.loading")}</p>
      </div>
    );
  }

  if (me && !me.profile.is_active) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-background px-4 text-center">
        <p className="max-w-sm text-sm text-muted-foreground">
          {t("common.inactive")} — {t("common.noAccess")}
        </p>
      </div>
    );
  }

  return (
    <AppShell>
      <Outlet />
    </AppShell>
  );
}

