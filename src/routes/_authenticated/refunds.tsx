import { useQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";

import { EmptyState, NoPermission, PageHeader } from "@/components/layout/AppShell";
import { RefundReclassifyDialog } from "@/components/orders/RefundReclassifyDialog";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
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
import { addDays, businessToday } from "@/core/finance/business-dates";
import { isCancellation, splitRefundStats } from "@/core/finance/cancellations";

export const Route = createFileRoute("/_authenticated/refunds")({
  head: () => ({
    meta: [
      { title: "Refunds & cancellations — 20s Coffee" },
      {
        name: "description",
        content: "Customer refunds and cancellations for 20s Coffee: amounts, methods, reasons.",
      },
      { property: "og:title", content: "Refunds & cancellations — 20s Coffee" },
      { property: "og:description", content: "Every refund, cancellation and waste record, searchable by invoice." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: RefundsPage,
});

type RefundEntry = {
  product_name?: string;
  quantity?: number;
  disposition?: string;
  unit_cost?: number | string;
};

type RefundRow = {
  id: string;
  created_at: string;
  kind: string;
  amount: number;
  tax_amount: number;
  method_key: string | null;
  reason: string | null;
  status: string;
  origin: string | null;
  is_cancellation: boolean | null;
  reclassify_note: string | null;
  items_payload: RefundEntry[] | null;
  orders: {
    shift_id: string | null;
    order_number: string | null;
    table_number: string | null;
    customer_name: string | null;
    user_profiles: { display_name: string | null; first_name: string; last_name: string } | null;
  } | null;
};

function isoDay(offsetDays: number) {
  return addDays(businessToday(), offsetDays);
}

function RefundsPage() {
  const { t, lang } = useI18n();
  const { can, me, currentBranchId } = useAuth();
  const currency = me?.company?.currency ?? "EGP";
  const ar = lang === "ar";
  const canView = can("pos.view") || can("reports.sales");
  const [q, setQ] = useState("");
  const [shiftNo, setShiftNo] = useState("");
  const [from, setFrom] = useState(isoDay(-29));
  const [to, setTo] = useState(isoDay(0));
  const [switching, setSwitching] = useState<string | null>(null);
  const [view, setView] = useState<"all" | "refunds" | "cancellations">("all");
  const isSuperAdmin = Boolean(me?.roleNames?.includes("Super Admin"));

  // Same sequential drawer numbering as the orders screen, for reconciliation.
  const shiftNumbers = useQuery({
    queryKey: ["shift-sequence", currentBranchId],
    enabled: canView && Boolean(currentBranchId),
    queryFn: async () => {
      const { data, error } = await supabase
        .from("shifts")
        .select("id")
        .eq("branch_id", currentBranchId!)
        .order("opened_at", { ascending: true })
        .limit(1000);
      if (error) throw error;
      const map: Record<string, number> = {};
      (data ?? []).forEach((row, index) => {
        map[row.id] = index + 1;
      });
      return map;
    },
  });

  const refunds = useQuery({
    queryKey: ["refunds-log", currentBranchId, from, to, q],
    enabled: canView && Boolean(currentBranchId),
    queryFn: async () => {
      let query = supabase
        .from("order_refunds")
        .select(
          "id, created_at, kind, amount, tax_amount, method_key, reason, status, origin, is_cancellation, reclassify_note, items_payload, orders!inner(shift_id, order_number, table_number, customer_name, branch_id, user_profiles!orders_created_by_fkey(display_name, first_name, last_name))",
        )
        .eq("orders.branch_id", currentBranchId!)
        .gte("business_date", from)
        .lte("business_date", to)
        .order("created_at", { ascending: false })
        .limit(200);
      const s = q.trim();
      if (s) {
        const dayMatch = /^(\d{4}-\d{2}-\d{2})$/.exec(s);
        if (dayMatch && dayMatch[1]) {
          const day = dayMatch[1];
          query = query.eq("business_date", day);
        } else {
          const safe = s.replace(/[%,()]/g, "").trim();
          if (safe) {
            const parts = [
              `orders.order_number.ilike.%${safe}%`,
              `orders.customer_name.ilike.%${safe}%`,
              `orders.table_number.eq.${safe}`,
              `orders.user_profiles.display_name.ilike.%${safe}%`,
              `orders.user_profiles.first_name.ilike.%${safe}%`,
            ];
            const { data: hits, error: hitsError } = await supabase
              .from("order_items")
              .select("order_id, orders!inner(branch_id)")
              .eq("orders.branch_id", currentBranchId!)
              .ilike("product_name", `%${safe}%`)
              .limit(500);
            if (hitsError) throw hitsError;
            const ids = Array.from(new Set((hits ?? []).map((hit) => hit.order_id)));
            if (ids.length > 0) parts.push(`id.in.(${ids.join(",")})`);
            query = query.or(parts.join(","));
          }
        }
      }
      const { data, error } = await query;
      if (error) throw error;
      return (data ?? []) as unknown as RefundRow[];
    },
  });

  const inRange = (refunds.data ?? []).filter(
    (row) => !shiftNo || String(row.orders?.shift_id ? shiftNumbers.data?.[row.orders.shift_id] ?? "" : "") === shiftNo,
  );
  // Cancelled items are not refunds: counted apart (owner rule 2026-10-24).
  const stats = splitRefundStats(inRange);
  const rows =
    view === "all" ? inRange : inRange.filter((row) => isCancellation(row) === (view === "cancellations"));
  // Waste of the rows on screen, so each tab's waste card matches its list.
  const viewWaste = splitRefundStats(rows).waste;

  if (!canView) return <NoPermission message={t("common.noAccess")} />;

  const cashierName = (row: RefundRow) => {
    const profile = row.orders?.user_profiles;
    return profile?.display_name || [profile?.first_name, profile?.last_name].filter(Boolean).join(" ") || "—";
  };

  return (
    <div>
      <PageHeader
        title={ar ? "المرتجعات والإلغاءات" : "Refunds & cancellations"}
        description={
          ar
            ? "المرتجع فلوس رجعت للعميل وبتتخصم من المبيعات. الإلغاء صنف أو طلب اتشال كأنه ماتباعش. الاتنين مع الهالك والسبب."
            : "A refund is money given back and comes off sales. A cancellation is an item or order removed as if never sold. Both with waste and reason."
        }
      />

      <Tabs value={view} onValueChange={(v) => setView(v as typeof view)} className="mb-4">
        <TabsList>
          <TabsTrigger value="all">
            {ar ? "الكل" : "All"} <span className="ms-1.5 tabular-nums text-muted-foreground">{inRange.length}</span>
          </TabsTrigger>
          <TabsTrigger value="refunds">
            {ar ? "المرتجعات" : "Refunds"} <span className="ms-1.5 tabular-nums text-muted-foreground">{stats.count}</span>
          </TabsTrigger>
          <TabsTrigger value="cancellations">
            {ar ? "الإلغاءات" : "Cancellations"}{" "}
            <span className="ms-1.5 tabular-nums text-muted-foreground">{stats.cancelCount}</span>
          </TabsTrigger>
        </TabsList>
      </Tabs>

      <div className="mb-4 flex flex-wrap items-end gap-3">
        <div className="grid gap-1">
          <Label htmlFor="refunds-from">{t("range.from")}</Label>
          <Input
            id="refunds-from"
            type="date"
            value={from}
            onChange={(e) => setFrom(e.target.value)}
          />
        </div>
        <div className="grid gap-1">
          <Label htmlFor="refunds-to">{t("range.to")}</Label>
          <Input id="refunds-to" type="date" value={to} onChange={(e) => setTo(e.target.value)} />
        </div>
        <div className="grid gap-1">
          <Label htmlFor="refunds-shift">{ar ? "رقم الوردية" : "Shift #"}</Label>
          <Input id="refunds-shift" inputMode="numeric" className="w-24" placeholder="#" value={shiftNo} onChange={(e) => setShiftNo(e.target.value.replace(/[^0-9]/g, ""))} />
        </div>
        <div className="min-w-[240px] flex-1 grid gap-1">
          <Label htmlFor="refunds-search">{t("orders.searchPlaceholder")}</Label>
          <Input
            id="refunds-search"
            value={q}
            placeholder={t("orders.searchPlaceholder")}
            onChange={(e) => setQ(e.target.value)}
          />
        </div>
      </div>

      <div className="stagger mb-5 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {view !== "cancellations" && (
          <>
            <StatCard label={ar ? "عدد المرتجعات" : "Refunds"} value={String(stats.count)} />
            <StatCard label={t("orders.refundedTotal")} value={formatMoney(stats.total, currency, lang)} />
            <StatCard label={ar ? "مرتجعات كاش" : "Cash refunds"} value={formatMoney(stats.cash, currency, lang)} />
          </>
        )}
        {view !== "refunds" && (
          <>
            <StatCard dashed label={ar ? "عدد الإلغاءات" : "Cancellations"} value={String(stats.cancelCount)} />
            <StatCard
              dashed
              label={ar ? "مبلغ الإلغاءات (مش مرتجع)" : "Cancelled amount (not refunds)"}
              value={formatMoney(stats.cancelTotal, currency, lang)}
            />
          </>
        )}
        <StatCard label={t("refunds.waste")} value={formatMoney(viewWaste, currency, lang)} />
      </div>

      {rows.length === 0 ? (
        <EmptyState
          message={
            view === "cancellations"
              ? ar ? "مفيش إلغاءات في الفترة دي." : "No cancellations in this range."
              : view === "refunds"
                ? ar ? "مفيش مرتجعات في الفترة دي." : "No refunds in this range."
                : ar ? "مفيش مرتجعات ولا إلغاءات في الفترة دي." : "No refunds or cancellations in this range."
          }
        />
      ) : (
        <div className="overflow-x-auto rounded-lg border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead className="w-44 whitespace-nowrap text-center">
                  {t("common.date")}
                </TableHead>
                <TableHead className="w-36 whitespace-nowrap text-start">#</TableHead>
                <TableHead className="w-24 whitespace-nowrap text-center">
                  {t("orders.shiftNo")}
                </TableHead>
                <TableHead className="w-20 whitespace-nowrap text-center">{t("orders.table")}</TableHead>
                <TableHead className="min-w-48 text-start">
                  {ar ? "الأصناف" : "Items"}
                </TableHead>
                <TableHead className="w-28 whitespace-nowrap text-center">
                  {t("pos.method")}
                </TableHead>
                <TableHead className="w-32 whitespace-nowrap text-end">
                  {t("common.total")}
                </TableHead>
                <TableHead className="w-28 whitespace-nowrap text-center">
                  {t("common.status")}
                </TableHead>
                <TableHead className="min-w-40 text-start">{t("orders.reason")}</TableHead>
                <TableHead className="w-32 whitespace-nowrap text-center">
                  {t("audit.user")}
                </TableHead>
                {isSuperAdmin && <TableHead className="w-28 whitespace-nowrap text-center" />}
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row) => {
                const wasteOnly =
                  (row.items_payload ?? []).length > 0 &&
                  (row.items_payload ?? []).every((entry) => entry.disposition === "waste");
                const cancelled = isCancellation(row);
                return (
                  <TableRow key={row.id} className={cancelled ? "text-muted-foreground" : undefined}>
                    <TableCell className="w-44 whitespace-nowrap text-center">
                      {formatDateTime(row.created_at, lang)}
                    </TableCell>
                    <TableCell className="w-36 whitespace-nowrap font-medium">
                      #{invoiceSequence(row.orders?.order_number ?? "1")}
                    </TableCell>
                    <TableCell className="w-24 whitespace-nowrap text-center tabular-nums">
                      {row.orders?.shift_id
                        ? (shiftNumbers.data?.[row.orders.shift_id] ?? "—")
                        : "—"}
                    </TableCell>
                    <TableCell className="w-20 whitespace-nowrap text-center font-bold tabular-nums">
                      {row.orders?.table_number || "—"}
                    </TableCell>
                    <TableCell className="min-w-48 max-w-72 text-xs text-muted-foreground">
                      {(row.items_payload ?? [])
                        .map(
                          (entry) =>
                            `${entry.quantity}× ${entry.product_name ?? "?"}${
                              entry.disposition === "waste" ? " ⚠" : ""
                            }`,
                        )
                        .join(", ") || (row.origin === "void" ? (ar ? "إلغاء صنف" : "Voided line") : "—")}
                    </TableCell>
                    <TableCell className="w-28 text-center text-xs">
                      {row.method_key ?? "cash"}
                    </TableCell>
                    <TableCell className="w-32 whitespace-nowrap text-end tabular-nums">
                      {formatMoney(row.amount, currency, lang)}
                    </TableCell>
                    <TableCell className="w-28 text-center">
                      <Badge variant={cancelled ? "secondary" : wasteOnly ? "destructive" : "outline"}>
                        {cancelled
                          ? ar ? "إلغاء" : "Cancelled"
                          : wasteOnly
                            ? t("orders.waste")
                            : row.kind === "full"
                              ? t("orders.refundFull")
                              : t("orders.refundPartial")}
                      </Badge>
                    </TableCell>
                    <TableCell className="min-w-40 max-w-64 text-xs text-muted-foreground">
                      {row.reason ?? "—"}
                      {row.reclassify_note && (
                        <span className="mt-1 block">
                          {ar ? "اتغيّر نوعها: " : "Type switched: "}
                          {row.reclassify_note}
                        </span>
                      )}
                    </TableCell>
                    <TableCell className="w-32 text-center text-xs">{cashierName(row)}</TableCell>
                    {isSuperAdmin && (
                      <TableCell className="w-28 text-center">
                        {(row.origin === "void" || row.origin === "cancel") && (
                          <Button size="sm" variant="ghost" className="h-7 text-xs" onClick={() => setSwitching(row.id)}>
                            {cancelled ? (ar ? "خليه مرتجع" : "Make refund") : (ar ? "خليه إلغاء" : "Make cancellation")}
                          </Button>
                        )}
                      </TableCell>
                    )}
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </div>
      )}
      <RefundReclassifyDialog refundId={switching} currency={currency} lang={lang} onClose={() => setSwitching(null)} />
    </div>
  );
}

function StatCard({ label, value, dashed }: { label: string; value: string; dashed?: boolean }) {
  return (
    <div className={`rounded-lg border border-border bg-card p-4 ${dashed ? "border-dashed" : ""}`}>
      <p className="text-xs text-muted-foreground">{label}</p>
      <p className="mt-1 text-xl font-bold tabular-nums">{value}</p>
    </div>
  );
}
