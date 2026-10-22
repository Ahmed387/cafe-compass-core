import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  ListChecks,
  Minus,
  PackageCheck,
  Plus,
  ReceiptText,
  Trash2,
  type LucideIcon,
} from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import type { OrderDetails } from "@/components/orders/OrderDetailsDialog";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
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
import { normalizeTender } from "@/core/finance/formulas";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { formatMoney, friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { invoiceSequence } from "@/lib/receipt";
import { cn } from "@/lib/utils";
import {
  WasteBearerPicker,
  bearerReady,
  type WasteBearer,
} from "@/modules/supply/WasteBearerPicker";

type PayloadEntry = { order_item_id?: string; quantity?: number };
type Disposition = "restock" | "waste";
type LineState = { qty: number; disposition: Disposition };
type Mode = "full" | "partial";
type RefundResult = { amount?: number; wallet_amount?: number; reward_clawback?: number; cash_withheld?: number };

/** One line after a refund: what went back as money, to the wallet, and any reward taken back. */
function refundSummary(result: RefundResult | null, currency: string, lang: "en" | "ar") {
  if (!result) return undefined;
  const ar = lang === "ar";
  const money = (v: number | undefined) => formatMoney(Number(v ?? 0), currency, lang);
  const parts = [`${ar ? "رجع للعميل" : "Refunded"} ${money(result.amount)}`];
  if (Number(result.wallet_amount ?? 0) > 0) parts.push(`${ar ? "ورجع لمحفظته" : "back to wallet"} ${money(result.wallet_amount)}`);
  if (Number(result.cash_withheld ?? 0) > 0) {
    parts.push(ar
      ? `واتخصم ${money(result.cash_withheld)} مكافأة كاش باك كان صرفها`
      : `${money(result.cash_withheld)} cashback reward already spent was kept`);
  } else if (Number(result.reward_clawback ?? 0) > 0) {
    parts.push(ar
      ? `واتسحب ${money(result.reward_clawback)} مكافأة كاش باك من محفظته`
      : `${money(result.reward_clawback)} cashback reward taken back from the wallet`);
  }
  return parts.join(ar ? "، " : ", ");
}

function ModeCard({
  active,
  icon: Icon,
  title,
  hint,
  onClick,
}: {
  active: boolean;
  icon: LucideIcon;
  title: string;
  hint: string;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      role="radio"
      aria-checked={active}
      onClick={onClick}
      className={cn(
        "flex items-start gap-3 rounded-xl border p-3 text-start transition-all active:scale-[0.98]",
        active
          ? "border-primary bg-primary/8 shadow-sm ring-2 ring-primary/30"
          : "border-border hover:border-primary/40 hover:bg-tint",
      )}
    >
      <span
        className={cn(
          "flex size-9 shrink-0 items-center justify-center rounded-lg",
          active ? "bg-gradient-module text-primary-foreground" : "bg-muted text-muted-foreground",
        )}
      >
        <Icon className="size-4" aria-hidden />
      </span>
      <span className="min-w-0">
        <span className="block text-sm font-semibold">{title}</span>
        <span className="block text-[11px] leading-snug text-muted-foreground">{hint}</span>
      </span>
    </button>
  );
}

/**
 * Customer returns, two clear paths:
 *  - Full invoice return: everything still on the bill goes back to stock, the rest of
 *    the money is refunded and the bill closes.
 *  - Partial item return: pick items / quantities; the rest of the order stays active.
 * Cashiers can do this on their own open shift without a manager.
 */
export function OrderRefundDialog({
  order,
  open,
  onClose,
  initialMode = "partial",
}: {
  order: OrderDetails | null;
  open: boolean;
  onClose: () => void;
  initialMode?: Mode;
}) {
  const { t, lang } = useI18n();
  const ar = lang === "ar";
  const { me } = useAuth();
  const currency = me?.company?.currency ?? "EGP";
  const queryClient = useQueryClient();
  const [mode, setMode] = useState<Mode>(initialMode);
  const [lines, setLines] = useState<Record<string, LineState>>({});
  const [reason, setReason] = useState("");
  const [method, setMethod] = useState("cash");
  // Who bears the cost of the return: the business (normal), one employee or the whole team.
  const [bearer, setBearer] = useState<WasteBearer | null>("business");
  const [blamedId, setBlamedId] = useState("");

  const activeItems = (order?.order_items ?? []).filter((item) => item.status === "active");

  // Prior refunds: how much money and how many units of each line already went back.
  const prior = useQuery({
    queryKey: ["refund-prior", order?.id],
    enabled: Boolean(order) && open,
    queryFn: async () => {
      if (!order) return { refundedCash: 0, refundedWallet: 0, refundedQty: {} as Record<string, number> };
      const { data, error } = await supabase
        .from("order_refunds")
        .select("amount, wallet_amount, cash_withheld, items_payload")
        .eq("order_id", order.id)
        .eq("status", "active");
      if (error) throw error;
      // Cash side: money handed back plus any cashback reward kept out of it.
      let refundedCash = 0;
      let refundedWallet = 0;
      const refundedQty: Record<string, number> = {};
      for (const row of data ?? []) {
        refundedCash += Number(row.amount) + Number(row.cash_withheld ?? 0);
        refundedWallet += Number(row.wallet_amount ?? 0);
        for (const entry of (row.items_payload ?? []) as PayloadEntry[]) {
          if (entry.order_item_id) {
            refundedQty[entry.order_item_id] =
              (refundedQty[entry.order_item_id] ?? 0) + Number(entry.quantity ?? 0);
          }
        }
      }
      return { refundedCash, refundedWallet, refundedQty };
    },
  });

  // The part paid from the customer's cashback wallet goes back to the wallet, not as cash.
  const payments = order?.order_payments ?? [];
  const paidTotal = payments.reduce((sum, p) => sum + Number(p.amount), 0);
  const walletPaid = payments
    .filter((p) => normalizeTender(p.method_key) === "points")
    .reduce((sum, p) => sum + Number(p.amount), 0);
  const cashLeft = Math.max(0, paidTotal - walletPaid - (prior.data?.refundedCash ?? 0));
  const walletLeft = Math.max(0, walletPaid - (prior.data?.refundedWallet ?? 0));
  const refundable = cashLeft + walletLeft;
  const remainingOf = (id: string, qty: number) => qty - (prior.data?.refundedQty[id] ?? 0);
  const fullLines = activeItems
    .map((item) => ({ item, left: remainingOf(item.id, item.quantity) }))
    .filter((entry) => entry.left > 0);

  // Server computes the exact amount; this mirrors its proportional share for display.
  const ratio =
    Number(order?.subtotal ?? 0) > 0 ? Number(order?.total ?? 0) / Number(order?.subtotal ?? 1) : 1;
  const selected = activeItems
    .map((item) => ({ item, st: lines[item.id] }))
    .filter((entry): entry is { item: OrderDetails["order_items"][number]; st: LineState } =>
      Boolean(entry.st && entry.st.qty > 0),
    );
  const share =
    mode === "full"
      ? refundable
      : ratio *
        selected.reduce(
          (sum, { item, st }) => sum + (Number(item.line_total) * st.qty) / item.quantity,
          0,
        );
  const walletBack =
    mode === "full" ? walletLeft : paidTotal > 0 ? Math.min(walletLeft, (share * walletPaid) / paidTotal) : 0;
  // Cash/card handed back; a cashback reward the customer already spent can still come off it.
  const estimate = mode === "full" ? cashLeft : Math.min(cashLeft, Math.max(0, share - walletBack));

  const ready =
    reason.trim().length >= 3 &&
    bearerReady(bearer, blamedId) &&
    (mode === "full" ? fullLines.length > 0 : selected.length > 0);

  const submit = useMutation({
    mutationFn: async () => {
      if (!order) throw new Error("Missing order");
      const common = {
        _order_id: order.id,
        _method_key: method,
        _reason: reason.trim(),
        _fault: bearer ?? "business",
        ...(bearer === "staff" ? { _staff_id: blamedId } : {}),
      };
      if (mode === "full") {
        const { data, error } = await supabase.rpc("refund_order_full", common);
        if (error) throw error;
        return data as RefundResult | null;
      }
      const { data, error } = await supabase.rpc("refund_order_items_attributed", {
        ...common,
        _items: selected.map(({ item, st }) => ({
          order_item_id: item.id,
          quantity: st.qty,
          disposition: st.disposition,
        })),
      });
      if (error) throw error;
      return data as RefundResult | null;
    },
    onSuccess: async (result) => {
      await Promise.all(
        [
          "orders",
          "orders-summary",
          "order-refunds",
          "refund-prior",
          "refunds-log",
          "customer-refunds",
          "branch-stock",
          "order-invoice",
        ].map((key) => queryClient.invalidateQueries({ queryKey: [key] })),
      );
      toast.success(t("orders.refundDone"), { description: refundSummary(result, currency, lang) });
      onClose();
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const setLine = (id: string, patch: Partial<LineState>) =>
    setLines((prev) => ({
      ...prev,
      [id]: { qty: 0, disposition: "restock" as const, ...prev[id], ...patch },
    }));

  return (
    <Dialog open={Boolean(order) && open} onOpenChange={(value) => !value && onClose()}>
      <DialogContent className="max-h-[92vh] overflow-y-auto sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>
            {ar ? "مرتجع فاتورة" : "Return"} ·{" "}
            <span className="font-mono font-bold text-primary">
              {invoiceSequence(order?.order_number ?? "1")}
            </span>
          </DialogTitle>
          <DialogDescription>
            {t("orders.refundable")}: {formatMoney(refundable, currency, lang)}
            {walletLeft > 0 &&
              ` (${ar ? "منهم" : "of which"} ${formatMoney(walletLeft, currency, lang)} ${ar ? "يرجعوا لمحفظة الكاش باك" : "back to the cashback wallet"})`}
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-4 text-sm">
          <div role="radiogroup" className="grid gap-2 sm:grid-cols-2">
            <ModeCard
              active={mode === "full"}
              icon={ReceiptText}
              title={ar ? "مرتجع فاتورة كاملة" : "Full invoice return"}
              hint={
                ar
                  ? "تتلغي الفاتورة كلها، كل الأصناف ترجع المخزن والفلوس الباقية ترجع للعميل."
                  : "Cancels the whole bill: every item back to stock, the rest of the money back."
              }
              onClick={() => setMode("full")}
            />
            <ModeCard
              active={mode === "partial"}
              icon={ListChecks}
              title={ar ? "مرتجع أصناف (جزئي)" : "Partial item return"}
              hint={
                ar
                  ? "اختار أصناف أو كميات معيّنة، والباقي من الطلب يفضل شغال."
                  : "Pick items or quantities; the rest of the order stays active."
              }
              onClick={() => setMode("partial")}
            />
          </div>

          {mode === "full" ? (
            <div
              key="full"
              className="animate-tab-in space-y-2 rounded-xl border border-border bg-muted p-3"
            >
              <p className="flex items-center gap-2 text-xs font-semibold text-muted-foreground">
                <PackageCheck className="size-4 text-success" aria-hidden />
                {ar ? "كل دول هيرجعوا للمخزن:" : "All of these go back to stock:"}
              </p>
              {fullLines.length === 0 ? (
                <p className="text-xs text-muted-foreground">
                  {ar
                    ? "كل أصناف الفاتورة اترجعت قبل كده."
                    : "Everything on this bill was already returned."}
                </p>
              ) : (
                <ul className="divide-y divide-border">
                  {fullLines.map(({ item, left }) => (
                    <li key={item.id} className="flex items-center justify-between gap-3 py-1.5">
                      <span className="min-w-0 truncate">
                        <span className="font-mono font-semibold tabular-nums">{left}×</span>{" "}
                        {item.product_name}
                        {item.size_name ? ` (${item.size_name})` : ""}
                      </span>
                      <span className="shrink-0 tabular-nums text-muted-foreground">
                        {formatMoney(
                          (Number(item.line_total) * left) / item.quantity,
                          currency,
                          lang,
                        )}
                      </span>
                    </li>
                  ))}
                </ul>
              )}
            </div>
          ) : (
            <div
              key="partial"
              className="animate-tab-in divide-y divide-border rounded-xl border border-border"
            >
              {activeItems.map((item) => {
                const st = lines[item.id] ?? { qty: 0, disposition: "restock" as const };
                const remaining = remainingOf(item.id, item.quantity);
                const disabled = remaining <= 0;
                return (
                  <div key={item.id} className={cn("grid gap-3 p-3", disabled && "opacity-50")}>
                    <div className="flex items-start justify-between gap-3">
                      <label className="flex min-w-0 cursor-pointer items-start gap-3">
                        <Checkbox
                          className="mt-0.5"
                          aria-label={item.product_name}
                          checked={st.qty > 0}
                          disabled={disabled}
                          onCheckedChange={(checked) => setLine(item.id, { qty: checked ? 1 : 0 })}
                        />
                        <span className="min-w-0">
                          <span className="block font-medium">
                            {item.quantity}× {item.product_name}
                            {item.size_name ? ` (${item.size_name})` : ""}
                          </span>
                          <span className="block text-xs text-muted-foreground">
                            {t("orders.remaining")}: {remaining}
                          </span>
                        </span>
                      </label>
                      <span className="shrink-0 tabular-nums">
                        {formatMoney(item.line_total, currency, lang)}
                      </span>
                    </div>
                    {!disabled && st.qty > 0 && (
                      <div className="flex flex-wrap items-center justify-between gap-3 ps-7 animate-pop-in">
                        <div className="flex items-center gap-1.5">
                          <Button
                            type="button"
                            size="icon"
                            variant="outline"
                            className="size-8"
                            aria-label={ar ? "أقل" : "Less"}
                            onClick={() => setLine(item.id, { qty: Math.max(0, st.qty - 1) })}
                          >
                            <Minus />
                          </Button>
                          <span className="w-8 text-center font-mono text-base font-bold tabular-nums">
                            {st.qty}
                          </span>
                          <Button
                            type="button"
                            size="icon"
                            variant="outline"
                            className="size-8"
                            aria-label={ar ? "أكتر" : "More"}
                            onClick={() =>
                              setLine(item.id, { qty: Math.min(remaining, st.qty + 1) })
                            }
                          >
                            <Plus />
                          </Button>
                        </div>
                        <div role="radiogroup" className="flex gap-1.5">
                          {(
                            [
                              ["restock", PackageCheck, t("orders.restock")],
                              ["waste", Trash2, t("orders.operationalWaste")],
                            ] as const
                          ).map(([value, Icon, label]) => (
                            <button
                              key={value}
                              type="button"
                              role="radio"
                              aria-checked={st.disposition === value}
                              onClick={() => setLine(item.id, { disposition: value })}
                              className={cn(
                                "flex items-center gap-1.5 rounded-lg border px-2.5 py-1.5 text-xs font-medium transition-colors",
                                st.disposition === value
                                  ? value === "waste"
                                    ? "border-destructive/50 bg-destructive/10 text-destructive"
                                    : "border-primary/50 bg-primary/10 text-primary"
                                  : "border-border text-muted-foreground hover:bg-tint",
                              )}
                            >
                              <Icon className="size-3.5" aria-hidden />
                              {label}
                            </button>
                          ))}
                        </div>
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
          )}

          <div className="grid gap-3 sm:grid-cols-2">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="refund-method" className="text-xs text-muted-foreground">
                {t("pos.method")}
              </Label>
              <select
                id="refund-method"
                className="h-9 rounded-md border border-input bg-background px-3 text-sm"
                value={method}
                onChange={(e) => setMethod(e.target.value)}
              >
                <option value="cash">{ar ? "كاش" : "Cash"}</option>
                <option value="instapay">InstaPay</option>
                <option value="wallet">{ar ? "محفظة إلكترونية" : "Wallet"}</option>
              </select>
            </div>
            <div className="flex flex-col gap-1.5">
              <span className="text-xs text-muted-foreground">
                {mode === "full"
                  ? ar
                    ? "هيرجع للعميل"
                    : "Refund to customer"
                  : t("orders.refundEstimate")}
              </span>
              <div className="flex h-9 items-center rounded-md border border-border bg-muted px-3 font-mono font-bold tabular-nums">
                {formatMoney(estimate, currency, lang)}
              </div>
              {walletBack > 0 && (
                <span className="text-xs text-muted-foreground">
                  {ar ? "+ يرجع لمحفظة الكاش باك:" : "+ back to the cashback wallet:"}{" "}
                  <span className="font-mono font-semibold">{formatMoney(walletBack, currency, lang)}</span>
                </span>
              )}
            </div>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="refund-reason" className="text-xs text-muted-foreground">
              {t("orders.reason")}
            </Label>
            <Input
              id="refund-reason"
              value={reason}
              placeholder={ar ? "مثال: العميل غيّر رأيه" : "e.g. customer changed their mind"}
              onChange={(e) => setReason(e.target.value)}
            />
          </div>

          <div className="rounded-xl border border-border bg-card p-3">
            <WasteBearerPicker
              idPrefix="refund"
              value={bearer}
              onChange={setBearer}
              staffId={blamedId}
              onStaffIdChange={setBlamedId}
              amount={estimate + walletBack}
            />
          </div>
          {mode === "partial" && (
            <p className="text-xs text-muted-foreground">{t("orders.wasteNote")}</p>
          )}
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            {t("common.cancel")}
          </Button>
          <Button
            variant="destructive"
            icon={mode === "full" ? ReceiptText : ListChecks}
            disabled={!ready || submit.isPending}
            onClick={() => submit.mutate()}
          >
            {submit.isPending
              ? ar
                ? "جاري التنفيذ…"
                : "Working…"
              : mode === "full"
                ? ar
                  ? "إرجاع الفاتورة كلها"
                  : "Return whole invoice"
                : t("orders.confirmRefund")}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
