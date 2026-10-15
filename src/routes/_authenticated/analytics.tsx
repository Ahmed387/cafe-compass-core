import { createFileRoute, redirect } from "@tanstack/react-router";

// Legacy URL: product analytics is a tab of Insights (Finance hub).
export const Route = createFileRoute("/_authenticated/analytics")({
  beforeLoad: () => {
    throw redirect({ to: "/insights", replace: true });
  },
});
