import { netInvoiceTotal } from "@/core/finance/formulas";
import { useRouter } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";

import { Badge } from "@/components/ui/badge";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { formatDateTime, formatMoney } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { invoiceSequence } from "@/lib/receipt";

type RefundPayloadItem = {
  order_item_id?: string;
  product_name?: string;
  quantity?: number;
  disposition?: string;
};

/**
 * Dual-identity customer drill-down: purchases, net spend, refunds and — when the
 * customer is also a partner — the credit pending against future dividends.
 */
export function CustomerProfileDialog({
  customerId,
  fallbackName,
  onClose,
}: {
  customerId: string | null;
  fallbackName?: string | null;
  onClose: () => void;
}) {
  const { t, lang } = useI18n();
  const router = useRouter();
  const { me } = useAuth();
  const currency = me?.company?.currency ?? "EGP";

  const profile = useQuery({
    queryKey: ["customer-profile", customerId],
    enabled: Boolean(customerId),
    queryFn: async () => {
      const id = customerId!;
      const [customerRes, ordersRes, refundsRes, partnerRes] = await Promise.all([
        supabase
          .from("customers")
          .select("id, code, name, phone, wallet_balance")
          .eq("id", id)
          .maybeSingle(),
        supabase
          .from("orders")
          .select(
            "id, order_number, created_at, order_type, status, total, order_payments(method_key), order_refunds(amount, status, origin)",
          )
          .eq("customer_id", id)
          .order("created_at", { ascending: false })
          .limit(200),
        supabase
          .from("order_refunds")
          .select(
            "id, amount, reason, method_key, created_at, items_payload, status, orders!inner(order_number, customer_id)",
          )
          .eq("orders.customer_id", id)
          .eq("status", "active")
          .order("created_at", { ascending: false })
          .limit(200),
        supabase
          .from("partners")
          .select("id, name, status, partner_tab_orders(total_amount, is_settled)")
          .eq("customer_id", id)
          .maybeSingle(),
      ]);
      if (customerRes.error) throw customerRes.error;
      if (ordersRes.error) throw ordersRes.error;
      if (refundsRes.error) throw refundsRes.error;

      const orders = ordersRes.data ?? [];
      const gross = orders
        .filter((order) => order.status !== "cancelled")
        .reduce((sum, order) => sum + Number(order.total), 0);
      const refundsTotal = (refundsRes.data ?? []).reduce(
        (sum, row) => sum + Number(row.amount),
        0,
      );
      const partner = partnerRes.error ? null : partnerRes.data;
      const pendingTab = ((partner?.partner_tab_orders ?? []) as Array<{
        total_amount: number;
        is_settled: boolean;
      }>)
        .filter((row) => !row.is_settled)
        .reduce((sum, row) => sum + Number(row.total_amount), 0);

      return {
        customer: customerRes.data,
        orders,
        refunds: refundsRes.data ?? [],
        gross,
        refundsTotal,
        partner: partner ? { id: partner.id, name: partner.name } : null,
        pendingTab,
      };
    },
  });

  const data = profile.data;
  const name = data?.customer?.name ?? fallbackName ?? "—";

  const statusLabel = (status: string) =>
    status === "cancelled"
      ? t("orders.statusCancelled")
      : status === "refunded"
        ? t("orders.statusRefunded")
        : status === "partially_refunded"
          ? t("orders.statusPartial")
          : status === "pending"
            ? t("orders.statusPending")
            : t("orders.statusDone");

  return (
    <Dialog open={Boolean(customerId)} onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-h-[92vh] overflow-y-auto sm:max-w-4xl">
        <DialogHeader className="border-b border-border pb-4 text-start">
          <DialogTitle className="flex flex-wrap items-center gap-2">
            {t("cust.profile")} · <span className="font-bold">{name}</span>
            {data?.customer?.phone && (
              <span className="font-mono text-sm text-muted-foreground">
                {data.customer.phone}
              </span>
            )}
            {data?.partner && (
              <Badge className="border border-amber-400/60 bg-gradient-to-r from-amber-400/20 to-yellow-500/20 px-2.5 py-1 font-bold text-amber-900 shadow-sm dark:text-amber-300">
                {t("cust.partnerBadge")}
              </Badge>
            )}
          </DialogTitle>
        </DialogHeader>

        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <div className="rounded-lg border border-border bg-card p-3">
            <p className="text-xs text-muted-foreground">{t("cust.gross")}</p>
            <p className="mt-1 font-mono text-lg font-bold tabular-nums whitespace-nowrap">
              {formatMoney(data?.gross ?? 0, currency, lang)}
            </p>
          </div>
          <div className="rounded-lg border border-border bg-card p-3">
            <p className="text-xs text-muted-foreground">{t("cust.net")}</p>
            <p className="mt-1 font-mono text-lg font-bold tabular-nums whitespace-nowrap text-primary">
              {formatMoney(Math.max(0, (data?.gross ?? 0) - (data?.refundsTotal ?? 0)), currency, lang)}
            </p>
          </div>
          <div className="rounded-lg border border-border bg-card p-3">
            <p className="text-xs text-muted-foreground">{t("cust.refundsTotal")}</p>
            <p className="mt-1 font-mono text-lg font-bold tabular-nums whitespace-nowrap text-rose-600">
              {formatMoney(data?.refundsTotal ?? 0, currency, lang)}
            </p>
          </div>
          <div className="rounded-lg border border-border bg-card p-3">
            <p className="text-xs text-muted-foreground">{lang === "ar" ? "رصيد الكاش باك" : "Cashback balance"}</p>
            <p className="mt-1 font-mono text-lg font-bold tabular-nums whitespace-nowrap">
              {formatMoney(data?.customer?.wallet_balance ?? 0, currency, lang)}
            </p>
          </div>
          {data?.partner && (
            <div className="rounded-lg border border-amber-400/60 bg-amber-500/5 p-3 sm:col-span-2">
              <p className="text-xs text-muted-foreground">{t("cust.pendingTab")}</p>
              <p className="mt-1 font-mono text-lg font-bold tabular-nums whitespace-nowrap text-amber-700 dark:text-amber-300">
                {formatMoney(data.pendingTab, currency, lang)}
              </p>
            </div>
          )}
        </div>

        <Tabs defaultValue="invoices" className="mt-4">
          <TabsList>
            <TabsTrigger value="invoices">{t("cust.invoices")}</TabsTrigger>
            <TabsTrigger value="refunds">{t("cust.refundsLog")}</TabsTrigger>
          </TabsList>

          <TabsContent value="invoices" className="mt-3">
            {(data?.orders ?? []).length === 0 ? (
              <p className="py-6 text-center text-sm text-muted-foreground">
                {t("cust.noInvoices")}
              </p>
            ) : (
              <div className="overflow-x-auto rounded-lg border border-border">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead className="w-24 whitespace-nowrap text-start">#</TableHead>
                      <TableHead className="w-44 whitespace-nowrap text-center">
                        {t("common.date")}
                      </TableHead>
                      <TableHead className="w-28 whitespace-nowrap text-center">
                        {t("pos.method")}
                      </TableHead>
                      <TableHead className="w-32 whitespace-nowrap text-center">
                        {t("common.status")}
                      </TableHead>
                      <TableHead className="w-36 whitespace-nowrap text-end">
                        {t("common.total")}
                      </TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {(data?.orders ?? []).map((order) => {
                      const net = netInvoiceTotal(order, order.order_refunds);
                      return (
                        <TableRow key={order.id}>
                          <TableCell className="w-24 whitespace-nowrap text-start">
                            <button
                              type="button"
                              className="font-mono font-bold text-primary underline-offset-4 hover:underline"
                              title={t("orders.openInNewTab")}
                              onClick={() => router.navigate({ to: "/orders/$orderId", params: { orderId: order.id } })}
                            >
                              {invoiceSequence(order.order_number)}
                            </button>
                          </TableCell>
                          <TableCell className="w-44 whitespace-nowrap text-center">
                            {formatDateTime(order.created_at, lang)}
                          </TableCell>
                          <TableCell className="w-28 whitespace-nowrap text-center text-xs">
                            {(order.order_payments ?? []).map((p) => p.method_key).join(", ") ||
                              t("orders.partnerTab")}
                          </TableCell>
                          <TableCell className="w-32 whitespace-nowrap text-center">
                            <Badge variant="outline">{statusLabel(order.status)}</Badge>
                          </TableCell>
                          <TableCell className="w-36 whitespace-nowrap text-end font-mono tabular-nums">
                            {formatMoney(net, currency, lang)}
                          </TableCell>
                        </TableRow>
                      );
                    })}
                  </TableBody>
                </Table>
              </div>
            )}
          </TabsContent>

          <TabsContent value="refunds" className="mt-3">
            {(data?.refunds ?? []).length === 0 ? (
              <p className="py-6 text-center text-sm text-muted-foreground">
                {t("cust.noRefunds")}
              </p>
            ) : (
              <div className="overflow-x-auto rounded-lg border border-border">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead className="w-24 whitespace-nowrap text-start">#</TableHead>
                      <TableHead className="w-44 whitespace-nowrap text-center">
                        {t("common.date")}
                      </TableHead>
                      <TableHead className="min-w-64 text-start">{t("orders.items")}</TableHead>
                      <TableHead className="min-w-40 text-start">{t("orders.reason")}</TableHead>
                      <TableHead className="w-32 whitespace-nowrap text-end">
                        {t("common.total")}
                      </TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {(data?.refunds ?? []).map((row) => {
                      const order = row.orders as unknown as { order_number: string } | null;
                      const items = (row.items_payload ?? []) as RefundPayloadItem[];
                      return (
                        <TableRow key={row.id}>
                          <TableCell className="w-24 whitespace-nowrap text-start font-mono font-bold text-primary">
                            {invoiceSequence(order?.order_number ?? "1")}
                          </TableCell>
                          <TableCell className="w-44 whitespace-nowrap text-center">
                            {formatDateTime(row.created_at, lang)}
                          </TableCell>
                          <TableCell className="min-w-64 text-start">
                            <div className="flex flex-wrap gap-1.5">
                              {items.length === 0 ? (
                                <span className="text-xs text-muted-foreground">—</span>
                              ) : (
                                items.map((item, index) => (
                                  <Badge
                                    key={`${row.id}-${index}`}
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
                                ))
                              )}
                            </div>
                          </TableCell>
                          <TableCell className="min-w-40 text-start text-xs text-muted-foreground">
                            {row.reason}
                          </TableCell>
                          <TableCell className="w-32 whitespace-nowrap text-end font-mono tabular-nums text-rose-600">
                            {formatMoney(row.amount, currency, lang)}
                          </TableCell>
                        </TableRow>
                      );
                    })}
                  </TableBody>
                </Table>
              </div>
            )}
          </TabsContent>
        </Tabs>
      </DialogContent>
    </Dialog>
  );
}
