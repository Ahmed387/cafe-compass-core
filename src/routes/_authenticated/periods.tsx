import { createFileRoute, redirect } from "@tanstack/react-router";

// Accounting periods were retired: profit is now reviewed and paid out by any date range on the P&L page.
export const Route = createFileRoute("/_authenticated/periods")({
  beforeLoad: () => {
    throw redirect({ to: "/pnl" });
  },
});
