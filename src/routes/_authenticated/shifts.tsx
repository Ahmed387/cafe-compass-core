import { createFileRoute, redirect } from "@tanstack/react-router";

export const Route = createFileRoute("/_authenticated/shifts")({
  head: () => ({
    meta: [
      { title: "Cash shifts — 20s Coffee" },
      { name: "description", content: "Review opening cash, closing cash and shift variances." },
      { property: "og:title", content: "Cash shifts — 20s Coffee" },
      { property: "og:description", content: "Cash shift history and reconciliation for 20s Coffee." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  beforeLoad: () => {
    throw redirect({ to: "/orders", search: { tab: "shifts", orderId: undefined } });
  },
});