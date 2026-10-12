import { useMutation, useQuery } from "@tanstack/react-query";
import { Minus, Plus, Printer, QrCode, Search, ShoppingCart, Trash2 } from "lucide-react";
import { useMemo, useState } from "react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { supabase } from "@/integrations/supabase/client";
import { formatMoney, friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { printMenuPoster } from "@/lib/labels";
import { printReceipt } from "@/lib/receipt";
import { CAN_SURCHARGE, softOpeningImage, type ServeType, type SoftOpeningAddon, type SoftOpeningItem, type SoftOpeningVariant } from "@/lib/soft-opening-catalog";
import { getSoftOpeningCatalog } from "@/lib/soft-opening.functions";

type CartRow = {
  key: string;
  itemId: string | null;
  variantId: string | null;
  addonIds: string[];
  inCan: boolean;
  serveType: ServeType;
  baseName: string;
  name: string;
  price: number;
  quantity: number;
};

const numberValue = (value: string) => {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
};

export function SoftOpeningTicket({
  branchId,
  companyName,
  branchName,
  cashierName,
  currency,
  footerMessage,
  canDiscount,
}: {
  branchId: string | null;
  companyName: string;
  branchName: string | null;
  cashierName: string | null;
  currency: string;
  footerMessage?: string | null;
  canDiscount: boolean;
}) {
  const { lang, t } = useI18n();
  const ar = lang === "ar";
  const catalog = useQuery({ queryKey: ["soft-opening-catalog"], queryFn: () => getSoftOpeningCatalog() });
  const [category, setCategory] = useState("all");
  const [search, setSearch] = useState("");
  const [cart, setCart] = useState<CartRow[]>([]);
  const [variantItem, setVariantItem] = useState<SoftOpeningItem | null>(null);
  const [customOpen, setCustomOpen] = useState(false);
  const [customName, setCustomName] = useState("");
  const [customPrice, setCustomPrice] = useState("");
  const [method, setMethod] = useState<"cash" | "card">("cash");
  const [tendered, setTendered] = useState("");
  const [discount, setDiscount] = useState("");
  const [discountReason, setDiscountReason] = useState("");
  const [discountMode, setDiscountMode] = useState<"amount" | "percent">("amount");
  const [notes, setNotes] = useState("");
  const [pickVariant, setPickVariant] = useState<SoftOpeningVariant | null>(null);
  const [pickAddons, setPickAddons] = useState<string[]>([]);
  const [pickCan, setPickCan] = useState(false);

  const items = useMemo(() => {
    const needle = search.trim().toLocaleLowerCase("ar");
    return (catalog.data ?? []).flatMap((group) =>
      group.items.filter(
        (item) =>
          (category === "all" || group.id === category) &&
          (!needle || `${item.name_ar} ${item.name_en}`.toLocaleLowerCase("ar").includes(needle)),
      ),
    );
  }, [catalog.data, category, search]);

  const subtotal = cart.reduce((sum, row) => sum + row.price * row.quantity, 0);
  const rawDiscount = Math.max(numberValue(discount), 0);
  const discountAmount = Math.round(Math.min(discountMode === "percent" ? (subtotal * Math.min(rawDiscount, 100)) / 100 : rawDiscount, subtotal) * 100) / 100;
  const total = Math.max(subtotal - discountAmount, 0);
  const change = Math.max(numberValue(tendered) - total, 0);

  const openItem = (item: SoftOpeningItem) => {
    if (item.variants.length === 0 && item.addons.length === 0) {
      addItem(item, null, [], false);
      return;
    }
    setPickVariant(item.variants[0] ?? null);
    setPickAddons([]);
    setPickCan(false);
    setVariantItem(item);
  };

  const rowName = (baseName: string, extras: string[], inCan: boolean) =>
    [baseName, ...extras, ...(inCan ? [ar ? `كان +${CAN_SURCHARGE}` : `CAN +${CAN_SURCHARGE}`] : [])].join(" · ");

  const addItem = (item: SoftOpeningItem, variant: SoftOpeningVariant | null, addonIds: string[], inCan: boolean) => {
    const variantId = variant?.id ?? null;
    const key = `${item.id}:${variantId ?? "base"}:${[...addonIds].sort().join(",")}:${inCan ? "can" : ""}`;
    const addons = item.addons.filter((addon: SoftOpeningAddon) => addonIds.includes(addon.id));
    const baseName = `${ar ? item.name_ar : item.name_en}${variant ? ` — ${ar ? variant.name_ar : variant.name_en}` : ""}`;
    const extras = addons.map((addon) => `+${ar ? addon.name_ar : addon.name_en}`);
    const price = (variant?.price ?? item.price) + addons.reduce((sum, addon) => sum + addon.price, 0) + (inCan ? CAN_SURCHARGE : 0);
    setCart((current) => {
      const existing = current.find((row) => row.key === key);
      if (existing) return current.map((row) => (row.key === key ? { ...row, quantity: row.quantity + 1 } : row));
      return [...current, { key, itemId: item.id, variantId, addonIds, inCan, serveType: item.serve_type, baseName: [baseName, ...extras].join(" · "), name: rowName(baseName, extras, inCan), price, quantity: 1 }];
    });
    setVariantItem(null);
  };

  const toggleCan = (key: string) =>
    setCart((current) =>
      current.map((row) => {
        if (row.key !== key || row.serveType !== "cold") return row;
        const inCan = !row.inCan;
        return { ...row, inCan, key: `${row.key}~${inCan ? "c" : "n"}`, price: row.price + (inCan ? CAN_SURCHARGE : -CAN_SURCHARGE), name: rowName(row.baseName, [], inCan) };
      }),
    );

  const setQuantity = (key: string, quantity: number) =>
    setCart((current) =>
      quantity < 1 ? current.filter((row) => row.key !== key) : current.map((row) => (row.key === key ? { ...row, quantity } : row)),
    );

  const addCustom = () => {
    const name = customName.trim();
    const price = numberValue(customPrice);
    if (!name || price <= 0) return;
    setCart((current) => [
      ...current,
      { key: `custom-${crypto.randomUUID()}`, itemId: null, variantId: null, addonIds: [], inCan: false, serveType: "none", baseName: name, name, price, quantity: 1 },
    ]);
    setCustomName("");
    setCustomPrice("");
    setCustomOpen(false);
  };

  const submit = useMutation({
    mutationFn: async () => {
      if (!branchId) throw new Error(ar ? "اختر الفرع أولًا" : "Select a branch first");
      const { data, error } = await supabase.rpc("create_soft_opening_order", {
        _branch_id: branchId,
        _items: cart.map((row) => ({
          ...(row.itemId ? { item_id: row.itemId } : { name: row.name, unit_price: row.price }),
          ...(row.variantId ? { variant_id: row.variantId } : {}),
          ...(row.addonIds.length ? { addon_ids: row.addonIds } : {}),
          ...(row.inCan ? { in_can: true } : {}),
          quantity: row.quantity,
        })),
        _method_key: method,
        _discount_amount: discountAmount,
        ...(notes.trim() ? { _notes: notes.trim() } : {}),
        ...(method === "cash" ? { _tendered: numberValue(tendered) } : {}),
        ...(discountAmount > 0 ? { _discount_reason: discountReason.trim() } : {}),
      });
      if (error) throw error;
      return Array.isArray(data) ? data[0] : null;
    },
    onSuccess: (created) => {
      printReceipt({
        companyName,
        branchName,
        orderNumber: created?.out_number ?? "20S",
        createdAt: new Date().toISOString(),
        orderType: "Takeaway",
        cashier: cashierName,
        lines: cart.map((row, index) => ({ ...(index === cart.length - 1 && notes.trim() ? { notes: `Note: ${notes.trim()}` } : {}), product_name: row.name, quantity: row.quantity, unit_price: row.price, line_total: row.price * row.quantity, status: "active" })),
        subtotal,
        discount: discountAmount,
        total,
        payments: [{ method_key: method, amount: total }],
        footerMessage: footerMessage ?? null,
        change: method === "cash" ? change : null,
        currency,
        lang: "en",
        labels: { order: t("receipt.order"), subtotal: t("receipt.subtotal"), discount: t("receipt.discount"), total: t("receipt.total"), refunded: t("receipt.refunded"), customer: t("receipt.customer"), thanks: t("receipt.thanks"), voided: t("receipt.voided") },
      });
      toast.success(ar ? "تم إتمام الطلب وطباعة الفاتورة" : "Order completed and printed");
      setCart([]);
      setTendered("");
      setDiscount("");
      setDiscountReason("");
      setNotes("");
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const printQr = async () => {
    const url = `${window.location.origin}/menu`;
    const ok = await printMenuPoster({ url, companyName, branchName: branchName ?? "", headline: "20s SPECIALTY COFFEE", hint: "امسح الرمز لتصفح المنيو", lang: "ar" });
    if (!ok) toast.error(ar ? "اسمح بالنوافذ المنبثقة للطباعة" : "Allow pop-ups to print");
  };

  const canSubmit = Boolean(branchId && cart.length && total > 0) && (method === "card" || numberValue(tendered) >= total) && (!discountAmount || Boolean(discountReason.trim()));

  return (
    <div className="grid gap-4 xl:grid-cols-[minmax(0,1fr)_380px]">
      <section className="min-w-0 space-y-4">
        <div className="sticky top-0 z-20 space-y-3 border-b bg-background/95 pb-3 backdrop-blur">
          <div className="flex gap-2 overflow-x-auto pb-1">
            <Button size="sm" variant={category === "all" ? "default" : "outline"} onClick={() => setCategory("all")}>{ar ? "الكل" : "All"}</Button>
            {(catalog.data ?? []).map((group) => (
              <Button key={group.id} size="sm" variant={category === group.id ? "default" : "outline"} onClick={() => setCategory(group.id)}>{ar ? group.name_ar : group.name_en}</Button>
            ))}
          </div>
          <div className="flex gap-2">
            <div className="relative flex-1">
              <Search className="absolute start-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
              <Input value={search} onChange={(event) => setSearch(event.target.value)} placeholder={ar ? "ابحث في المنيو..." : "Search menu..."} className="ps-9" />
            </div>
            <Button variant="outline" onClick={printQr} title={ar ? "طباعة QR المنيو" : "Print menu QR"}><QrCode className="size-4" /><span className="hidden sm:inline">{ar ? "طباعة QR" : "Print QR"}</span></Button>
          </div>
        </div>

        {catalog.isLoading ? (
          <div className="grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-4">{Array.from({ length: 8 }).map((_, index) => <div key={index} className="aspect-[4/5] animate-pulse rounded-md bg-muted" />)}</div>
        ) : (
          <div className="grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-4">
            {items.map((item) => (
              <Button key={item.id} variant="outline" className="h-auto min-w-0 flex-col items-stretch overflow-hidden p-0 text-start" onClick={() => openItem(item)}>
                <img src={softOpeningImage(item.image_key, item.serve_type)} alt={item.name_ar} className="aspect-square w-full object-cover" />
                <span className="grid min-w-0 gap-1 p-3">
                  <span className="truncate font-bold">{ar ? item.name_ar : item.name_en}</span>
                  <span className="truncate text-xs text-muted-foreground" dir="ltr">{ar ? item.name_en : item.name_ar}</span>
                  <span className="flex items-center justify-between gap-1">
                    <Badge variant="secondary">{formatMoney(item.price, currency, lang)}</Badge>
                    {item.serve_type === "cold" && <span className="text-[10px] text-muted-foreground">🥫 +{CAN_SURCHARGE}</span>}{item.variants.length > 0 && <span className="text-[10px] text-muted-foreground">{ar ? "خيارات" : "Options"}</span>}
                  </span>
                </span>
              </Button>
            ))}
          </div>
        )}
      </section>

      <Card className="h-fit xl:sticky xl:top-4">
        <CardHeader className="pb-3"><CardTitle className="flex items-center justify-between text-base"><span className="flex items-center gap-2"><ShoppingCart className="size-4" />{ar ? "الطلب الحالي" : "Current order"}</span><Badge>{cart.reduce((sum, row) => sum + row.quantity, 0)}</Badge></CardTitle></CardHeader>
        <CardContent className="space-y-4">
          <div className="max-h-[38vh] space-y-2 overflow-y-auto">
            {cart.length === 0 ? <p className="py-8 text-center text-sm text-muted-foreground">{ar ? "اضغط على صنف لإضافته" : "Tap an item to add it"}</p> : cart.map((row) => (
              <div key={row.key} className="grid grid-cols-[1fr_auto] gap-2 rounded-md border p-2">
                <div className="min-w-0"><p className="truncate text-sm font-semibold">{row.name}</p><p className="text-xs text-muted-foreground">{formatMoney(row.price * row.quantity, currency, lang)}</p></div>
                <div className="flex items-center gap-1">
                  {row.serveType === "cold" && <Button size="sm" variant={row.inCan ? "default" : "outline"} className="h-7 px-2 text-xs" onClick={() => toggleCan(row.key)} title={ar ? "تقديم في كان" : "Serve in can"}>🥫 +{CAN_SURCHARGE}</Button>}
                  <Button size="icon" variant="ghost" className="size-7" onClick={() => setQuantity(row.key, row.quantity - 1)}><Minus className="size-3" /></Button>
                  <span className="w-5 text-center text-sm tabular-nums">{row.quantity}</span>
                  <Button size="icon" variant="ghost" className="size-7" onClick={() => setQuantity(row.key, row.quantity + 1)}><Plus className="size-3" /></Button>
                  <Button size="icon" variant="ghost" className="size-7 text-destructive" onClick={() => setQuantity(row.key, 0)} aria-label={ar ? "حذف" : "Delete"}><Trash2 className="size-3" /></Button>
                </div>
              </div>
            ))}
          </div>
          <Button variant="outline" className="w-full border-dashed" onClick={() => setCustomOpen(true)}><Plus className="size-4" />{ar ? "صنف حر إضافي" : "Add custom item"}</Button>
          <div><Label htmlFor="so-notes">{ar ? "ملاحظة على الطلب" : "Order note"}</Label><Input id="so-notes" maxLength={500} value={notes} onChange={(event) => setNotes(event.target.value)} placeholder={ar ? "مثال: سكر خفيف" : "e.g. less sugar"} /></div>
          {canDiscount && <div className="space-y-2"><div className="flex items-center justify-between"><Label htmlFor="so-discount">{ar ? "الخصم" : "Discount"}</Label><div className="flex gap-1"><Button size="sm" className="h-7 px-2" variant={discountMode === "amount" ? "default" : "outline"} onClick={() => setDiscountMode("amount")}>{currency}</Button><Button size="sm" className="h-7 px-2" variant={discountMode === "percent" ? "default" : "outline"} onClick={() => setDiscountMode("percent")}>%</Button></div></div><div className="grid grid-cols-2 gap-2"><Input id="so-discount" inputMode="decimal" value={discount} onChange={(event) => setDiscount(event.target.value)} placeholder={discountMode === "percent" ? "%" : currency} /><Input aria-label={ar ? "سبب الخصم" : "Reason"} placeholder={ar ? "سبب الخصم" : "Reason"} value={discountReason} onChange={(event) => setDiscountReason(event.target.value)} disabled={!discountAmount} /></div></div>}
          <div className="space-y-1 rounded-md bg-muted p-3 text-sm"><div className="flex justify-between"><span>{ar ? "الإجمالي الفرعي" : "Subtotal"}</span><span>{formatMoney(subtotal, currency, lang)}</span></div>{discountAmount > 0 && <div className="flex justify-between text-destructive"><span>{ar ? "الخصم" : "Discount"}</span><span>-{formatMoney(discountAmount, currency, lang)}</span></div>}<div className="flex justify-between border-t pt-2 text-lg font-bold"><span>{ar ? "الإجمالي" : "Total"}</span><span>{formatMoney(total, currency, lang)}</span></div></div>
          <div className="grid grid-cols-2 gap-2"><Button variant={method === "cash" ? "default" : "outline"} onClick={() => setMethod("cash")}>💵 {ar ? "كاش" : "Cash"}</Button><Button variant={method === "card" ? "default" : "outline"} onClick={() => setMethod("card")}>💳 {ar ? "فيزا" : "Card"}</Button></div>
          {method === "cash" && <div><Label htmlFor="so-tendered">{ar ? "المبلغ المستلم" : "Tendered cash"}</Label><Input id="so-tendered" inputMode="decimal" value={tendered} onChange={(event) => setTendered(event.target.value)} /><p className="mt-1 text-xs text-muted-foreground">{ar ? "الباقي" : "Change"}: {formatMoney(change, currency, lang)}</p></div>}
          <Button className="w-full" disabled={!canSubmit || submit.isPending} onClick={() => submit.mutate()}><Printer className="size-4" />{submit.isPending ? (ar ? "جارٍ الحفظ..." : "Saving...") : ar ? "إتمام وطباعة الفاتورة" : "Complete & print"}</Button>
        </CardContent>
      </Card>

      <Dialog open={Boolean(variantItem)} onOpenChange={(open) => !open && setVariantItem(null)}><DialogContent><DialogHeader><DialogTitle>{variantItem ? (ar ? variantItem.name_ar : variantItem.name_en) : ""}</DialogTitle></DialogHeader>
        {variantItem && <div className="space-y-4">
          {variantItem.variants.length > 0 && <div className="grid grid-cols-2 gap-2">{variantItem.variants.map((variant) => <Button key={variant.id} variant={pickVariant?.id === variant.id ? "default" : "outline"} className="h-16 flex-col" onClick={() => setPickVariant(variant)}><span>{ar ? variant.name_ar : variant.name_en}</span><strong>{formatMoney(variant.price, currency, lang)}</strong></Button>)}</div>}
          {variantItem.addons.length > 0 && <div className="flex flex-wrap gap-2">{variantItem.addons.map((addon) => <Button key={addon.id} size="sm" variant={pickAddons.includes(addon.id) ? "default" : "outline"} onClick={() => setPickAddons((current) => current.includes(addon.id) ? current.filter((id) => id !== addon.id) : [...current, addon.id])}>{ar ? addon.name_ar : addon.name_en} +{addon.price}</Button>)}</div>}
          {variantItem.serve_type === "cold" && <Button size="sm" variant={pickCan ? "default" : "outline"} onClick={() => setPickCan((value) => !value)}>🥫 {ar ? "تقديم في كان" : "Serve in can"} +{CAN_SURCHARGE}</Button>}
        </div>}
        <DialogFooter><Button disabled={Boolean(variantItem?.variants.length) && !pickVariant} onClick={() => variantItem && addItem(variantItem, pickVariant, pickAddons, pickCan)}>{ar ? "إضافة للطلب" : "Add to order"}</Button></DialogFooter>
      </DialogContent></Dialog>
      <Dialog open={customOpen} onOpenChange={setCustomOpen}><DialogContent><DialogHeader><DialogTitle>{ar ? "صنف حر إضافي" : "Custom item"}</DialogTitle></DialogHeader><div className="space-y-3"><div><Label htmlFor="custom-name">{ar ? "اسم الصنف" : "Item name"}</Label><Input id="custom-name" value={customName} onChange={(event) => setCustomName(event.target.value)} autoFocus /></div><div><Label htmlFor="custom-price">{ar ? "السعر" : "Price"}</Label><Input id="custom-price" inputMode="decimal" value={customPrice} onChange={(event) => setCustomPrice(event.target.value)} onKeyDown={(event) => event.key === "Enter" && addCustom()} /></div></div><DialogFooter><Button variant="outline" onClick={() => setCustomOpen(false)}>{ar ? "إلغاء" : "Cancel"}</Button><Button onClick={addCustom} disabled={!customName.trim() || numberValue(customPrice) <= 0}>{ar ? "إضافة" : "Add"}</Button></DialogFooter></DialogContent></Dialog>
    </div>
  );
}