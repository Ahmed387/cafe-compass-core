import { useQuery } from "@tanstack/react-query";

import { supabase } from "@/integrations/supabase/client";

export const PRODUCT_IMAGE_BUCKET = "product-images";
export const MAX_PRODUCT_IMAGE_BYTES = 3 * 1024 * 1024;

/** Uploads a product photo and returns the storage path stored on the product row. */
export async function uploadProductImage(file: File, companyId: string) {
  if (file.size > MAX_PRODUCT_IMAGE_BYTES) throw new Error("image too large");
  const extension = file.name.split(".").pop()?.toLowerCase() || "jpg";
  const path = `${companyId}/${crypto.randomUUID()}.${extension}`;
  const { error } = await supabase.storage
    .from(PRODUCT_IMAGE_BUCKET)
    .upload(path, file, { contentType: file.type || "image/jpeg", upsert: true });
  if (error) throw error;
  return path;
}

/** Signs every product photo path once so cards can render them straight away. */
export function useProductImageUrls(paths: Array<string | null | undefined>) {
  const clean = Array.from(new Set(paths.filter((p): p is string => Boolean(p)))).sort();
  return useQuery({
    queryKey: ["product-image-urls", clean.join("|")],
    enabled: clean.length > 0,
    staleTime: 45 * 60 * 1000,
    queryFn: async () => {
      const { data, error } = await supabase.storage
        .from(PRODUCT_IMAGE_BUCKET)
        .createSignedUrls(clean, 60 * 60);
      if (error) throw error;
      const map = new Map<string, string>();
      for (const row of data ?? []) {
        if (row.path && row.signedUrl) map.set(row.path, row.signedUrl);
      }
      return map;
    },
  });
}
