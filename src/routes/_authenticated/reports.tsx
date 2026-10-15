import { createFileRoute, redirect } from "@tanstack/react-router";

// Legacy URL: reports are a tab of Insights (Finance hub).
export const Route = createFileRoute("/_authenticated/reports")({
  beforeLoad: () => {
    throw redirect({ to: "/insights", replace: true });
  },
});
