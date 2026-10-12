import { createFileRoute, redirect } from "@tanstack/react-router";

export const Route = createFileRoute("/_authenticated/bar")({
  beforeLoad: () => {
    throw redirect({ to: "/warehouse" });
  },
});
