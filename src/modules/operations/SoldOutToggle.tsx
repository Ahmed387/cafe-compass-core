import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Ban, RotateCcw } from "lucide-react";
import { toast } from "sonner";

import { supabase } from "@/integrations/supabase/client";
import { friendlyError } from "@/lib/format";

/** One-tap "86" switch on a POS product card; syncs the public /menu too. */
export function SoldOutToggle({
  productId,
  available,
  lang,
}: {
  productId: string;
  available: boolean;
  lang: "ar" | "en";
}) {
  const queryClient = useQueryClient();
  const ar = lang === "ar";
  const toggle = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc("set_product_availability", {
        _product_id: productId,
        _available: !available,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["pos-products"] });
      toast.success(
        available
          ? ar ? "تم تعليم الصنف: نفد مؤقتاً" : "Marked as sold out"
          : ar ? "الصنف متاح مرة أخرى" : "Back in stock",
      );
    },
    onError: (error) => toast.error(friendlyError(error)),
  });

  const text = available ? (ar ? "نفد مؤقتاً" : "Sold out") : ar ? "إتاحة" : "Restock";
  return (
    <button
      type="button"
      disabled={toggle.isPending}
      onClick={(event) => {
        event.stopPropagation();
        toggle.mutate();
      }}
      aria-label={text}
      title={text}
      className={`absolute start-2 top-2 z-10 inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-xs font-bold shadow-sm transition disabled:opacity-60 ${
        available
          ? "bg-background/90 text-destructive hover:bg-destructive hover:text-destructive-foreground"
          : "bg-primary text-primary-foreground hover:opacity-90"
      }`}
    >
      {available ? <Ban className="size-3.5" /> : <RotateCcw className="size-3.5" />}
      {text}
    </button>
  );
}
