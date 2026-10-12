import { createServerFn } from "@tanstack/react-start";
import { createClient } from "@supabase/supabase-js";
import { z } from "zod";

import type { Database } from "@/integrations/supabase/types";

export type PublicMenuSize = {
  id: string;
  name: string;
  name_ar: string | null;
  price_delta: number;
};

export type PublicMenuProduct = {
  id: string;
  name: string;
  name_ar: string | null;
  description: string | null;
  image_url: string | null;
  price: number;
  offer_price: number | null;
  sizes: PublicMenuSize[];
};

export type PublicMenuOffer = {
  id: string;
  title: string;
  offer_type: "single" | "bundle";
  offer_price: number;
  base_price: number;
  image_path: string | null;
  double_points: boolean;
  ends_at: string | null;
  product: { id: string; name: string; name_ar: string | null; image_url: string | null } | null;
  items: Array<{
    product_id: string;
    name: string;
    name_ar: string | null;
    image_url: string | null;
    quantity: number;
    base_price: number;
  }>;
};

export type PublicMenu = {
  company: {
    name: string;
    logo_url: string | null;
    currency: string;
    default_language: "ar" | "en";
  };
  branch: { id: string; name: string; address: string | null; phone: string | null };
  offers_enabled: boolean;
  offers: PublicMenuOffer[];
  categories: Array<{
    id: string;
    name: string;
    name_ar: string | null;
    products: PublicMenuProduct[];
  }>;
};

export const getPublicMenu = createServerFn({ method: "GET" })
  .inputValidator((data: unknown) => z.object({ branchId: z.string().uuid() }).parse(data))
  .handler(async ({ data }): Promise<PublicMenu | null> => {
    const client = createClient<Database>(
      process.env["SUPABASE_URL"]!,
      process.env["SUPABASE_PUBLISHABLE_KEY"]!,
      { auth: { storage: undefined, persistSession: false, autoRefreshToken: false } },
    );
    const { data: menu, error } = await client.rpc("public_menu", { _branch_id: data.branchId });
    if (error) throw error;
    const result = (menu as PublicMenu | null) ?? null;
    if (!result) return null;

    result.offers = result.offers ?? [];

    // Product photos live in a private bucket, so sign them server-side for guests.
    const paths = Array.from(
      new Set(
        [
          ...result.categories.flatMap((category) => category.products),
          ...result.offers.flatMap((offer) => [
            ...(offer.product ? [offer.product] : []),
            ...offer.items,
          ]),
        ]
          .map((product) => product.image_url)
          .filter((path): path is string => Boolean(path) && !path!.startsWith("http")),
      ),
    );
    const offerPaths = Array.from(
      new Set(
        result.offers
          .map((offer) => offer.image_path)
          .filter((path): path is string => Boolean(path) && !path!.startsWith("http")),
      ),
    );
    if (paths.length > 0 || offerPaths.length > 0) {
      const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
      const [{ data: signed }, { data: signedOffers }] = await Promise.all([
        paths.length > 0
          ? supabaseAdmin.storage.from("product-images").createSignedUrls(paths, 60 * 60 * 6)
          : Promise.resolve({ data: [] as Array<{ path: string | null; signedUrl: string }> }),
        offerPaths.length > 0
          ? supabaseAdmin.storage.from("offer-images").createSignedUrls(offerPaths, 60 * 60 * 6)
          : Promise.resolve({ data: [] as Array<{ path: string | null; signedUrl: string }> }),
      ]);
      const map = new Map<string, string>();
      for (const row of signed ?? []) {
        if (row.path && row.signedUrl) map.set(row.path, row.signedUrl);
      }
      const offerMap = new Map<string, string>();
      for (const row of signedOffers ?? []) {
        if (row.path && row.signedUrl) offerMap.set(row.path, row.signedUrl);
      }
      for (const category of result.categories) {
        for (const product of category.products) {
          if (product.image_url) product.image_url = map.get(product.image_url) ?? null;
        }
      }
      for (const offer of result.offers) {
        if (offer.image_path) offer.image_path = offerMap.get(offer.image_path) ?? null;
        if (offer.product?.image_url) {
          offer.product.image_url = map.get(offer.product.image_url) ?? null;
        }
        for (const item of offer.items) {
          if (item.image_url) item.image_url = map.get(item.image_url) ?? null;
        }
      }
    }
    return result;
  });
