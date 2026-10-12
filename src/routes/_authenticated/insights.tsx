import { createFileRoute } from "@tanstack/react-router";

import { AnalyticsPage } from "@/modules/finance/AnalyticsPage";
import { ReportsPage } from "@/modules/finance/ReportsPage";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { useI18n } from "@/lib/i18n";

export const Route = createFileRoute("/_authenticated/insights")({
  head: () => ({
    meta: [
      { title: "Reports & insights — 20s Coffee" },
      {
        name: "description",
        content:
          "Sales reports, product demand, margins and marketing plans for 20s Coffee products.",
      },
      { property: "og:title", content: "Reports & insights — 20s Coffee" },
      {
        property: "og:description",
        content: "Daily sales, best sellers, cashier performance and product activation plans.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: InsightsHub,
});

function InsightsHub() {
  const { t } = useI18n();
  return (
    <Tabs defaultValue="reports" className="animate-fade-in">
      <TabsList>
        <TabsTrigger value="reports">{t("ins.tab.reports")}</TabsTrigger>
        <TabsTrigger value="analytics">{t("ins.tab.analytics")}</TabsTrigger>
      </TabsList>
      <TabsContent value="reports" className="mt-4">
        <ReportsPage />
      </TabsContent>
      <TabsContent value="analytics" className="mt-4">
        <AnalyticsPage />
      </TabsContent>
    </Tabs>
  );
}
