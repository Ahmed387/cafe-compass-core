import { createFileRoute } from "@tanstack/react-router";

import { PageHeader } from "@/components/layout/AppShell";
import { FinancePage } from "@/modules/finance/FinancePage";
import { useI18n } from "@/lib/i18n";

export const Route = createFileRoute("/_authenticated/pnl")({
  head: () => ({
    meta: [
      { title: "Profit & loss — 20s Coffee" },
      { name: "description", content: "Period revenue, cost of goods, operating expenses, salaries and net profit for 20s Coffee." },
      { property: "og:title", content: "Profit & loss — 20s Coffee" },
      { property: "og:description", content: "A clear period profit and loss statement for 20s Coffee." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: ProfitAndLossRoute,
});

function ProfitAndLossRoute() {
  const { lang } = useI18n();
  return (
    <div className="animate-fade-in">
      <PageHeader
        title={lang === "ar" ? "قائمة الدخل والأرباح والخسائر" : "Profit & loss statement"}
        description={lang === "ar" ? "الإيرادات والتكلفة والمصروفات والرواتب وصافي نتيجة كل فترة." : "Revenue, COGS, operating expenses, salaries, and the final result for each period."}
      />
      <FinancePage sections={["profit"]} bare />
    </div>
  );
}