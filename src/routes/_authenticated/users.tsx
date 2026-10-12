import { createFileRoute, redirect } from "@tanstack/react-router";

// Users merged into the unified Team & HR page; keep the old URL working.
export const Route = createFileRoute("/_authenticated/users")({
  beforeLoad: () => {
    throw redirect({ to: "/hr", search: { tab: "team" }, replace: true });
  },
});
