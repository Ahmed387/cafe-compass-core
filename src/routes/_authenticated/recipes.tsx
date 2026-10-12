import { createFileRoute } from "@tanstack/react-router";

import { RecipeMatrixPage } from "@/modules/supply/RecipeMatrixPage";

export const Route = createFileRoute("/_authenticated/recipes")({
  head: () => ({
    meta: [
      { title: "Recipe matrix — 20s Coffee" },
      { name: "description", content: "Link raw materials to menu items and sizes with unit conversion and real cost." },
      { property: "og:title", content: "Recipe matrix — 20s Coffee" },
      { property: "og:description", content: "Ingredient recipes per menu item and size." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: RecipeMatrixPage,
});
