import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { AlertTriangle } from "lucide-react";

import { supabase } from "@/integrations/supabase/client";

export type BarLowItem = {
  item_id: string;
  name: string;
  unit: string;
  bar_qty: number;
  bar_min: number;
  product_ids: string[];
};

/** Bar ingredients at or below their reorder level, plus the menu items that use them. */
export function useBarLowStock(branchId: string | null | undefined) {
  const q = useQuery({
    queryKey: ["bar-low-stock", branchId],
    enabled: Boolean(branchId),
    refetchInterval: 60_000,
    queryFn: async (): Promise<BarLowItem[]> => {
      const { data, error } = await supabase.rpc("bar_low_stock", { _branch_id: branchId! });
      if (error) throw error;
      return (data ?? []) as BarLowItem[];
    },
  });
  const items = q.data ?? [];
  const byProduct = new Map<string, BarLowItem[]>();
  for (const it of items)
    for (const pid of it.product_ids ?? []) byProduct.set(pid, [...(byProduct.get(pid) ?? []), it]);
  return { items, byProduct };
}

export function BarLowStockAlert({ items, showLink }: { items: BarLowItem[]; showLink?: boolean }) {
  if (items.length === 0) return null;
  return (
    <div dir="rtl" className="mb-4 rounded-lg border border-destructive/40 bg-destructive/10 p-3 text-sm">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="flex items-center gap-2 font-semibold text-destructive">
          <AlertTriangle className="h-4 w-4" /> خامات البار تحت حد إعادة الطلب ({items.length})
        </p>
        {showLink && (
          <Link to="/warehouse" className="text-xs font-medium text-primary underline">
            اطلب من المخزن الرئيسي
          </Link>
        )}
      </div>
      <div className="mt-2 flex flex-wrap gap-2">
        {items.map((i) => (
          <span key={i.item_id} className="rounded-full border border-destructive/40 bg-background px-2 py-0.5 text-xs">
            {i.name}: {Number(i.bar_qty)} / {Number(i.bar_min)} {i.unit}
          </span>
        ))}
      </div>
    </div>
  );
}

export function LowStockCardBadge({ items }: { items: BarLowItem[] | undefined }) {
  if (!items?.length) return null;
  return (
    // A small icon under the sold-out toggle, so it never covers the product name.
    <span
      title={`مخزون البار منخفض: ${items.map((i) => i.name).join("، ")}`}
      className="absolute start-2 top-11 z-10 grid size-7 place-items-center rounded-full bg-destructive text-destructive-foreground shadow-sm ring-2 ring-background"
    >
      <AlertTriangle className="size-3.5" aria-hidden />
      <span className="sr-only">مخزون البار منخفض</span>
    </span>
  );
}
