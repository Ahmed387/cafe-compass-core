import { createFileRoute, redirect } from "@tanstack/react-router";

// Legacy URL: the treasury now lives in the Finance hub.
export const Route = createFileRoute("/_authenticated/treasury")({
  beforeLoad: () => {
    throw redirect({ to: "/money", replace: true });
  },
});
