import { netInvoiceTotal, saleRefundTotal } from "@/core/finance/formulas";
import { useQuery } from "@tanstack/react-query";
import { Ban, Undo2 } from "lucide-react";
import { useState } from "react";
import { createFileRoute, Link } from "@tanstack/react-router";

import { NoPermission, PageHeader } from "@/components/layout/AppShell";
import { OrderCancelDialog } from "@/components/orders/OrderCancelDialog";
import type { OrderDetails } from "@/components/orders/OrderDetailsDialog";
import { OrderRefundDialog } from "@/components/orders/OrderRefundDialog";
import { OrderTableField } from "@/components/orders/OrderTableField";
import { useOrderShiftAccess } from "@/components/orders/useOrderShiftAccess";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { formatDateTime, formatMoney } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { invoiceSequence } from "@/lib/receipt";
import { tenderLabel } from "@/lib/tender";

export const Route = createFileRoute("/_authenticated/orders/$orderId")({
  head: () => ({
    meta: [
      { title: "Invoice — 20s Coffee" },
      {
        name: "description",
        content: "Standalone invoice view with items, payments and refund audit trail.",
      },
      { property: "og:title", content: "Invoice — 20s Coffee" },
      { property: "og:description", content: "Full invoice breakdown and refund history." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: OrderInvoicePage,
});

type RefundPayloadItem = {
  product_name?: string;
  quantity?: number;
  disposition?: string;
};

function OrderInvoicePage() {
  const { orderId } = Route.useParams();
  const { t, lang } = useI18n();
  const { can, me } = useAuth();
  const currency = me?.company?.currency ?? "EGP";
  const canView = can("pos.view") || can("reports.sales");
  const [refundMode, setRefundMode] = useState<"full" | "partial" | null>(null);
  const [cancelling, setCancelling] = useState(false);

  const order = useQuery({
    queryKey: ["order-invoice", orderId],
    enabled: canView,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("orders")
        .select(
          "id, order_number, order_type, table_number, status, subtotal, discount_amount, discount_reason, tax_amount, total, created_at, completed_at, customer_id, customer_name, customer_phone, notes, shift_id, branch_id, user_profiles!orders_created_by_fkey(display_name, first_name, last_name), order_items(id, product_name, size_name, unit_price, quantity, line_total, status, void_reason, notes, order_item_modifiers(name, price_delta)), order_payments(method_key, amount, reference), order_refunds(id, amount, wallet_amount, reason, method_key, created_at, status, origin, is_cancellation, items_payload), partner_tab_orders(id, total_amount, is_settled, partners(name))",
        )
        .eq("id", orderId)
        .maybeSingle();
      if (error) throw error;
      if (!data) return null;

      let shiftNo: number | null = null;
      if (data.shift_id) {
        const { data: shiftRows } = await supabase
          .from("shifts")
          .select("id")
          .eq("branch_id", data.branch_id)
          .order("opened_at", { ascending: true })
          .limit(1000);
        const index = (shiftRows ?? []).findIndex((row) => row.id === data.shift_id);
        shiftNo = index >= 0 ? index + 1 : null;
      }
      return { ...data, shiftNo };
    },
  });

  const { shiftClosed, canRefund } = useOrderShiftAccess(order.data?.shift_id);

  if (!canView) return <NoPermission message={t("common.noAccess")} />;

  const row = order.data;
  if (order.isLoading) {
    return <p className="p-6 text-sm text-muted-foreground">{t("common.loading")}</p>;
  }
  if (!row) {
    return (
      <div className="p-6">
        <p className="text-sm text-muted-foreground">{t("orders.notFound")}</p>
        <Link to="/orders" search={{ tab: undefined, orderId: undefined }}>
          <Button variant="outline" className="mt-3">
            {t("orders.backToOrders")}
          </Button>
        </Link>
      </div>
    );
  }

  const cashier = row.user_profiles as unknown as {
    display_name: string | null;
    first_name: string;
    last_name: string | null;
  } | null;
  const cashierName =
    cashier?.display_name || `${cashier?.first_name ?? ""} ${cashier?.last_name ?? ""}`.trim() || "—";
  const refunds = (row.order_refunds ?? []).filter((refund) => refund.status === "active");
  const refunded = saleRefundTotal(refunds);
  const net = netInvoiceTotal(row, refunds);
  type TabRow = { total_amount: number; is_settled: boolean; partners: { name: string } | null };
  const tabRel = row.partner_tab_orders as unknown as TabRow | TabRow[] | null;
  const tab = Array.isArray(tabRel) ? tabRel[0] : tabRel;
  const paid = (row.order_payments ?? []).length > 0;
  const canReturn = canRefund && (row.status === "completed" || row.status === "partially_refunded") && paid && net > 0;
  // Server rule cancel_pos_order: only unpaid orders (pending / open, or an unsettled partner-tab invoice).
  const canCancel =
    (row.status === "pending" || row.status === "open" || (row.status === "completed" && Boolean(tab) && !paid)) &&
    !shiftClosed &&
    (can("pos.cancel_order") || can("pos.create_order"));

  const statusLabel =
    row.status === "cancelled"
      ? t("orders.statusCancelled")
      : row.status === "refunded"
        ? t("orders.statusRefunded")
        : row.status === "partially_refunded"
          ? t("orders.statusPartial")
          : row.status === "pending"
            ? t("orders.statusPending")
            : t("orders.statusDone");

  return (
    <div className="mx-auto max-w-3xl">
      <PageHeader
        title={`${t("orders.invoice")} #${invoiceSequence(row.order_number)}`}
        description={formatDateTime(row.created_at, lang)}
      />

      <div className="mb-4 flex flex-wrap gap-2 print:hidden">
        <Link to="/orders" search={{ tab: undefined, orderId: undefined }}>
          <Button variant="outline" size="sm">
            {t("orders.backToOrders")}
          </Button>
        </Link>
        <Button size="sm" onClick={() => window.print()}>
          {t("orders.print")}
        </Button>
        {canReturn && (
          <>
            <Button size="sm" variant="outline" icon={Undo2} onClick={() => setRefundMode("partial")}>
              {lang === "ar" ? "مرتجع جزئي" : "Partial return"}
            </Button>
            <Button size="sm" variant="destructive" icon={Undo2} onClick={() => setRefundMode("full")}>
              {lang === "ar" ? "مرتجع كلي" : "Full return"}
            </Button>
          </>
        )}
        {canCancel && (
          <Button size="sm" variant="destructive" icon={Ban} onClick={() => setCancelling(true)}>
            {lang === "ar" ? "إلغاء الطلب" : "Cancel order"}
          </Button>
        )}
      </div>
      {shiftClosed && row.status !== "cancelled" && (
        <p className="mb-4 rounded-lg bg-muted px-3 py-2 text-xs text-muted-foreground print:hidden">
          {lang === "ar"
            ? "الوردية بتاعة الفاتورة دي اتقفلت، فالمرتجع والإلغاء مش متاحين."
            : "This invoice's shift is closed: returns and cancellation are no longer available."}
        </p>
      )}

      <div className="rounded-lg border border-border bg-card p-5 font-mono">
        <div className="grid gap-2 border-b border-dashed border-border pb-4 text-sm sm:grid-cols-2">
          <p>
            <span className="text-muted-foreground">{t("pos.customer")}: </span>
            {row.customer_name || t("orders.walkInCustomer")}
            {row.customer_phone ? ` · ${row.customer_phone}` : ""}
          </p>
          <p>
            <span className="text-muted-foreground">{t("orders.cashier")}: </span>
            {cashierName}
          </p>
          {row.notes?.trim() && (
            <div className="sm:col-span-2 rounded-md border border-dashed border-border p-2">
              <p className="text-xs text-muted-foreground">{t("common.notes")}</p>
              <p className="whitespace-pre-wrap font-medium" dir="auto">{row.notes}</p>
            </div>
          )}
          {row.order_type === "dine_in" && (
            <div className="flex items-center gap-2">
              <span className="text-muted-foreground">{t("orders.table")}: </span>
              <OrderTableField
                orderId={row.id}
                value={row.table_number}
                shiftClosed={shiftClosed}
                onSaved={() => void order.refetch()}
              />
            </div>
          )}
          <p>
            <span className="text-muted-foreground">{t("orders.shiftNo")}: </span>
            {row.shiftNo ?? "—"}
          </p>
          <p className="flex items-center gap-2">
            <span className="text-muted-foreground">{t("common.status")}: </span>
            <Badge variant="outline">{statusLabel}</Badge>
            {tab && !tab.is_settled && (
              <Badge className="border border-amber-400/60 bg-gradient-to-r from-amber-400/20 to-yellow-500/20 px-2.5 py-1 font-bold text-amber-900 shadow-sm dark:text-amber-300">
                {t("orders.partnerTab")}
                {tab.partners?.name ? ` · ${tab.partners.name}` : ""}
              </Badge>
            )}
          </p>
        </div>

        <Table className="mt-3">
          <TableHeader>
            <TableRow>
              <TableHead className="min-w-48 text-start">{t("orders.items")}</TableHead>
              <TableHead className="w-16 whitespace-nowrap text-center">
                {t("common.quantity")}
              </TableHead>
              <TableHead className="w-28 whitespace-nowrap text-end">{t("orders.unitPrice")}</TableHead>
              <TableHead className="w-28 whitespace-nowrap text-end">{t("common.total")}</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {(row.order_items ?? []).map((item) => (
              <TableRow key={item.id} className={item.status === "voided" ? "opacity-50" : ""}>
                <TableCell className="min-w-48 text-start">
                  {item.product_name}
                  {item.size_name ? ` (${item.size_name})` : ""}
                  {(item.order_item_modifiers ?? []).length > 0 && (
                    <span className="block text-xs text-muted-foreground">
                      + {(item.order_item_modifiers ?? []).map((mod) => mod.name).join(", ")}
                    </span>
                  )}
                </TableCell>
                <TableCell className="w-16 whitespace-nowrap text-center tabular-nums">
                  {item.quantity}
                </TableCell>
                <TableCell className="w-28 whitespace-nowrap text-end tabular-nums">
                  {formatMoney(Number(item.line_total) / item.quantity, currency, lang)}
                </TableCell>
                <TableCell className="w-28 whitespace-nowrap text-end tabular-nums">
                  {formatMoney(item.line_total, currency, lang)}
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>

        <div className="mt-4 grid gap-1 border-t border-dashed border-border pt-4 text-sm">
          <div className="flex justify-between">
            <span className="text-muted-foreground">{t("receipt.subtotal")}</span>
            <span className="tabular-nums">{formatMoney(row.subtotal, currency, lang)}</span>
          </div>
          <div className="flex justify-between">
            <span className="text-muted-foreground">{t("receipt.discount")}</span>
            <span className="tabular-nums">{formatMoney(row.discount_amount, currency, lang)}</span>
          </div>
          <div className="flex justify-between">
            <span className="text-muted-foreground">{t("common.total")}</span>
            <span className="tabular-nums">{formatMoney(row.total, currency, lang)}</span>
          </div>
          {refunded > 0 && (
            <div className="flex justify-between text-rose-600">
              <span>{t("orders.statusRefunded")}</span>
              <span className="tabular-nums">-{formatMoney(refunded, currency, lang)}</span>
            </div>
          )}
          <div className="mt-2 flex items-center justify-between rounded-md bg-secondary/50 px-3 py-2">
            <span className="font-semibold">{t("orders.netCollected")}</span>
            <span className="font-mono text-xl font-bold tabular-nums whitespace-nowrap text-primary">
              {formatMoney(net, currency, lang)}
            </span>
          </div>
        </div>

        {(row.order_payments ?? []).length > 0 && (
          <div className="mt-4 grid gap-1 border-t border-dashed border-border pt-4 text-sm">
            {(row.order_payments ?? []).map((payment, index) => (
              <div key={`${payment.method_key}-${index}`} className="flex justify-between">
                <span className="text-muted-foreground">{tenderLabel(payment.method_key, lang)}</span>
                <span className="tabular-nums">{formatMoney(payment.amount, currency, lang)}</span>
              </div>
            ))}
          </div>
        )}

        {refunds.length > 0 && (
          <div className="mt-4 border-t border-dashed border-border pt-4">
            <p className="mb-2 text-sm font-semibold">{t("orders.refundHistory")}</p>
            <div className="grid gap-2">
              {refunds.map((refund) => (
                <div key={refund.id} className="rounded-md border border-border p-2 text-xs">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <span>
                      {formatDateTime(refund.created_at, lang)}
                      {refund.is_cancellation && (
                        <Badge variant="secondary" className="ms-2">
                          {lang === "ar" ? "إلغاء (مش مرتجع)" : "Cancelled (not a refund)"}
                        </Badge>
                      )}
                    </span>
                    <span className="font-mono tabular-nums text-rose-600">
                      {formatMoney(refund.amount, currency, lang)}
                    </span>
                  </div>
                  <div className="mt-1 flex flex-wrap gap-1.5">
                    {((refund.items_payload ?? []) as RefundPayloadItem[]).map((item, index) => (
                      <Badge
                        key={`${refund.id}-${index}`}
                        variant="outline"
                        className={
                          item.disposition === "restock"
                            ? "border-emerald-300 bg-emerald-50 text-emerald-700 dark:bg-emerald-950/40 dark:text-emerald-300"
                            : "border-rose-300 bg-rose-50 text-rose-700 dark:bg-rose-950/40 dark:text-rose-300"
                        }
                      >
                        {item.quantity ?? 1}× {item.product_name ?? "—"} ·{" "}
                        {item.disposition === "restock"
                          ? t("orders.restock")
                          : t("orders.operationalWaste")}
                      </Badge>
                    ))}
                  </div>
                  <p className="mt-1 text-muted-foreground">{refund.reason}</p>
                </div>
              ))}
            </div>
          </div>
        )}
      </div>

      <OrderRefundDialog
        key={`${row.id}-${refundMode ?? "closed"}`}
        order={row as unknown as OrderDetails}
        open={refundMode !== null}
        initialMode={refundMode ?? "partial"}
        onClose={() => setRefundMode(null)}
      />
      <OrderCancelDialog
        order={cancelling ? { id: row.id, number: row.order_number } : null}
        onClose={() => setCancelling(false)}
      />
    </div>
  );
}
