import { createFileRoute } from "@tanstack/react-router";

import { PurchasesPage } from "@/modules/supply/PurchasesPage";
import { SuppliersPage } from "@/modules/supply/SuppliersPage";
import { SupplierReturnsLog } from "@/modules/supply/SupplierReturnsLog";
import { z } from "zod";
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
  validateSearch: (search) =>
    z.object({ tab: z.enum(["purchases", "suppliers", "returns"]).optional() }).parse(search),
  component: PurchasesHub,
});

function PurchasesHub() {
  const { t, lang } = useI18n();
  const { tab } = Route.useSearch();
  const navigate = Route.useNavigate();
  return (
    <Tabs
      value={tab ?? "purchases"}
      onValueChange={(v) => navigate({ search: { tab: v as "purchases" }, replace: true })}
      className="animate-fade-in"
    >
      <TabsList>
        <TabsTrigger value="purchases">{t("nav.purchases")}</TabsTrigger>
        <TabsTrigger value="suppliers">{t("nav.suppliers")}</TabsTrigger>
        <TabsTrigger value="returns">
          {lang === "ar" ? "مرتجعات الموردين" : "Supplier returns"}
        </TabsTrigger>
      </TabsList>
      <TabsContent value="purchases" className="mt-4">
        <PurchasesPage />
      </TabsContent>
      <TabsContent value="suppliers" className="mt-4">
        <SuppliersPage />
      </TabsContent>
      <TabsContent value="returns" className="mt-4">
        <SupplierReturnsLog />
      </TabsContent>
    </Tabs>
  );
}
