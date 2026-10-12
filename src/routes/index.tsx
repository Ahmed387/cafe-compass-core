import { createFileRoute, useRouter } from "@tanstack/react-router";
import { Coffee } from "lucide-react";
import { useEffect } from "react";

import { useAuth } from "@/lib/auth";
import { useI18n } from "@/lib/i18n";

export const Route = createFileRoute("/")({
  ssr: false,
  head: () => ({
    meta: [
      { title: "20s Coffee — Sign in" },
      {
        name: "description",
        content:
          "Sign in to manage your coffee shop: staff, roles, branches, partners and financial periods.",
      },
      { property: "og:title", content: "20s Coffee" },
      {
        property: "og:description",
        content: "Operations, finance and partners for your coffee shop in one place.",
      },
    ],
  }),
  component: Index,
});

function Index() {
  const { session, sessionLoaded } = useAuth();
  const { t } = useI18n();
  const router = useRouter();

  useEffect(() => {
    if (!sessionLoaded) return;
    router.navigate({ to: session ? "/dashboard" : "/auth", replace: true });
  }, [session, sessionLoaded, router]);

  return (
    <div className="flex min-h-screen flex-col items-center justify-center gap-3 bg-background">
      <Coffee className="size-8 text-primary" />
      <p className="text-sm text-muted-foreground">{t("common.loading")}</p>
    </div>
  );
}
