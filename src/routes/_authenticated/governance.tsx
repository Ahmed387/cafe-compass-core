import { createFileRoute } from "@tanstack/react-router";

import { HubLanding } from "@/modules/shell/HubLanding";

export const Route = createFileRoute("/_authenticated/governance")({
  head: () => ({
    meta: [
      { title: "Governance hub — 20s Coffee" },
      { name: "description", content: "Owner dashboard, partners, HR, users and system settings for 20s Coffee." },
      { property: "og:title", content: "Governance hub — 20s Coffee" },
      { property: "og:description", content: "Owner dashboard, partners, HR, users and system settings for 20s Coffee." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: GovernancehubLanding,
});

function GovernancehubLanding() {
  return <HubLanding hubId="governance" />;
}
