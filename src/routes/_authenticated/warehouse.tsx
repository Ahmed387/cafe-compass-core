import { createFileRoute } from "@tanstack/react-router";

import { WarehousePage } from "@/modules/supply/WarehousePage";

export const Route = createFileRoute("/_authenticated/warehouse")({
  head: () => ({
    meta: [
      { title: "Main & Bar stores — 20s Coffee" },
      { name: "description", content: "Main storage and bar stock with approved transfers." },
      { property: "og:title", content: "Main & Bar stores — 20s Coffee" },
      { property: "og:description", content: "Dual-location stock and transfer approvals." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: WarehousePage,
});
