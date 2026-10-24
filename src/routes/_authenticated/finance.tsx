import { createFileRoute } from "@tanstack/react-router";

import { FinanceKpiStrip } from "@/modules/finance/FinanceKpiStrip";
import { ManagerSalaryPanel } from "@/modules/finance/ManagerSalaryPanel";
import { PartnerTabsDueCard } from "@/modules/finance/PartnerTabsDueCard";
import { HubLanding } from "@/modules/shell/HubLanding";

export const Route = createFileRoute("/_authenticated/finance")({
  head: () => ({
    meta: [
      { title: "Finance hub — 20s Coffee" },
      { name: "description", content: "Treasury, operating expenses, periods and profit reports for 20s Coffee." },
      { property: "og:title", content: "Finance hub — 20s Coffee" },
      { property: "og:description", content: "Treasury, operating expenses, periods and profit reports for 20s Coffee." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: FinancehubLanding,
});

function FinancehubLanding() {
  return (
    <>
      <div className="mx-auto max-w-6xl px-4 pt-4">
        <FinanceKpiStrip />
        <ManagerSalaryPanel />
        <PartnerTabsDueCard />
      </div>
      <HubLanding hubId="finance" />
    </>
  );
}
