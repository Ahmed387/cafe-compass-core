import { createFileRoute, redirect } from "@tanstack/react-router";

// Legacy URL: the public menu now lives at /menu.
export const Route = createFileRoute("/soft-menu")({
  beforeLoad: () => {
    throw redirect({ to: "/menu", replace: true, statusCode: 301 });
  },
});
