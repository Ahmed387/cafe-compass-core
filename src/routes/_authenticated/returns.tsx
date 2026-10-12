import { useQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";

import { EmptyState, NoPermission, PageHeader } from "@/components/layout/AppShell";
import { Badge } from "@/components/ui/badge";
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
import { formatDate, formatMoney } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { useState } from "react";
import { matches, SmartFilterBar } from "@/modules/shell/SmartFilterBar";

export const Route = createFileRoute("/_authenticated/returns")({
  head: () => ({
    meta: [
      { title: "Returns — 20s Coffee" },
      {
        name: "description",
        content:
          "All supplier returns and customer refunds for 20s Coffee, with items, amounts and reasons.",
      },
      { property: "og:title", content: "Returns — 20s Coffee" },
      {
        property: "og:description",
        content: "Track partial and full returns to suppliers and refunds to customers.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: ReturnsPage,
});

type SupplierReturn = {
  id: string;
  return_date: string;
  refund_mode: string;
  total: number;
  reason: string | null;
  purchases: { invoice_number: string | null; suppliers: { name: string } | null } | null;
  purchase_return_items: {
    id: string;
    quantity: number;
    line_total: number;
    inventory_items: { name: string; name_ar: string | null; unit: string } | null;
  }[];
};

type CustomerRefund = {
  id: string;
  created_at: string;
  kind: string;
  amount: number;
  tax_amount: number;
  method_key: string | null;
  reason: string | null;
  status: string;
  orders: { order_number: string | null; customer_name: string | null } | null;
};

function ReturnsPage() {
  const { t, lang } = useI18n();
  const { can, me } = useAuth();
  const currency = me?.company?.currency ?? "EGP";
  const [q, setQ] = useState("");
  const canView = can("purchases.view") || can("pos.view") || can("reports.sales");

  const supplierReturns = useQuery({
    queryKey: ["supplier-returns"],
    enabled: canView,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("purchase_returns")
        .select(
          "id, return_date, refund_mode, total, reason, purchases(invoice_number, suppliers(name)), purchase_return_items(id, quantity, line_total, inventory_items(name, name_ar, unit))",
        )
        .order("return_date", { ascending: false })
        .limit(200);
      if (error) throw error;
      return (data ?? []) as unknown as SupplierReturn[];
    },
  });

  const customerRefunds = useQuery({
    queryKey: ["customer-refunds"],
    enabled: canView,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("order_refunds")
        .select(
          "id, created_at, kind, amount, tax_amount, method_key, reason, status, orders(order_number, customer_name)",
        )
        .order("created_at", { ascending: false })
        .limit(200);
      if (error) throw error;
      return (data ?? []) as unknown as CustomerRefund[];
    },
  });

  if (!canView) return <NoPermission message={t("common.noAccess")} />;

  const sup = (supplierReturns.data ?? []).filter((r) =>
    matches(q, r.purchases?.suppliers?.name, r.purchases?.invoice_number, r.reason, ...(r.purchase_return_items ?? []).flatMap((l) => [l.inventory_items?.name, l.inventory_items?.name_ar])),
  );
  const cus = (customerRefunds.data ?? []).filter((r) => matches(q, r.orders?.order_number, r.orders?.customer_name, r.reason, r.method_key));
  const supTotal = sup.reduce((s, r) => s + Number(r.total), 0);
  const cusTotal = cus.reduce((s, r) => s + Number(r.amount), 0);

  return (
    <div>
      <PageHeader title={t("ret.title")} description={t("ret.subtitle")} />
      <SmartFilterBar search={q} onSearch={setQ} placeholder={lang === "ar" ? "ابحث بالمورد أو الفاتورة أو العميل أو الصنف أو السبب…" : "Search supplier, invoice, customer, item or reason…"} />

      <div className="mb-4 grid gap-3 sm:grid-cols-2">
        {[
          { label: t("ret.tab.suppliers"), value: supTotal, count: sup.length },
          { label: t("ret.tab.customers"), value: cusTotal, count: cus.length },
        ].map((c) => (
          <div
            key={c.label}
            className="animate-fade-in rounded-xl border border-border/60 bg-card p-4 transition-transform hover:-translate-y-0.5"
          >
            <p className="text-xs text-muted-foreground">
              {c.label} ({c.count})
            </p>
            <p className="mt-1 font-display text-xl font-bold tabular-nums">
              {formatMoney(c.value, currency, lang)}
            </p>
          </div>
        ))}
      </div>

      <Tabs defaultValue="suppliers">
        <TabsList>
          <TabsTrigger value="suppliers">{t("ret.tab.suppliers")}</TabsTrigger>
          <TabsTrigger value="customers">{t("ret.tab.customers")}</TabsTrigger>
        </TabsList>

        <TabsContent value="suppliers" className="mt-4">
          {sup.length === 0 ? (
            <EmptyState message={t("ret.emptySup")} />
          ) : (
            <div className="overflow-x-auto rounded-xl border border-border/60 bg-card">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead className="text-start">{t("ret.date")}</TableHead>
                    <TableHead className="text-start">{t("ret.supplier")}</TableHead>
                    <TableHead className="text-start">{t("ret.invoice")}</TableHead>
                    <TableHead className="text-start">{t("ret.items")}</TableHead>
                    <TableHead className="text-center">{t("ret.mode")}</TableHead>
                    <TableHead className="text-end">{t("ret.total")}</TableHead>
                    <TableHead className="text-start">{t("ret.reason")}</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {sup.map((r, idx) => (
                    <TableRow key={r.id} className={idx % 2 ? "bg-muted/30" : ""}>
                      <TableCell className="text-start whitespace-nowrap">
                        {formatDate(r.return_date, lang)}
                      </TableCell>
                      <TableCell className="text-start font-medium">
                        {r.purchases?.suppliers?.name ?? "—"}
                      </TableCell>
                      <TableCell className="text-start text-muted-foreground">
                        {r.purchases?.invoice_number ?? "—"}
                      </TableCell>
                      <TableCell className="text-start">
                        <div className="space-y-0.5">
                          {(r.purchase_return_items ?? []).map((line) => (
                            <p key={line.id} className="text-xs">
                              {((lang === "ar" ? line.inventory_items?.name_ar : null) ??
                                line.inventory_items?.name ??
                                "—") + ` × ${line.quantity} ${line.inventory_items?.unit ?? ""}`}
                            </p>
                          ))}
                        </div>
                      </TableCell>
                      <TableCell className="text-center">
                        <Badge variant={r.refund_mode === "cash" ? "default" : "secondary"}>
                          {r.refund_mode === "cash" ? t("ret.mode.cash") : t("ret.mode.credit")}
                        </Badge>
                      </TableCell>
                      <TableCell className="text-end font-semibold tabular-nums">
                        {formatMoney(r.total, currency, lang)}
                      </TableCell>
                      <TableCell className="text-start text-muted-foreground">
                        {r.reason ?? "—"}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          )}
        </TabsContent>

        <TabsContent value="customers" className="mt-4">
          {cus.length === 0 ? (
            <EmptyState message={t("ret.emptyCus")} />
          ) : (
            <div className="overflow-x-auto rounded-xl border border-border/60 bg-card">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead className="text-start">{t("ret.date")}</TableHead>
                    <TableHead className="text-start">{t("ret.order")}</TableHead>
                    <TableHead className="text-center">{t("ret.kind")}</TableHead>
                    <TableHead className="text-center">{t("ret.method")}</TableHead>
                    <TableHead className="text-end">{t("ret.total")}</TableHead>
                    <TableHead className="text-start">{t("ret.reason")}</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {cus.map((r, idx) => (
                    <TableRow key={r.id} className={idx % 2 ? "bg-muted/30" : ""}>
                      <TableCell className="text-start whitespace-nowrap">
                        {formatDate(r.created_at, lang)}
                      </TableCell>
                      <TableCell className="text-start font-medium">
                        {r.orders?.order_number ?? "—"}
                        {r.orders?.customer_name && (
                          <span className="block text-xs text-muted-foreground">
                            {r.orders.customer_name}
                          </span>
                        )}
                      </TableCell>
                      <TableCell className="text-center">
                        <Badge variant={r.kind === "full" ? "default" : "secondary"}>
                          {r.kind === "full" ? t("ret.kind.full") : t("ret.kind.partial")}
                        </Badge>
                      </TableCell>
                      <TableCell className="text-center text-muted-foreground">
                        {r.method_key ?? "—"}
                      </TableCell>
                      <TableCell className="text-end font-semibold tabular-nums">
                        {formatMoney(r.amount, currency, lang)}
                      </TableCell>
                      <TableCell className="text-start text-muted-foreground">
                        {r.reason ?? "—"}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          )}
        </TabsContent>
      </Tabs>

      <p className="mt-4 text-xs text-muted-foreground">{t("ret.hint")}</p>
    </div>
  );
}
