const imageModules = import.meta.glob("../assets/soft-menu/items/*.jpg", {
  eager: true,
  import: "default",
  query: "?url",
}) as Record<string, string>;

export type SoftOpeningVariant = {
  id: string;
  key: string;
  name_ar: string;
  name_en: string;
  price: number;
  display_order: number;
};

export type ServeType = "cold" | "hot" | "none";

export type SoftOpeningAddon = {
  id: string;
  key: string;
  name_ar: string;
  name_en: string;
  price: number;
};

/** Flat surcharge for serving a cold drink in a sealed can. */
export const CAN_SURCHARGE = 30;

export type SoftOpeningItem = {
  id: string;
  category_id: string;
  slug: string;
  name_ar: string;
  name_en: string;
  price: number;
  image_key: string;
  display_order: number;
  serve_type: ServeType;
  /** false = temporarily sold out ("86"). Optional for static catalog entries. */
  is_available?: boolean;
  variants: SoftOpeningVariant[];
  addons: SoftOpeningAddon[];
};

export type SoftOpeningCategory = {
  id: string;
  slug: string;
  name_ar: string;
  name_en: string;
  display_order: number;
  items: SoftOpeningItem[];
};

const motifModules = import.meta.glob("../assets/soft-menu/*.{jpg,png}", {
  eager: true,
  import: "default",
  query: "?url",
}) as Record<string, string>;

const creamCanMotif = motifModules["../assets/soft-menu/can-cream.png"] ?? "";
const blueCanMotif = motifModules["../assets/soft-menu/can-blue.png"] ?? creamCanMotif;
const caramelCanMotif = motifModules["../assets/soft-menu/can-caramel.png"] ?? creamCanMotif;

export const canMotif = creamCanMotif;
export const kraftMotif = motifModules["../assets/soft-menu/kraft-filled.png"] ?? "";

function coldCanFor(imageKey: string) {
  if (/mojito|smoothie|matcha|blue|passion|kiwi|lemon|mango|guava/.test(imageKey)) return blueCanMotif;
  if (/caramel|lotus|pistachio|spanish|white-mocha|milkshake/.test(imageKey)) return caramelCanMotif;
  return creamCanMotif;
}

export function softOpeningImage(imageKey: string, serveType: ServeType = "none") {
  const own = imageModules[`../assets/soft-menu/items/${imageKey}.jpg`];
  if (own) return own;
  if (serveType === "cold") return coldCanFor(imageKey);
  if (serveType === "hot") return kraftMotif;
  return imageModules["../assets/soft-menu/items/cheesecake.jpg"] ?? kraftMotif;
}