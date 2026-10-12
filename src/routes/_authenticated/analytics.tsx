import { createFileRoute } from "@tanstack/react-router";
import { AnalyticsPage } from "@/modules/finance/AnalyticsPage";

export const Route = createFileRoute("/_authenticated/analytics")({
  head: () => ({
    meta: [
      { title: "Product analytics — 20s Coffee" },
      {
        name: "description",
        content:
          "See which 20s Coffee drinks sell most, their margins, and marketing ideas for slow movers.",
      },
      { property: "og:title", content: "Product analytics — 20s Coffee" },
      {
        property: "og:description",
        content: "Demand, profit margins and promotion ideas per product.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: AnalyticsPage,
});
