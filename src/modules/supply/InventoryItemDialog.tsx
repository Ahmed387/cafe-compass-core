import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Coins, Info, Package, ShoppingBag, Trash2, type LucideIcon } from "lucide-react";
import { useEffect, useMemo, useState, type ReactNode } from "react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { formatMoney, friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { cn } from "@/lib/utils";

export const INVENTORY_UNITS = ["kg", "g", "liter", "ml", "pcs", "box"];

export type InventoryItemForm = {
  id?: string;
  name: string;
  name_ar: string;
  unit: string;
  sku: string;
  cost_per_unit: string;
  total_cost: string;
  min_qty: string;
  opening_qty: string;
  waste_pct: string;
};

export const emptyInventoryItem: InventoryItemForm = {
  name: "",
  name_ar: "",
  unit: "kg",
  sku: "",
  cost_per_unit: "0",
  total_cost: "",
  min_qty: "0",
  opening_qty: "0",
  waste_pct: "0",
};

/** Unit cost = total cost / quantity, rounded to 3 decimals; guards zero and invalid input. */
export function deriveUnitCost(totalCost: string, quantity: string): string | null {
  const total = Number(totalCost);
  const qty = Number(quantity);
  if (!totalCost.trim() || !Number.isFinite(total)) return null;
  if (!Number.isFinite(qty) || qty <= 0) return "0.00";
  return (Math.round((total / qty) * 1000) / 1000).toFixed(3);
}

const sameName = (a: string | null | undefined, b: string | null | undefined) =>
  Boolean(a?.trim() && b?.trim() && a.trim().toLowerCase() === b.trim().toLowerCase());

function Section({
  icon: Icon,
  title,
  hint,
  tone = "default",
  children,
}: {
  icon: LucideIcon;
  title: string;
  hint?: string;
  tone?: "default" | "muted";
  children: ReactNode;
}) {
  return (
    <section
      className={cn(
        "space-y-4 rounded-xl border p-4",
        tone === "muted" ? "border-dashed border-border bg-muted" : "border-border bg-card",
      )}
    >
      <header className="flex items-start gap-3">
        <span className="icon-chip-soft flex size-8 shrink-0 items-center justify-center rounded-lg">
          <Icon className="size-4" aria-hidden />
        </span>
        <div className="min-w-0">
          <h3 className="text-sm font-semibold leading-8">{title}</h3>
          {hint && <p className="-mt-1 text-xs leading-relaxed text-muted-foreground">{hint}</p>}
        </div>
      </header>
      {children}
    </section>
  );
}

function Field({
  id,
  label,
  hint,
  suffix,
  className,
  children,
}: {
  id: string;
  label: string;
  hint?: ReactNode;
  suffix?: string;
  className?: string;
  children: ReactNode;
}) {
  return (
    <div className={cn("flex min-w-0 flex-col gap-1.5", className)}>
      <Label htmlFor={id} className="text-xs font-medium text-muted-foreground">
        {label}
      </Label>
      <div className="relative">
        {children}
        {suffix && (
          <span className="pointer-events-none absolute inset-y-0 end-3 flex items-center text-xs text-muted-foreground">
            {suffix}
          </span>
        )}
      </div>
      {hint && <p className="text-[11px] leading-relaxed text-muted-foreground">{hint}</p>}
    </div>
  );
}

/**
 * Create / edit a raw material. Three clearly separated parts: what the item is,
 * what it costs (the plain purchase cost per unit), and its expected waste %, which
 * is tracked on its own and never changes the cost or any menu price.
 */
export function InventoryItemDialog({
  open,
  onOpenChange,
  initial,
  onSaved,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  initial: InventoryItemForm;
  onSaved: () => void | Promise<void>;
}) {
  const { t, lang } = useI18n();
  const ar = lang === "ar";
  const { me, currentBranchId } = useAuth();
  const currency = me?.company?.currency ?? "EGP";
  const qc = useQueryClient();
  const [form, setForm] = useState<InventoryItemForm>(initial);
  // Menu product this item is sold as (1 piece sold = 1 unit of this item).
  const [sellAs, setSellAs] = useState<string | null>(null);
  useEffect(() => {
    if (open) {
      setForm(initial);
      setSellAs(null);
    }
  }, [open, initial]);

  const menu = useQuery({
    queryKey: ["ready-product-links"],
    enabled: open,
    queryFn: async () => {
      const [products, recipes] = await Promise.all([
        supabase.from("products").select("id, name, name_ar").eq("is_active", true).order("name"),
        supabase.from("product_recipes").select("product_id, item_id, quantity"),
      ]);
      if (products.error) throw products.error;
      if (recipes.error) throw recipes.error;
      return { products: products.data ?? [], recipes: recipes.data ?? [] };
    },
  });

  const isNew = !form.id;
  const set = (patch: Partial<InventoryItemForm>) => setForm((prev) => ({ ...prev, ...patch }));
  const derived = isNew ? deriveUnitCost(form.total_cost, form.opening_qty) : null;
  const waste = Number(form.waste_pct);
  const wasteValid =
    form.waste_pct.trim() === "" || (Number.isFinite(waste) && waste >= 0 && waste <= 100);
  const unitCost = Number(form.cost_per_unit || 0);

  const { freeProducts, linkedProducts, suggested } = useMemo(() => {
    const products = menu.data?.products ?? [];
    const recipes = menu.data?.recipes ?? [];
    const withRecipe = new Set(recipes.map((r) => r.product_id));
    const free = products.filter((p) => !withRecipe.has(p.id));
    const linked = form.id
      ? products.filter((p) => {
          const [only, ...more] = recipes.filter((r) => r.product_id === p.id);
          return (
            only !== undefined &&
            more.length === 0 &&
            only.item_id === form.id &&
            Number(only.quantity) === 1
          );
        })
      : [];
    // A new item named like a menu product with no recipe is most likely that product, bought ready.
    const match = !form.id
      ? free.find((p) =>
          [p.name, p.name_ar].some((n) => sameName(n, form.name) || sameName(n, form.name_ar)),
        )
      : undefined;
    return { freeProducts: free, linkedProducts: linked, suggested: match };
  }, [menu.data, form.id, form.name, form.name_ar]);
  const sellAsId = sellAs ?? suggested?.id ?? "none";
  const sellAsProduct = freeProducts.find((p) => p.id === sellAsId);
  const productLabel = (p: { name: string; name_ar: string | null }) =>
    ar ? p.name_ar || p.name : p.name;

  const save = useMutation({
    mutationFn: async () => {
      if (!form.name.trim() && !form.name_ar.trim()) throw new Error(t("inv.nameRequired"));
      if (!Number.isFinite(unitCost) || unitCost < 0)
        throw new Error(
          ar ? "تكلفة الوحدة لازم تكون رقم موجب" : "Unit cost must be a positive number",
        );
      if (!wasteValid) throw new Error(ar ? "نسبة الهالك من 0 إلى 100" : "Waste must be 0–100%");
      let id = form.id;
      if (id) {
        const { error } = await supabase
          .from("inventory_items")
          .update({
            name: form.name.trim() || form.name_ar.trim(),
            name_ar: form.name_ar.trim() || null,
            sku: form.sku.trim() || null,
            unit: form.unit,
            cost_per_unit: unitCost,
            min_qty: Number(form.min_qty || 0),
          })
          .eq("id", id);
        if (error) throw error;
      } else {
        // Item + opening balance land in one database transaction.
        const { data, error } = await supabase.rpc("create_inventory_item", {
          _name: form.name.trim() || form.name_ar.trim(),
          ...(form.name_ar.trim() ? { _name_ar: form.name_ar.trim() } : {}),
          _unit: form.unit,
          ...(form.sku.trim() ? { _sku: form.sku.trim() } : {}),
          _cost_per_unit: unitCost,
          _min_qty: Number(form.min_qty || 0),
          _opening_qty: Number(form.opening_qty || 0),
          ...(currentBranchId ? { _branch_id: currentBranchId } : {}),
        });
        if (error) throw error;
        id = data ?? undefined;
      }
      const pct = Number(form.waste_pct || 0);
      if (id && pct !== Number(initial.waste_pct || 0)) {
        const { error } = await supabase.rpc("set_item_waste_pct", {
          _item_id: id,
          _waste_pct: pct,
        });
        if (error) throw error;
      }
      if (!id || !sellAsProduct) return null;
      // The item is saved by now; a failed link is reported without failing the save.
      try {
        const { count, error: countError } = await supabase
          .from("product_recipes")
          .select("id", { count: "exact", head: true })
          .eq("product_id", sellAsProduct.id);
        if (countError) throw countError;
        if (count) {
          return ar
            ? `"${productLabel(sellAsProduct)}" بقى له وصفة، فما اتربطش. راجعه من شاشة المنيو.`
            : `"${productLabel(sellAsProduct)}" already has a recipe, so it was not linked.`;
        }
        const { error } = await supabase
          .from("product_recipes")
          .insert({ product_id: sellAsProduct.id, item_id: id, quantity: 1 });
        if (error) throw error;
      } catch (e) {
        return ar
          ? `الصنف اتحفظ، بس الربط بالمنتج ما تمش: ${friendlyError(e, lang)}`
          : `Item saved, but linking it to the product failed: ${friendlyError(e, lang)}`;
      }
      toast.success(
        ar
          ? `اتربط بـ "${productLabel(sellAsProduct)}". كل واحد يتباع هيتخصم من المخزون وياخد تكلفته.`
          : `Linked to "${productLabel(sellAsProduct)}". Each one sold takes one from stock at its cost.`,
      );
      return null;
    },
    onSuccess: async (linkProblem) => {
      if (linkProblem) toast.error(linkProblem);
      ["ready-product-links", "recipes", "product-recipe-links"].forEach((k) =>
        qc.invalidateQueries({ queryKey: [k] }),
      );
      toast.success(t("common.saved"));
      onOpenChange(false);
      await onSaved();
    },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  const numeric = "text-end font-mono tabular-nums";

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[92vh] overflow-y-auto sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>{isNew ? t("inv.newItem") : t("inv.editItem")}</DialogTitle>
          <DialogDescription>
            {ar
              ? "بيانات الخامة، تكلفتها الأساسية، ونسبة الهالك المتوقعة — كل واحدة في مكانها."
              : "The item's details, its base cost and its expected waste — each in its own place."}
          </DialogDescription>
        </DialogHeader>

        <form
          className="space-y-4"
          onSubmit={(e) => {
            e.preventDefault();
            save.mutate();
          }}
        >
          <Section icon={Package} title={ar ? "بيانات الصنف" : "Item details"}>
            <div className="grid gap-4 sm:grid-cols-2">
              <Field id="inv-name-ar" label={t("menu.nameAr")}>
                <Input
                  id="inv-name-ar"
                  dir="rtl"
                  value={form.name_ar}
                  placeholder={ar ? "مثال: لبن كامل الدسم" : "e.g. لبن كامل الدسم"}
                  onChange={(e) => set({ name_ar: e.target.value })}
                />
              </Field>
              <Field id="inv-name-en" label={t("menu.nameEn")}>
                <Input
                  id="inv-name-en"
                  dir="ltr"
                  value={form.name}
                  placeholder="e.g. Full-cream milk"
                  onChange={(e) => set({ name: e.target.value })}
                />
              </Field>
              <Field id="inv-sku" label={t("inv.sku")} hint={ar ? "اختياري" : "Optional"}>
                <Input
                  id="inv-sku"
                  dir="ltr"
                  className="font-mono"
                  value={form.sku}
                  onChange={(e) => set({ sku: e.target.value })}
                />
              </Field>
              <Field
                id="inv-unit"
                label={t("inv.unit")}
                hint={
                  ar
                    ? "الوحدة اللي بتتحسب بيها التكلفة والمخزون"
                    : "Stock and cost are counted in this unit"
                }
              >
                <Select value={form.unit} onValueChange={(unit) => set({ unit })}>
                  <SelectTrigger id="inv-unit">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {INVENTORY_UNITS.map((unit) => (
                      <SelectItem key={unit} value={unit}>
                        {unit}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </Field>
            </div>
          </Section>

          {(freeProducts.length > 0 || linkedProducts.length > 0) && (
            <Section
              icon={ShoppingBag}
              title={ar ? "بيتباع جاهز في المنيو؟" : "Sold as-is on the menu?"}
              hint={
                ar
                  ? 'لو بتشتري الصنف ده جاهز وبتبيعه زي ما هو (زي الكانز أو حلويات جاهزة)، اختار المنتج بتاعه. لو خامة بتدخل في وصفات، سيبها "لا".'
                  : 'If you buy this ready and sell it as it is (cans, ready desserts), pick its menu product. Leave "No" for an ingredient used in recipes.'
              }
            >
              {linkedProducts.length > 0 && (
                <p className="rounded-lg bg-muted p-3 text-xs leading-relaxed">
                  {ar ? "مربوط بالفعل بـ: " : "Already sold as: "}
                  <span className="font-semibold">
                    {linkedProducts.map(productLabel).join("، ")}
                  </span>
                </p>
              )}
              {freeProducts.length > 0 && (
                <Field
                  id="inv-sell-as"
                  label={ar ? "منتج المنيو" : "Menu product"}
                  hint={
                    sellAsProduct
                      ? ar
                        ? `${sellAs === null ? "لقينا منتج بنفس الاسم فاخترناه، غيّره لو مش هو. " : ""}كل 1 ${form.unit} من الصنف ده = 1 "${productLabel(sellAsProduct)}". لما يتباع واحد يتخصم واحد من المخزون وياخد تكلفته، ولما تدخل فاتورة شراء التكلفة بتتعدل لوحدها، حتى على اللي اتباع قبل كده.${form.unit !== "pcs" ? " خلي الوحدة pcs (قطعة)." : ""}`
                        : `${sellAs === null ? "We found a product with the same name; change it if it is not this one. " : ""}1 ${form.unit} of this item = 1 "${productLabel(sellAsProduct)}". Each sale takes one from stock at its cost, and purchase invoices re-cost earlier sales automatically.${form.unit !== "pcs" ? " Set the unit to pcs." : ""}`
                      : undefined
                  }
                >
                  <Select
                    value={sellAsId}
                    onValueChange={(v) => {
                      setSellAs(v);
                      if (v !== "none") set({ unit: "pcs" });
                    }}
                  >
                    <SelectTrigger id="inv-sell-as">
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="none">
                        {ar ? "لا، دي خامة بتدخل في وصفات" : "No, it is an ingredient"}
                      </SelectItem>
                      {freeProducts.map((p) => (
                        <SelectItem key={p.id} value={p.id}>
                          {productLabel(p)}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </Field>
              )}
            </Section>
          )}

          <Section
            icon={Coins}
            title={ar ? "التكلفة والمخزون" : "Cost & stock"}
            hint={
              ar
                ? "تكلفة الشراء الصافية لكل وحدة، من غير أي هالك. دي تكلفة أول المدة لحد أول فاتورة شراء، وبعدها السيستم بيحسب المتوسط لوحده ويعدّل تكلفة المبيعات اللي أرباحها لسه ما اتوزعتش."
                : "The plain purchase cost per unit — no waste added. It is the opening cost until the first purchase invoice; after that the average updates by itself and re-costs sales not yet paid out."
            }
          >
            {isNew && (
              <div className="grid gap-4 sm:grid-cols-2">
                <Field id="inv-opening" label={t("inv.totalQty")} suffix={form.unit}>
                  <Input
                    id="inv-opening"
                    className={cn(numeric, "pe-12")}
                    inputMode="decimal"
                    value={form.opening_qty}
                    onChange={(e) => {
                      const opening_qty = e.target.value;
                      const d = deriveUnitCost(form.total_cost, opening_qty);
                      set({ opening_qty, ...(d ? { cost_per_unit: d } : {}) });
                    }}
                  />
                </Field>
                <Field id="inv-total" label={t("inv.totalCost")} suffix={currency}>
                  <Input
                    id="inv-total"
                    className={cn(numeric, "pe-12")}
                    inputMode="decimal"
                    value={form.total_cost}
                    onChange={(e) => {
                      const total_cost = e.target.value;
                      const d = deriveUnitCost(total_cost, form.opening_qty);
                      set({ total_cost, ...(d ? { cost_per_unit: d } : {}) });
                    }}
                  />
                </Field>
              </div>
            )}
            <div className="grid gap-4 sm:grid-cols-2">
              <Field
                id="inv-unit-cost"
                label={t("inv.unitCost")}
                suffix={`${currency} / ${form.unit}`}
                hint={
                  derived
                    ? t("inv.computedUnitCost")
                        .replace("{price}", formatMoney(Number(derived), currency, lang))
                        .replace("{unit}", form.unit)
                    : undefined
                }
              >
                <Input
                  id="inv-unit-cost"
                  className={cn(numeric, "pe-24")}
                  inputMode="decimal"
                  value={form.cost_per_unit}
                  onChange={(e) => set({ cost_per_unit: e.target.value })}
                />
              </Field>
              <Field
                id="inv-min"
                label={t("inv.minQty")}
                suffix={form.unit}
                hint={
                  ar
                    ? "هتوصلك تنبيه لما الرصيد يوصل للرقم ده"
                    : "You get an alert when stock reaches this level"
                }
              >
                <Input
                  id="inv-min"
                  className={cn(numeric, "pe-12")}
                  inputMode="decimal"
                  value={form.min_qty}
                  onChange={(e) => set({ min_qty: e.target.value })}
                />
              </Field>
            </div>
          </Section>

          <Section
            icon={Trash2}
            tone="muted"
            title={ar ? "متابعة الهالك" : "Waste tracking"}
            hint={
              ar
                ? "رقم داخلي للمتابعة بس — مش بيغيّر تكلفة الصنف ولا سعر المنيو."
                : "An internal tracking figure only — it never changes the item cost or menu prices."
            }
          >
            <div className="grid items-start gap-4 sm:grid-cols-2">
              <Field
                id="inv-waste"
                label={ar ? "نسبة الهالك المتوقعة" : "Expected waste"}
                suffix="%"
                hint={
                  !wasteValid ? (
                    <span className="text-destructive">
                      {ar ? "من 0 إلى 100" : "Between 0 and 100"}
                    </span>
                  ) : undefined
                }
              >
                <Input
                  id="inv-waste"
                  className={cn(numeric, "pe-8", !wasteValid && "border-destructive")}
                  inputMode="decimal"
                  value={form.waste_pct}
                  onChange={(e) => set({ waste_pct: e.target.value })}
                />
              </Field>
              <div className="flex gap-2 rounded-lg bg-card p-3 text-[11px] leading-relaxed text-muted-foreground">
                <Info className="mt-0.5 size-3.5 shrink-0 text-primary" aria-hidden />
                <p>
                  {ar
                    ? `بتستخدم كسماحية في الجرد. ${waste > 0 && wasteValid ? `الخسارة المتوقعة ≈ ${formatMoney((unitCost * waste) / 100, currency, lang)} لكل ${form.unit}.` : "سيبها 0% لو مفيش هالك متوقع."} الهالك الفعلي بيتسجل من "تسجيل هالك".`
                    : `Used as the stocktake tolerance. ${waste > 0 && wasteValid ? `Expected loss ≈ ${formatMoney((unitCost * waste) / 100, currency, lang)} per ${form.unit}.` : "Leave at 0% when no loss is expected."} Actual losses are logged with "Log waste".`}
                </p>
              </div>
            </div>
          </Section>

          <DialogFooter className="pt-1">
            <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
              {t("common.cancel")}
            </Button>
            <Button type="submit" disabled={save.isPending || !wasteValid}>
              {save.isPending ? (ar ? "جاري الحفظ…" : "Saving…") : t("common.save")}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
