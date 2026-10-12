import { createFileRoute } from "@tanstack/react-router";

import { PurchasesPage } from "@/modules/supply/PurchasesPage";
import { SuppliersPage } from "@/modules/supply/SuppliersPage";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { useI18n } from "@/lib/i18n";

export const Route = createFileRoute("/_authenticated/purchases")({
  head: () => ({
    meta: [
      { title: "Purchases & suppliers — 20s Coffee" },
      {
        name: "description",
        content:
          "Record supplier invoices, returns and payments, and review each supplier balance for 20s Coffee.",
      },
      { property: "og:title", content: "Purchases & suppliers — 20s Coffee" },
      {
        property: "og:description",
        content: "Procurement invoices and per-supplier ledger in one place.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: PurchasesHub,
});

function PurchasesHub() {
  const { t } = useI18n();
  return (
    <Tabs defaultValue="purchases" className="animate-fade-in">
      <TabsList>
        <TabsTrigger value="purchases">{t("nav.purchases")}</TabsTrigger>
        <TabsTrigger value="suppliers">{t("nav.suppliers")}</TabsTrigger>
      </TabsList>
      <TabsContent value="purchases" className="mt-4">
        <PurchasesPage />
      </TabsContent>
      <TabsContent value="suppliers" className="mt-4">
        <SuppliersPage />
      </TabsContent>
    </Tabs>
  );
}
