import { createFileRoute } from "@tanstack/react-router";

import { HubLanding } from "@/modules/shell/HubLanding";

export const Route = createFileRoute("/_authenticated/operations")({
  head: () => ({
    meta: [
      { title: "Operations hub — 20s Coffee" },
      { name: "description", content: "POS, orders, refunds and cash shifts for 20s Coffee." },
      { property: "og:title", content: "Operations hub — 20s Coffee" },
      { property: "og:description", content: "POS, orders, refunds and cash shifts for 20s Coffee." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: OperationshubLanding,
});

function OperationshubLanding() {
  return <HubLanding hubId="operations" />;
}
