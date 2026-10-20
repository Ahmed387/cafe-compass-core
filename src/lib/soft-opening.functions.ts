import { createServerFn } from "@tanstack/react-start";
import { createClient } from "@supabase/supabase-js";

import type {
  ServeType,
  SoftOpeningAddon,
  SoftOpeningCategory,
  SoftOpeningItem,
  SoftOpeningVariant,
} from "./soft-opening-catalog";

type CategoryRow = Omit<SoftOpeningCategory, "items">;
type ItemRow = Omit<SoftOpeningItem, "variants" | "addons">;

export const getSoftOpeningCatalog = createServerFn({ method: "GET" }).handler(
  async (): Promise<SoftOpeningCategory[]> => {
    const client = createClient(
      process.env["SUPABASE_URL"]!,
      process.env["SUPABASE_PUBLISHABLE_KEY"]!,
      { auth: { storage: undefined, persistSession: false, autoRefreshToken: false } },
    );
    const [categoriesResult, itemsResult, variantsResult, addonsResult] = await Promise.all([
      client
        .from("soft_opening_categories")
        .select("id,slug,name_ar,name_en,display_order")
        .eq("is_active", true)
        .order("display_order"),
      client
        .from("soft_opening_items")
        .select("id,category_id,slug,name_ar,name_en,price,image_key,display_order,serve_type,is_available")
        .eq("is_active", true)
        .order("display_order"),
      client
        .from("soft_opening_item_variants")
        .select("id,item_id,key,name_ar,name_en,price,display_order")
        .eq("is_active", true)
        .order("display_order"),
      client
        .from("soft_opening_item_addons")
        .select("id,item_id,key,name_ar,name_en,price,display_order")
        .eq("is_active", true)
        .order("display_order"),
    ]);
    if (addonsResult.error) throw addonsResult.error;
    const addonsByItem = new Map<string, SoftOpeningAddon[]>();
    for (const row of addonsResult.data ?? []) {
      const addon: SoftOpeningAddon = { id: String(row.id), key: String(row.key), name_ar: String(row.name_ar), name_en: String(row.name_en), price: Number(row.price) };
      addonsByItem.set(String(row.item_id), [...(addonsByItem.get(String(row.item_id)) ?? []), addon]);
    }
    if (categoriesResult.error) throw categoriesResult.error;
    if (itemsResult.error) throw itemsResult.error;
    if (variantsResult.error) throw variantsResult.error;

    const variantsByItem = new Map<string, SoftOpeningVariant[]>();
    for (const row of variantsResult.data ?? []) {
      const variant: SoftOpeningVariant = {
        id: String(row.id),
        key: String(row.key),
        name_ar: String(row.name_ar),
        name_en: String(row.name_en),
        price: Number(row.price),
        display_order: Number(row.display_order),
      };
      const itemId = String(row.item_id);
      variantsByItem.set(itemId, [...(variantsByItem.get(itemId) ?? []), variant]);
    }

    const itemsByCategory = new Map<string, SoftOpeningItem[]>();
    for (const row of (itemsResult.data ?? []) as ItemRow[]) {
      const item: SoftOpeningItem = {
        ...row,
        price: Number(row.price),
        display_order: Number(row.display_order),
        serve_type: (row.serve_type as ServeType) ?? "none",
        is_available: row.is_available !== false,
        variants: variantsByItem.get(row.id) ?? [],
        addons: addonsByItem.get(row.id) ?? [],
      };
      itemsByCategory.set(row.category_id, [...(itemsByCategory.get(row.category_id) ?? []), item]);
    }

    return ((categoriesResult.data ?? []) as CategoryRow[]).map((category) => ({
      ...category,
      display_order: Number(category.display_order),
      items: itemsByCategory.get(category.id) ?? [],
    }));
  },
);
export type MenuOffer = {
  id: string;
  title: string;
  offer_price: number;
  base_price: number;
  product_name: string | null;
  product_name_ar: string | null;
  ends_at: string | null;
};

/** Offers approved on the offers page, shown at the top of the public menu. Empty if none or not set up yet. */
export const getMenuOffers = createServerFn({ method: "GET" }).handler(async (): Promise<MenuOffer[]> => {
  const client = createClient(process.env["SUPABASE_URL"]!, process.env["SUPABASE_PUBLISHABLE_KEY"]!, {
    auth: { storage: undefined, persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await client.rpc("public_menu_offers" as never);
  if (error || !Array.isArray(data)) return [];
  return (data as Record<string, unknown>[]).map((row) => ({
    id: String(row["id"]),
    title: String(row["title"] ?? ""),
    offer_price: Number(row["offer_price"] ?? 0),
    base_price: Number(row["base_price"] ?? 0),
    product_name: (row["product_name"] as string | null) ?? null,
    product_name_ar: (row["product_name_ar"] as string | null) ?? null,
    ends_at: (row["ends_at"] as string | null) ?? null,
  }));
});
