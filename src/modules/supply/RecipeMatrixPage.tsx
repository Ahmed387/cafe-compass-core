import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useMemo, useState } from "react";
import { Plus, Save, Trash2 } from "lucide-react";
import { toast } from "sonner";

import { NoPermission, PageHeader } from "@/components/layout/AppShell";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { formatMoney, friendlyError } from "@/lib/format";
import { compatibleUnits, defaultEntryUnit, fromStockUnit, toStockUnit, unitLabel } from "./units";

type Line = { key: string; size_id: string; item_id: string; qty: string; unit: string };
type Inv = { id: string; name: string; unit: string; cost: number; waste: number };

let seq = 0;
const k = () => `l${++seq}`;

export function RecipeMatrixPage() {
  const { can } = useAuth();
  const qc = useQueryClient();
  const [q, setQ] = useState("");
  const [productId, setProductId] = useState<string | null>(null);
  const [lines, setLines] = useState<Line[]>([]);

  const base = useQuery({
    queryKey: ["recipe-matrix-base"],
    queryFn: async () => {
      const [p, inv, r] = await Promise.all([
        supabase.from("products").select("id,name,is_active").eq("is_active", true).order("name"),
        supabase.from("inventory_items").select("id,name,name_ar,unit,cost_per_unit,waste_pct").eq("is_active", true).order("name"),
        supabase.from("product_recipes").select("product_id"),
      ]);
      if (p.error) throw p.error;
      if (inv.error) throw inv.error;
      if (r.error) throw r.error;
      const withRecipe = new Set(r.data.map((x) => x.product_id));
      return {
        products: p.data.map((x) => ({ id: x.id, name: x.name, has: withRecipe.has(x.id) })),
        inv: inv.data.map((i): Inv => ({ id: i.id, name: i.name_ar || i.name, unit: i.unit, cost: Number(i.cost_per_unit ?? 0), waste: Number(i.waste_pct ?? 0) })),
      };
    },
  });
  const invMap = useMemo(() => new Map((base.data?.inv ?? []).map((i) => [i.id, i])), [base.data]);

  const detail = useQuery({
    queryKey: ["recipe-matrix", productId],
    enabled: !!productId,
    queryFn: async () => {
      const [s, r] = await Promise.all([
        supabase.from("product_sizes").select("id,name").eq("product_id", productId!).order("name"),
        supabase.from("product_recipes").select("size_id,item_id,quantity,unit").eq("product_id", productId!),
      ]);
      if (s.error) throw s.error;
      if (r.error) throw r.error;
      return { sizes: s.data, recipe: r.data };
    },
  });

  useEffect(() => {
    if (!detail.data) return;
    setLines(
      detail.data.recipe.map((r) => {
        const stockUnit = invMap.get(r.item_id)?.unit ?? "";
        const unit = r.unit || stockUnit;
        return {
          key: k(),
          size_id: r.size_id ?? "",
          item_id: r.item_id,
          unit,
          qty: String(Math.round(fromStockUnit(Number(r.quantity), unit, stockUnit) * 1000) / 1000),
        };
      }),
    );
  }, [detail.data, invMap]);

  const save = useMutation({
    mutationFn: async () => {
      const payload = lines
        .filter((l) => l.item_id && Number(l.qty) > 0)
        .map((l) => ({
          size_id: l.size_id || null,
          item_id: l.item_id,
          unit: l.unit,
          quantity: toStockUnit(Number(l.qty), l.unit, invMap.get(l.item_id)?.unit ?? l.unit),
        }));
      const { error } = await supabase.rpc("save_recipe_matrix", { _product_id: productId!, _lines: payload });
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success("تم حفظ الوصفة");
      qc.invalidateQueries({ queryKey: ["recipe-matrix"] });
      qc.invalidateQueries({ queryKey: ["recipe-matrix-base"] });
      qc.invalidateQueries({ queryKey: ["recipe-costs"] });
    },
    onError: (e) => toast.error(friendlyError(e)),
  });

  if (!can("products.view") && !can("inventory.view")) return <NoPermission message="لا تملك صلاحية" />;
  const canEdit = can("products.update") || can("inventory.adjust");

  const sizes = detail.data?.sizes ?? [];
  const lineCost = (l: Line) => {
    const i = invMap.get(l.item_id);
    return i ? toStockUnit(Number(l.qty || 0), l.unit, i.unit) * i.cost : 0;
  };
  const costFor = (sizeId: string) =>
    lines.filter((l) => !l.size_id || l.size_id === sizeId).reduce((s, l) => s + lineCost(l), 0);
  // Booked cost = raw ingredient cost (same as the sale-time cost). Expected waste is
  // shown apart for tracking; it never marks up the cost or the menu price.
  const expectedWaste = (sizeId: string) =>
    lines
      .filter((l) => !l.size_id || l.size_id === sizeId)
      .reduce((s, l) => s + (lineCost(l) * (invMap.get(l.item_id)?.waste ?? 0)) / 100, 0);
  const variants = sizes.length ? sizes.map((s) => ({ id: s.id, name: s.name })) : [{ id: "", name: "الصنف" }];

  const products = (base.data?.products ?? []).filter((p) => p.name.toLowerCase().includes(q.toLowerCase()));

  return (
    <div dir="rtl" className="space-y-6">
      <PageHeader
        title="مصفوفة الوصفات"
        description="اربط الخامات بكل صنف وحجم. البيع يخصم الكمية بالظبط من البار، وتكلفة الخامات دي هي اللي بتدخل في حسابات الوردية."
      />
      <div className="grid gap-4 lg:grid-cols-[280px_1fr]">
        <div className="space-y-2 rounded-lg border p-2">
          <Input placeholder="بحث عن صنف…" value={q} onChange={(e) => setQ(e.target.value)} />
          <div className="max-h-[65vh] space-y-1 overflow-y-auto">
            {products.map((p) => (
              <button
                key={p.id}
                onClick={() => setProductId(p.id)}
                className={`flex w-full items-center justify-between rounded-md px-2 py-1.5 text-right text-sm hover:bg-muted ${productId === p.id ? "bg-muted font-semibold" : ""}`}
              >
                <span className="truncate">{p.name}</span>
                {!p.has && <Badge variant="destructive">بدون وصفة</Badge>}
              </button>
            ))}
          </div>
        </div>

        <div className="space-y-4 rounded-lg border p-4">
          {!productId ? (
            <p className="text-sm text-muted-foreground">اختر صنفًا لعرض وصفته.</p>
          ) : (
            <>
              <div className="flex flex-wrap gap-2">
                {variants.map((v) => (
                  <div key={v.id} className="rounded-md border px-3 py-2 text-sm">
                    <div className="text-muted-foreground">{v.name}</div>
                    <div className="font-semibold">{formatMoney(costFor(v.id))}</div>
                    {expectedWaste(v.id) > 0 && (
                      <div className="text-xs text-muted-foreground">
                        هالك متوقع (للمتابعة بس): {formatMoney(expectedWaste(v.id))}
                      </div>
                    )}
                  </div>
                ))}
              </div>

              <div className="space-y-2">
                {lines.map((l) => {
                  const inv = invMap.get(l.item_id);
                  const set = (patch: Partial<Line>) =>
                    setLines((ls) => ls.map((x) => (x.key === l.key ? { ...x, ...patch } : x)));
                  return (
                    <div key={l.key} className="flex flex-wrap items-center gap-2">
                      <select
                        className="h-9 min-w-48 flex-1 rounded-md border bg-background px-2 text-sm"
                        value={l.item_id}
                        disabled={!canEdit}
                        onChange={(e) => {
                          const ni = invMap.get(e.target.value);
                          set({ item_id: e.target.value, unit: ni ? defaultEntryUnit(ni.unit) : l.unit });
                        }}
                      >
                        <option value="">— الخامة —</option>
                        {(base.data?.inv ?? []).map((i) => (
                          <option key={i.id} value={i.id}>
                            {i.name}
                          </option>
                        ))}
                      </select>
                      {sizes.length > 0 && (
                        <select
                          className="h-9 rounded-md border bg-background px-2 text-sm"
                          value={l.size_id}
                          disabled={!canEdit}
                          onChange={(e) => set({ size_id: e.target.value })}
                        >
                          <option value="">كل الأحجام</option>
                          {sizes.map((s) => (
                            <option key={s.id} value={s.id}>
                              {s.name}
                            </option>
                          ))}
                        </select>
                      )}
                      <Input
                        type="number"
                        min={0}
                        className="h-9 w-24"
                        value={l.qty}
                        disabled={!canEdit}
                        onChange={(e) => set({ qty: e.target.value })}
                      />
                      <select
                        className="h-9 rounded-md border bg-background px-2 text-sm"
                        value={l.unit}
                        disabled={!canEdit || !inv}
                        onChange={(e) => set({ unit: e.target.value })}
                      >
                        {(inv ? compatibleUnits(inv.unit) : [l.unit]).map((u) => (
                          <option key={u} value={u}>
                            {unitLabel(u)}
                          </option>
                        ))}
                      </select>
                      <span className="w-20 text-xs text-muted-foreground">{formatMoney(lineCost(l))}</span>
                      {canEdit && (
                        <Button
                          size="icon"
                          variant="ghost"
                          onClick={() => setLines((ls) => ls.filter((x) => x.key !== l.key))}
                          aria-label="حذف"
                        >
                          <Trash2 className="h-4 w-4" />
                        </Button>
                      )}
                    </div>
                  );
                })}
              </div>

              {canEdit && (
                <div className="flex gap-2">
                  <Button
                    variant="outline"
                    onClick={() => setLines((ls) => [...ls, { key: k(), size_id: "", item_id: "", qty: "", unit: "g" }])}
                  >
                    <Plus className="ml-1 h-4 w-4" /> إضافة خامة
                  </Button>
                  <Button disabled={save.isPending} onClick={() => save.mutate()}>
                    <Save className="ml-1 h-4 w-4" /> حفظ الوصفة
                  </Button>
                </div>
              )}
            </>
          )}
        </div>
      </div>
    </div>
  );
}
