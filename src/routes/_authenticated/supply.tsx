import { createFileRoute } from "@tanstack/react-router";

import { HubLanding } from "@/modules/shell/HubLanding";

export const Route = createFileRoute("/_authenticated/supply")({
  head: () => ({
    meta: [
      { title: "Supply hub — 20s Coffee" },
      { name: "description", content: "Warehouses, stocktaking, purchases and supplier returns for 20s Coffee." },
      { property: "og:title", content: "Supply hub — 20s Coffee" },
      { property: "og:description", content: "Warehouses, stocktaking, purchases and supplier returns for 20s Coffee." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: SupplyhubLanding,
});

function SupplyhubLanding() {
  return <HubLanding hubId="supply" />;
}
