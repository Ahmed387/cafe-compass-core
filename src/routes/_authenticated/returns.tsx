import { createFileRoute, redirect } from "@tanstack/react-router";

// Legacy URL: supplier returns live in Purchases; customer refunds in /refunds.
export const Route = createFileRoute("/_authenticated/returns")({
  beforeLoad: () => {
    throw redirect({ to: "/purchases", search: { tab: "returns" }, replace: true });
  },
});
