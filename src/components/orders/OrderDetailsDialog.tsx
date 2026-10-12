import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Undo2 } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { OrderRefundDialog } from "@/components/orders/OrderRefundDialog";
import { PreparedDisposition, useDisposition } from "@/components/orders/PreparedDisposition";
import { StatusBadge } from "@/components/shared/StatusBadge";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { formatDateTime, formatMoney, friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { invoiceSequence, printReceipt } from "@/lib/receipt";

export type OrderDetails = {
  id: string;
  order_number: string;
  order_type: string;
  status: string;
  subtotal: number | string;
  discount_amount: number | string;
  tax_amount: number | string;
  total: number | string;
  created_at: string;
  customer_phone?: string | null;
  user_profiles?: {
    display_name: string | null;
    first_name: string;
    last_name: string;
  } | null;
  order_items: Array<{
    id: string;
    product_name: string;
    size_name: string | null;
    unit_price: number | string;
    quantity: number;
    line_total: number | string;
    status: string;
    void_reason: string | null;
    notes: string | null;
    order_item_modifiers: Array<{ name: string }>;
  }>;
  order_payments: Array<{ method_key: string; amount: number | string }>;
  customer_name?: string | null;
  shift_id?: string | null;
  /** Cashier's note written at checkout. */
  notes?: string | null;
};

type RefundPayloadItem = {
  product_name?: string;
  quantity?: number;
  disposition?: "restock" | "waste";
};

export function OrderDetailsDialog({
  order,
  onClose,
  typeLabel,
}: {
  order: OrderDetails | null;
  onClose: () => void;
  typeLabel: (value: string) => string;
}) {
  const { t, lang } = useI18n();
  const { can, me, currentBranchId } = useAuth();
  const queryClient = useQueryClient();
  const currency = me?.company?.currency ?? "EGP";
  // Line being removed: "draft" lines (order not delivered, shift open) need no reason.
  const [voidLine, setVoidLine] = useState<{ id: string; name: string; draft: boolean } | null>(null);
  const [voidReason, setVoidReason] = useState("");
  const disposition = useDisposition();
  const openVoid = (line: { id: string; name: string; draft: boolean }) => {
    setVoidReason("");
    disposition.reset();
    setVoidLine(line);
  };
  const [refundOpen, setRefundOpen] = useState(false);

  const refunds = useQuery({
    queryKey: ["order-refunds", order?.id],
    enabled: Boolean(order),
    queryFn: async () => {
      if (!order) return [];
      const { data, error } = await supabase
        .from("order_refunds")
        .select("id, kind, amount, reason, method_key, created_at, origin, items_payload")
        .eq("order_id", order.id)
        .eq("status", "active")
        .order("created_at", { ascending: false });
      if (error) throw error;
      return data ?? [];
    },
  });

  const refundedTotal = (refunds.data ?? []).reduce((sum, r) => sum + Number(r.amount), 0);

  // Cashback moves recorded against this order (for the reprinted receipt).
  const wallet = useQuery({
    queryKey: ["order-wallet", order?.id],
    enabled: Boolean(order),
    queryFn: async () => {
      if (!order) return [];
      const { data, error } = await supabase
        .from("customer_wallet_transactions")
        .select("kind, amount, balance_after, created_at")
        .eq("order_id", order.id)
        .order("created_at", { ascending: true });
      if (error) throw error;
      return data ?? [];
    },
  });

  const refundable = Math.max(0, Number(order?.total ?? 0) - refundedTotal);

  // Cashiers return orders of their own still-open shift without a manager
  // (same rule as the server's can_refund_order).
  const ownOpenShift = useQuery({
    queryKey: ["order-shift-open", order?.shift_id, me?.profile.id],
    enabled: Boolean(order?.shift_id && me?.profile.id) && !can("pos.process_refund"),
    queryFn: async () => {
      const { data: shift, error } = await supabase
        .from("shifts")
        .select("id, user_id, status")
        .eq("id", order!.shift_id!)
        .maybeSingle();
      if (error) throw error;
      if (!shift || shift.status !== "open") return false;
      if (shift.user_id === me!.profile.id) return true;
      const { data: crew } = await supabase
        .from("shift_staff")
        .select("staff_id")
        .eq("shift_id", shift.id)
        .eq("staff_id", me!.profile.id);
      return (crew ?? []).length > 0;
    },
  });
  const canRefund =
    can("pos.process_refund") || (can("pos.create_order") && ownOpenShift.data === true);

  const invalidate = async () => {
    await Promise.all([
      queryClient.invalidateQueries({ queryKey: ["orders"] }),
      queryClient.invalidateQueries({ queryKey: ["order-refunds"] }),
      queryClient.invalidateQueries({ queryKey: ["shifts"] }),
    ]);
  };

  // Remove a line. Before delivery the cashier says whether the bar already made it:
  // not made → back to stock; made → written off as waste with who bears the cost.
  const voidItem = useMutation({
    mutationFn: async () => {
      if (!voidLine) throw new Error("Missing line");
      const { error } = await supabase.rpc("void_order_item", {
        _order_item_id: voidLine.id,
        _reason: voidReason.trim(),
        ...disposition.args,
      });
      if (error) throw error;
    },
    onSuccess: async () => {
      const draft = voidLine?.draft;
      setVoidLine(null);
      await invalidate();
      toast.success(
        draft ? (lang === "ar" ? "اتشال الصنف من الطلب" : "Item removed from the order") : t("orders.voidDone"),
      );
      if (!draft) onClose();
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  const branchName = me?.branches.find((b) => b.id === currentBranchId)?.name ?? null;

  const print = () => {
    if (!order) return;
    const cashier = order.user_profiles;
    const cashierName =
      cashier?.display_name || `${cashier?.first_name ?? ""} ${cashier?.last_name ?? ""}`.trim();
    const ok = printReceipt({
      companyName: me?.company?.name ?? "20s Coffee",
      branchName,
      orderNumber: order.order_number,
      createdAt: order.created_at,
      orderType: typeLabel(order.order_type),
      cashier: cashierName || null,
      notes: order.notes ?? null,
      lines: order.order_items.map((item) => ({
        product_name: item.product_name,
        size_name: item.size_name,
        unit_price: item.unit_price,
        quantity: item.quantity,
        line_total: item.line_total,
        status: item.status,
        modifiers: item.order_item_modifiers,
        notes: item.notes,
      })),
      subtotal: order.subtotal,
      discount: order.discount_amount,
      total: order.total,
      refunded: refundedTotal,
      payments: order.order_payments,
      customerName: order.customer_name ?? null,
      customerPhone: order.customer_phone ?? null,
      cashbackEarned: (wallet.data ?? []).filter((w) => w.kind === "earn").reduce((sum, w) => sum + Number(w.amount), 0),
      walletBalance: wallet.data?.length ? Number(wallet.data[wallet.data.length - 1]!.balance_after) : null,
      currency,
      lang,
      labels: {
        order: t("orders.receiptOrder"),
        subtotal: t("pos.subtotal"),
        discount: t("pos.discount"),
        total: t("common.total"),
        refunded: t("orders.refundedTotal"),
        voided: t("orders.voided"),
        customer: t("loy.customer"),
        pointsEarned: t("pos.pointsEarned"),
        pointsBalance: t("pos.pointsBalance"),
        thanks: t("orders.receiptThanks"),
      },
    });
    if (!ok) toast.error(t("orders.printBlocked"));
  };

  return (
    <>
      <Dialog open={Boolean(order)} onOpenChange={(open) => !open && onClose()}>
        <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-2xl">
          <DialogHeader className="border-b border-border pb-4 text-start">
            <DialogTitle className="flex flex-wrap items-center gap-3 pe-8">
              <span>{t("orders.details")}</span>
              <span className="font-mono text-xl font-bold text-primary">
                {invoiceSequence(order?.order_number ?? "1")}
              </span>
              {order && <StatusBadge status={order.status} />}
            </DialogTitle>
            {order && (
              <div className="flex flex-wrap gap-x-4 gap-y-1 pt-1 text-xs text-muted-foreground">
                <span>{formatDateTime(order.created_at, lang)}</span>
                <span>{typeLabel(order.order_type)}</span>
              </div>
            )}
          </DialogHeader>

          {order && (
            <div className="space-y-5 text-sm">
              <div className="grid gap-3 rounded-lg bg-muted p-3 sm:grid-cols-2">
                <div>
                  <p className="text-xs text-muted-foreground">{t("pos.customer")}</p>
                  <p className="font-medium">{order.customer_name || t("orders.walkInCustomer")}</p>
                  {order.customer_phone && <p className="text-xs text-muted-foreground">{order.customer_phone}</p>}
                </div>
                <div>
                  <p className="text-xs text-muted-foreground">{t("orders.cashier")}</p>
                  <p className="font-medium">
                    {order.user_profiles?.display_name ||
                      [order.user_profiles?.first_name, order.user_profiles?.last_name]
                        .filter(Boolean)
                        .join(" ") ||
                      "—"}
                  </p>
                </div>
                {order.notes?.trim() && (
                  <div className="sm:col-span-2">
                    <p className="text-xs text-muted-foreground">{t("common.notes")}</p>
                    <p className="whitespace-pre-wrap font-medium" dir="auto">{order.notes}</p>
                  </div>
                )}
              </div>

              <div className="overflow-hidden rounded-lg border border-border">
                <div className="grid grid-cols-[1fr_auto_auto] gap-3 bg-muted px-3 py-2 text-xs font-medium text-muted-foreground">
                  <span>{t("orders.items")}</span>
                  <span>{t("orders.unitPrice")}</span>
                  <span>{t("common.total")}</span>
                </div>
                <div className="divide-y divide-border">
                {order.order_items.map((item) => (
                  <div key={item.id} className="grid grid-cols-[1fr_auto_auto] items-start gap-3 p-3">
                    <div className={item.status === "voided" ? "opacity-60 line-through" : ""}>
                      <p className="font-medium">
                        {item.quantity}× {item.product_name}
                        {item.size_name ? ` (${item.size_name})` : ""}
                      </p>
                      {item.order_item_modifiers.length > 0 && (
                        <p className="text-xs text-muted-foreground">
                          {item.order_item_modifiers.map((m) => m.name).join(", ")}
                        </p>
                      )}
                      {item.void_reason && (
                        <p className="text-xs text-destructive">{item.void_reason}</p>
                      )}
                    </div>
                    <span className="whitespace-nowrap font-mono text-xs">
                      {formatMoney(Number(item.line_total) / Math.max(1, item.quantity), currency, lang)}
                    </span>
                    <div className="flex shrink-0 items-center gap-2 whitespace-nowrap font-mono">
                      <span className="font-semibold">{formatMoney(item.line_total, currency, lang)}</span>
                      {item.status === "active" &&
                        (order.status === "open" || order.status === "pending") &&
                        (can("pos.create_order") || can("pos.void_item")) && (
                          <Button
                            size="sm"
                            variant="outline"
                            className="text-destructive"
                            onClick={() => openVoid({ id: item.id, name: item.product_name, draft: true })}
                          >
                            {lang === "ar" ? "شيل الصنف" : "Remove"}
                          </Button>
                        )}
                      {item.status === "active" &&
                        order.status === "completed" &&
                        can("pos.void_item") && (
                          <Button
                            size="sm"
                            variant="outline"
                            onClick={() => openVoid({ id: item.id, name: item.product_name, draft: false })}
                          >
                            {t("orders.void")}
                          </Button>
                        )}
                    </div>
                  </div>
                ))}
                </div>
              </div>

              <div className="space-y-2 border-y border-border py-4">
                <Row
                  label={t("pos.subtotal")}
                  value={formatMoney(order.subtotal, currency, lang)}
                />
                <Row
                  label={t("pos.discount")}
                  value={formatMoney(order.discount_amount, currency, lang)}
                />
                <Row
                  label={t("common.total")}
                  value={formatMoney(order.total, currency, lang)}
                />
                {refundedTotal > 0 && (
                  <Row
                    label={t("orders.refundedTotal")}
                    value={`-${formatMoney(refundedTotal, currency, lang)}`}
                  />
                )}
                <div className="mt-3 flex items-end justify-between border-t border-border pt-3">
                  <span className="font-semibold">{t("orders.netCollected")}</span>
                  <span className="font-mono text-xl font-bold text-primary">
                    {formatMoney(Math.max(0, Number(order.total) - refundedTotal), currency, lang)}
                  </span>
                </div>
              </div>

              {(refunds.data ?? []).length > 0 && (
                <div className="space-y-3">
                  <p className="font-semibold">{t("orders.refundHistory")}</p>
                  {(refunds.data ?? []).map((r) => (
                    <div key={r.id} className="rounded-lg border border-border p-3 text-xs">
                      <div className="flex flex-wrap items-center justify-between gap-2">
                        <span className="text-muted-foreground">
                          {formatDateTime(r.created_at, lang)} · {r.reason || "—"}
                        </span>
                        <span className="flex items-center gap-2 font-mono font-semibold">
                        <Badge variant="outline">
                          {r.origin === "void" || r.kind === "void"
                            ? t("orders.void")
                            : r.kind === "full"
                              ? t("orders.refundFull")
                              : t("orders.refundPartial")}
                        </Badge>
                        {formatMoney(r.amount, currency, lang)}
                        </span>
                      </div>
                      {((r.items_payload ?? []) as RefundPayloadItem[]).length > 0 && (
                        <div className="mt-2 flex flex-wrap gap-1.5">
                          {((r.items_payload ?? []) as RefundPayloadItem[]).map((item, index) => (
                            <Badge key={`${r.id}-${index}`} variant="secondary" className="font-normal">
                              {item.quantity ?? 0}× {item.product_name || t("orders.items")} ·{" "}
                              {item.disposition === "restock" ? t("orders.restock") : t("orders.waste")}
                            </Badge>
                          ))}
                        </div>
                      )}
                      {r.method_key && (
                        <p className="mt-2 text-muted-foreground">
                          {t("pos.method")}: {r.method_key}
                        </p>
                      )}
                    </div>
                  ))}
                </div>
              )}
            </div>
          )}

          <DialogFooter className="gap-2">
            {can("pos.reprint_receipt") && (
              <Button variant="outline" onClick={print}>
                {t("orders.print")}
              </Button>
            )}
            {(order?.status === "completed" || order?.status === "partially_refunded") &&
              canRefund &&
              refundable > 0 && (
                <Button variant="destructive" icon={Undo2} onClick={() => setRefundOpen(true)}>
                  {lang === "ar" ? "مرتجع (كامل / جزئي)" : "Return (full / partial)"}
                </Button>
              )}
            <Button variant="secondary" onClick={onClose}>
              {t("common.close")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={Boolean(voidLine)} onOpenChange={(open) => !open && setVoidLine(null)}>
        <DialogContent className="sm:max-w-xl">
          <DialogHeader>
            <DialogTitle>
              {voidLine?.draft ? (lang === "ar" ? "شيل صنف" : "Remove item") : t("orders.voidItem")}
              {voidLine ? ` · ${voidLine.name}` : ""}
            </DialogTitle>
          </DialogHeader>
          <div className="space-y-4">
            <PreparedDisposition idPrefix="void" value={disposition.value} onChange={disposition.setValue} />
            <div className="grid gap-1.5">
              <Label htmlFor="void-reason" className="text-xs text-muted-foreground">
                {t("orders.reason")}
                {voidLine?.draft ? (lang === "ar" ? " (اختياري)" : " (optional)") : ""}
              </Label>
              <Input id="void-reason" value={voidReason} onChange={(e) => setVoidReason(e.target.value)} />
              {!voidLine?.draft && <p className="text-xs text-muted-foreground">{t("orders.voidHint")}</p>}
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setVoidLine(null)}>
              {t("common.cancel")}
            </Button>
            <Button
              variant="destructive"
              disabled={
                !disposition.ready ||
                (!voidLine?.draft && voidReason.trim().length < 3) ||
                voidItem.isPending
              }
              onClick={() => voidItem.mutate()}
            >
              {voidLine?.draft ? (lang === "ar" ? "شيل الصنف" : "Remove item") : t("orders.void")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <OrderRefundDialog
        key={order?.id ?? "none"}
        order={order}
        open={refundOpen}
        onClose={() => setRefundOpen(false)}
      />
    </>
  );
}

function Row({ label, value, strong }: { label: string; value: string; strong?: boolean }) {
  return (
    <div className={`flex items-center justify-between ${strong ? "font-semibold" : ""}`}>
      <span className={strong ? "" : "text-muted-foreground"}>{label}</span>
      <span>{value}</span>
    </div>
  );
}
