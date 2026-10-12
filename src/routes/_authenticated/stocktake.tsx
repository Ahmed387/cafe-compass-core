import { createFileRoute } from "@tanstack/react-router";

import { StocktakePage } from "@/modules/supply/StocktakePage";

export const Route = createFileRoute("/_authenticated/stocktake")({
  head: () => ({
    meta: [
      { title: "Smart stocktake — 20s Coffee" },
      { name: "description", content: "Count Bar and Main stock against expected levels with waste tolerance." },
      { property: "og:title", content: "Smart stocktake — 20s Coffee" },
      { property: "og:description", content: "Bar and Main stocktake with variance reconciliation." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: StocktakePage,
});
