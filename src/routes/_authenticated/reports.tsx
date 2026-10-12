import { createFileRoute } from "@tanstack/react-router";
import { ReportsPage } from "@/modules/finance/ReportsPage";

export const Route = createFileRoute("/_authenticated/reports")({
  head: () => ({
    meta: [
      { title: "Reports — 20s Coffee" },
      {
        name: "description",
        content: "Sales, product, cashier, expense and inventory reports for 20s Coffee branches.",
      },
      { property: "og:title", content: "Reports — 20s Coffee" },
      {
        property: "og:description",
        content: "Daily sales, best sellers, cashier performance and costs.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: ReportsPage,
});
