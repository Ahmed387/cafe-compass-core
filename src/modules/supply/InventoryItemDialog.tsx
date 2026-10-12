import { useMutation } from "@tanstack/react-query";
import { Coins, Info, Package, Trash2, type LucideIcon } from "lucide-react";
import { useEffect, useState, type ReactNode } from "react";
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
  const [form, setForm] = useState<InventoryItemForm>(initial);
  useEffect(() => {
    if (open) setForm(initial);
  }, [open, initial]);

  const isNew = !form.id;
  const set = (patch: Partial<InventoryItemForm>) => setForm((prev) => ({ ...prev, ...patch }));
  const derived = isNew ? deriveUnitCost(form.total_cost, form.opening_qty) : null;
  const waste = Number(form.waste_pct);
  const wasteValid =
    form.waste_pct.trim() === "" || (Number.isFinite(waste) && waste >= 0 && waste <= 100);
  const unitCost = Number(form.cost_per_unit || 0);

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
    },
    onSuccess: async () => {
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

          <Section
            icon={Coins}
            title={ar ? "التكلفة والمخزون" : "Cost & stock"}
            hint={
              ar
                ? "تكلفة الشراء الصافية لكل وحدة، من غير أي هالك."
                : "The plain purchase cost per unit — no waste added."
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
