import { createFileRoute } from "@tanstack/react-router";

import { FinancePage } from "@/modules/finance/FinancePage";
import { PageHeader } from "@/components/layout/AppShell";
import { useI18n } from "@/lib/i18n";

export const Route = createFileRoute("/_authenticated/expenses")({
  head: () => ({
    meta: [
      { title: "Operating expenses — 20s Coffee" },
      {
        name: "description",
        content: "Record and review day-to-day operating expenses, petty cash, supplies and bills.",
      },
      { property: "og:title", content: "Operating expenses — 20s Coffee" },
      {
        property: "og:description",
        content: "Day-to-day operating costs for 20s Coffee branches.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: ExpensesRoute,
});

function ExpensesRoute() {
  const { t } = useI18n();
  return (
    <div className="animate-fade-in">
      <PageHeader title={t("nav.expenses")} description={t("expenses.subtitle")} />
      <FinancePage sections={["expenses"]} bare />
    </div>
  );
}
