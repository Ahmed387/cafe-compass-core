import { useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { createFileRoute, useRouter } from "@tanstack/react-router";
import { ChevronDown, Download, Receipt } from "lucide-react";

import { EmptyState, NoPermission, PageHeader } from "@/components/layout/AppShell";
import { CollapsibleSection } from "@/components/shared/KpiCard";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
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
import { businessToday } from "@/core/finance/business-dates";
import { PartnerTabsDueCard } from "@/modules/finance/PartnerTabsDueCard";

export const Route = createFileRoute("/_authenticated/partner-tabs")({
  head: () => ({
    meta: [
      { title: "Partner invoices — 20s Coffee" },
      {
        name: "description",
        content: "All partner orders charged via the cashier, itemized and deducted from profit distributions.",
      },
      { property: "og:title", content: "Partner invoices — 20s Coffee" },
      { property: "og:description", content: "Track and audit partner consumption per partner." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: PartnerTabsPage,
});

type Item = {
  product_name: string;
  size_name: string | null;
  quantity: number;
  unit_price: number;
  line_total: number;
  status: string;
};
type Row = {
  id: string;
  total_amount: number;
  settled_amount: number | null;
  is_settled: boolean;
  settled_at: string | null;
  created_at: string;
  partners: { id: string; name: string } | null;
  orders: { id: string; order_number: string; order_items: Item[] } | null;
  user_profiles: { display_name: string | null } | null;
};

function PartnerTabsPage() {
  const { t, lang } = useI18n();
  const ar = lang === "ar";
  const router = useRouter();
  const { me } = useAuth();
  const currency = me?.company?.currency ?? "EGP";
  const [partnerFilter, setPartnerFilter] = useState("all");
  const [status, setStatus] = useState<"all" | "pending" | "settled">("all");
  const [from, setFrom] = useState("");
  const [to, setTo] = useState("");
  const [expanded, setExpanded] = useState<Record<string, boolean>>({});

  // RLS decides the audience: a partner only ever receives their own rows.
  const tabs = useQuery({
    queryKey: ["partner-tab-orders"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("partner_tab_orders")
        .select(
          "id, total_amount, settled_amount, is_settled, settled_at, created_at, partners(id, name), user_profiles!partner_tab_orders_created_by_fkey(display_name), orders(id, order_number, order_items(product_name, size_name, quantity, unit_price, line_total, status))",
        )
        .order("created_at", { ascending: false })
        .limit(2000);
      if (error) throw error;
      return (data ?? []) as unknown as Row[];
    },
  });

  const all = tabs.data ?? [];
  const partnersList = useMemo(() => {
    const m = new Map<string, string>();
    for (const r of all) if (r.partners) m.set(r.partners.id, r.partners.name);
    return [...m.entries()];
  }, [all]);

  const rows = all.filter((r) => {
    if (partnerFilter !== "all" && r.partners?.id !== partnerFilter) return false;
    if (status === "pending" && r.is_settled) return false;
    if (status === "settled" && !r.is_settled) return false;
    const d = r.created_at.slice(0, 10);
    if (from && d < from) return false;
    if (to && d > to) return false;
    return true;
  });

  if (tabs.isError) return <NoPermission message={t("common.noAccess")} />;

  // A tab can be settled in parts: what is open is total minus what was settled so far.
  const paidOf = (r: Row) => (r.is_settled ? Number(r.total_amount) : Math.min(Number(r.settled_amount ?? 0), Number(r.total_amount)));
  const openOf = (r: Row) => Number(r.total_amount) - paidOf(r);
  const pendingTotal = rows.reduce((s, r) => s + openOf(r), 0);
  const settledTotal = rows.reduce((s, r) => s + paidOf(r), 0);

  const byPartner = new Map<string, { name: string; count: number; pending: number; settled: number }>();
  for (const r of rows) {
    if (!r.partners) continue;
    const c = byPartner.get(r.partners.id) ?? { name: r.partners.name, count: 0, pending: 0, settled: 0 };
    c.count += 1;
    c.settled += paidOf(r);
    c.pending += openOf(r);
    byPartner.set(r.partners.id, c);
  }

  const itemsOf = (r: Row) => (r.orders?.order_items ?? []).filter((i) => i.status !== "voided");

  const exportCsv = () => {
    const lines = [
      ["invoice", "date", "partner", "cashier", "item", "size", "qty", "unit_price", "line_total", "invoice_total", "status"].join(","),
    ];
    for (const r of rows) {
      for (const i of itemsOf(r)) {
        lines.push(
          [
            invoiceSequence(r.orders?.order_number ?? "1"),
            r.created_at,
            r.partners?.name ?? "",
            r.user_profiles?.display_name ?? "",
            i.product_name,
            i.size_name ?? "",
            i.quantity,
            i.unit_price,
            i.line_total,
            r.total_amount,
            r.is_settled ? "settled" : "pending",
          ]
            .map((v) => `"${String(v).replace(/"/g, '""')}"`)
            .join(","),
        );
      }
    }
    const blob = new Blob(["\ufeff" + lines.join("\n")], { type: "text/csv;charset=utf-8" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = `partner-invoices-${businessToday()}.csv`;
    a.click();
  };

  return (
    <div>
      <PageHeader
        title={t("ptab.title")}
        description={
          ar
            ? "كل طلبات الشركاء التي سجلها الكاشير على حسابهم — تُخصم تلقائيًا عند توزيع الأرباح القادم."
            : "All partner orders charged by the cashier — deducted automatically at the next profit distribution."
        }
      />
      <PartnerTabsDueCard />

      <div className="mb-5 grid gap-3 sm:grid-cols-4">
        <Kpi label={ar ? "عدد الفواتير" : "Invoices"} value={String(rows.length)} />
        <Kpi label={ar ? "إجمالي الاستهلاك" : "Total consumption"} value={formatMoney(pendingTotal + settledTotal, currency, lang)} />
        <Kpi label={ar ? "مستحق الخصم من الأرباح" : "Pending deduction"} value={formatMoney(pendingTotal, currency, lang)} tone="warn" />
        <Kpi label={ar ? "تم خصمه" : "Already deducted"} value={formatMoney(settledTotal, currency, lang)} tone="ok" />
      </div>

      <div className="mb-5 flex flex-wrap items-end gap-3 rounded-2xl bg-card p-4 shadow-sm">
        <div className="min-w-44">
          <p className="mb-1 text-xs text-muted-foreground">{ar ? "الشريك" : "Partner"}</p>
          <Select value={partnerFilter} onValueChange={setPartnerFilter}>
            <SelectTrigger><SelectValue /></SelectTrigger>
            <SelectContent>
              <SelectItem value="all">{ar ? "كل الشركاء" : "All partners"}</SelectItem>
              {partnersList.map(([id, name]) => (
                <SelectItem key={id} value={id}>{name}</SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="min-w-36">
          <p className="mb-1 text-xs text-muted-foreground">{t("common.status")}</p>
          <Select value={status} onValueChange={(v) => setStatus(v as typeof status)}>
            <SelectTrigger><SelectValue /></SelectTrigger>
            <SelectContent>
              <SelectItem value="all">{ar ? "الكل" : "All"}</SelectItem>
              <SelectItem value="pending">{t("ptab.unsettled")}</SelectItem>
              <SelectItem value="settled">{t("ptab.settledFlag")}</SelectItem>
            </SelectContent>
          </Select>
        </div>
        <div>
          <p className="mb-1 text-xs text-muted-foreground">{ar ? "من" : "From"}</p>
          <Input type="date" value={from} onChange={(e) => setFrom(e.target.value)} />
        </div>
        <div>
          <p className="mb-1 text-xs text-muted-foreground">{ar ? "إلى" : "To"}</p>
          <Input type="date" value={to} onChange={(e) => setTo(e.target.value)} />
        </div>
        <Button variant="outline" onClick={exportCsv} disabled={rows.length === 0} className="ms-auto gap-2">
          <Download className="size-4" /> {ar ? "تصدير" : "Export"}
        </Button>
      </div>

      {byPartner.size > 0 && (
        <CollapsibleSection title={ar ? "ملخص لكل شريك" : "Per-partner summary"} className="mb-5">
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            {[...byPartner.entries()].map(([id, v]) => (
              <button
                key={id}
                type="button"
                onClick={() => setPartnerFilter(partnerFilter === id ? "all" : id)}
                className={`rounded-2xl bg-card p-4 text-start shadow-sm transition hover:shadow-md ${partnerFilter === id ? "ring-2 ring-primary" : ""}`}
              >
                <div className="flex items-center justify-between">
                  <p className="font-semibold">{v.name}</p>
                  <Badge variant="outline">{v.count} {ar ? "فاتورة" : "invoices"}</Badge>
                </div>
                <div className="mt-3 grid grid-cols-2 gap-2 text-xs">
                  <div>
                    <p className="text-muted-foreground">{ar ? "مستحق الخصم" : "Pending"}</p>
                    <p className="font-mono text-base font-bold tabular-nums text-amber-700 dark:text-amber-300">
                      {formatMoney(v.pending, currency, lang)}
                    </p>
                  </div>
                  <div>
                    <p className="text-muted-foreground">{ar ? "تم خصمه" : "Deducted"}</p>
                    <p className="font-mono text-base font-bold tabular-nums">{formatMoney(v.settled, currency, lang)}</p>
                  </div>
                </div>
              </button>
            ))}
          </div>
        </CollapsibleSection>
      )}

      <CollapsibleSection title={ar ? "سجل فواتير الشركاء" : "Partner invoice log"} icon={<Receipt className="size-4" />}>
        {rows.length === 0 ? (
          <EmptyState message={t("ptab.empty")} />
        ) : (
          <div className="overflow-x-auto rounded-2xl bg-card shadow-sm">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead className="w-10" />
                  <TableHead className="w-24 text-start">#</TableHead>
                  <TableHead className="w-44 text-center">{t("common.date")}</TableHead>
                  <TableHead className="min-w-36 text-start">{t("ptab.partner")}</TableHead>
                  <TableHead className="min-w-32 text-start">{ar ? "الكاشير" : "Cashier"}</TableHead>
                  <TableHead className="w-20 text-center">{ar ? "الأصناف" : "Items"}</TableHead>
                  <TableHead className="w-36 text-end">{t("common.total")}</TableHead>
                  <TableHead className="w-32 text-center">{t("common.status")}</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {rows.map((r) => {
                  const items = itemsOf(r);
                  const open = !!expanded[r.id];
                  return [
                    <TableRow key={r.id} className="cursor-pointer" onClick={() => setExpanded((e) => ({ ...e, [r.id]: !open }))}>
                      <TableCell>
                        <ChevronDown className={`size-4 transition-transform ${open ? "rotate-180" : ""}`} />
                      </TableCell>
                      <TableCell className="text-start">
                        <button
                          type="button"
                          className="font-mono font-bold text-primary underline-offset-4 hover:underline"
                          onClick={(e) => {
                            e.stopPropagation();
                            if (r.orders) router.navigate({ to: "/orders/$orderId", params: { orderId: r.orders.id } });
                          }}
                        >
                          {invoiceSequence(r.orders?.order_number ?? "1")}
                        </button>
                      </TableCell>
                      <TableCell className="whitespace-nowrap text-center">{formatDateTime(r.created_at, lang)}</TableCell>
                      <TableCell className="font-medium">{r.partners?.name ?? "—"}</TableCell>
                      <TableCell className="text-muted-foreground">{r.user_profiles?.display_name ?? "—"}</TableCell>
                      <TableCell className="text-center tabular-nums">{items.reduce((s, i) => s + Number(i.quantity), 0)}</TableCell>
                      <TableCell className="whitespace-nowrap text-end font-mono tabular-nums">
                        {formatMoney(r.total_amount, currency, lang)}
                      </TableCell>
                      <TableCell className="text-center">
                        {r.is_settled ? (
                          <Badge variant="outline" className="border-emerald-300 bg-emerald-50 text-emerald-700 dark:bg-emerald-950/40 dark:text-emerald-300">
                            {t("ptab.settledFlag")}
                          </Badge>
                        ) : (
                          <Badge variant="outline" className="border-amber-400/60 bg-amber-500/10 text-amber-800 dark:text-amber-300">
                            {t("ptab.unsettled")}
                          </Badge>
                        )}
                      </TableCell>
                    </TableRow>,
                    open && (
                      <TableRow key={`${r.id}-items`} className="bg-muted/30 hover:bg-muted/30">
                        <TableCell colSpan={8} className="p-3">
                          <table className="w-full text-xs">
                            <thead className="text-muted-foreground">
                              <tr>
                                <th className="py-1 text-start">{ar ? "الصنف" : "Item"}</th>
                                <th className="py-1 text-center">{ar ? "الكمية" : "Qty"}</th>
                                <th className="py-1 text-end">{ar ? "سعر الوحدة" : "Unit"}</th>
                                <th className="py-1 text-end">{ar ? "الإجمالي" : "Total"}</th>
                              </tr>
                            </thead>
                            <tbody>
                              {items.map((i, idx) => (
                                <tr key={idx}>
                                  <td className="py-1">{i.product_name}{i.size_name ? ` (${i.size_name})` : ""}</td>
                                  <td className="py-1 text-center tabular-nums">{i.quantity}</td>
                                  <td className="py-1 text-end font-mono tabular-nums">{formatMoney(i.unit_price, currency, lang)}</td>
                                  <td className="py-1 text-end font-mono tabular-nums">{formatMoney(i.line_total, currency, lang)}</td>
                                </tr>
                              ))}
                            </tbody>
                          </table>
                          {r.is_settled && r.settled_at && (
                            <p className="mt-2 text-xs text-muted-foreground">
                              {ar ? "خُصم من الأرباح في" : "Deducted from profit on"} {formatDateTime(r.settled_at, lang)}
                            </p>
                          )}
                        </TableCell>
                      </TableRow>
                    ),
                  ];
                })}
              </TableBody>
            </Table>
          </div>
        )}
      </CollapsibleSection>
    </div>
  );
}

function Kpi({ label, value, tone }: { label: string; value: string; tone?: "warn" | "ok" }) {
  const color = tone === "warn" ? "text-amber-700 dark:text-amber-300" : tone === "ok" ? "text-emerald-700 dark:text-emerald-300" : "";
  return (
    <div className="rounded-2xl bg-card p-4 shadow-sm">
      <p className="text-xs text-muted-foreground">{label}</p>
      <p className={`mt-1 font-mono text-xl font-bold tabular-nums whitespace-nowrap ${color}`}>{value}</p>
    </div>
  );
}
