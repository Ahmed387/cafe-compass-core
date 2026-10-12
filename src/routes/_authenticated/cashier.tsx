import { createFileRoute, redirect } from "@tanstack/react-router";

export const Route = createFileRoute("/_authenticated/cashier")({
  beforeLoad: () => {
    throw redirect({ to: "/pos", search: { mode: undefined } });
  },
});
