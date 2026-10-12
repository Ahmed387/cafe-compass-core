import { createFileRoute } from "@tanstack/react-router";

import { MoneyHub } from "@/modules/finance/MoneyHub";

export const Route = createFileRoute("/_authenticated/money")({
  head: () => ({
    meta: [
      { title: "Treasury & payroll — 20s Coffee" },
      {
        name: "description",
        content: "Master safe ledger, staff payroll and partner profit distribution for 20s Coffee.",
      },
      { property: "og:title", content: "Treasury & payroll — 20s Coffee" },
      {
        property: "og:description",
        content: "Cash balances, salaries and partner dividends in one restricted place.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: MoneyHub,
});
