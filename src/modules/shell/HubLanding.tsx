import { useRouter } from "@tanstack/react-router";
import { useEffect } from "react";

import { useI18n } from "@/lib/i18n";

import type { Hub } from "./hubs";
import { useHubAccess } from "./use-hub-access";

/** A hub URL opens the first tab the signed-in user is allowed to see. */
export function HubLanding({ hubId }: { hubId: Hub["id"] }) {
  const { t } = useI18n();
  const router = useRouter();
  const { hubs, ready } = useHubAccess();

  useEffect(() => {
    if (!ready) return;
    const first = hubs.find((h) => h.id === hubId)?.tabs[0]?.to ?? hubs[0]?.tabs[0]?.to ?? "/auth";
    router.navigate({ to: first, replace: true });
  }, [hubId, hubs, ready, router]);

  return <p className="p-6 text-sm text-muted-foreground">{t("common.loading")}</p>;
}
