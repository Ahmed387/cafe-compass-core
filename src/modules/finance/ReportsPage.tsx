import { saleRefundTotal } from "@/core/finance/formulas";
import { useQuery } from "@tanstack/react-query";
import { useCallback, useMemo, useState } from "react";

type SalesSummary = {
  revenue: number;
  refunds: number;
  discounts: number;
  cogs: number;
  count: number;
  cancelled: number;
  avg: number;
  by_day: Array<{ day: string; revenue: number; count: number }>;
  by_product: Array<{ name: string; qty: number; revenue: number }>;
  by_method: Array<{ method: string; amount: number }>;
  by_cashier: Array<{ name: string; revenue: number; count: number }>;
};

type CogsItem = {
  item_id: string;
  name: string;
  name_ar: string | null;
  unit: string;
  unit_cost: number;
  on_hand: number;
  valuation: number;
  consumed_qty: number;
  consumed_cost: number;
  waste_qty: number;
  adjust_qty: number;
};

type CogsReport = {
  items: CogsItem[];
  total_valuation: number;
  total_consumed_cost: number;
};

type ExpensesSummary = {
  approved_total: number;
  pending_total: number;
  by_category: Array<{ category: string; amount: number }>;
};

import { EmptyState, NoPermission, PageHeader } from "@/components/layout/AppShell";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
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
import { ExportCsvButton } from "@/components/ui/export-button";
import type { CsvColumn } from "@/lib/csv";

type OrderExportRow = {
  order_number: string;
  created_at: string;
  status: string;
  subtotal: number;
  discount: number;
  total: number;
  refunded: number;
  methods: string;
  cashier: string;
};
type ItemExportRow = {
  order_number: string;
  created_at: string;
  product: string;
  size: string;
  quantity: number;
  line_total: number;
  unit_cost: number;
  status: string;
};
type ExpenseExportRow = {
  expense_date: string;
  category: string;
  amount: number;
  status: string;
  approved: string;
};
type StockExportRow = {
  item: string;
  unit: string;
  quantity: number;
  cost_per_unit: number;
  value: number;
  min_qty: number;
};

const ORDER_COLUMNS: Array<CsvColumn<OrderExportRow>> = [
  { header: "Order", value: (r) => r.order_number },
  { header: "Date", value: (r) => r.created_at },
  { header: "Status", value: (r) => r.status },
  { header: "Subtotal", value: (r) => r.subtotal },
  { header: "Discount", value: (r) => r.discount },
  { header: "Total", value: (r) => r.total },
  { header: "Refunded", value: (r) => r.refunded },
  { header: "Payments", value: (r) => r.methods },
  { header: "Cashier", value: (r) => r.cashier },
];

const ITEM_COLUMNS: Array<CsvColumn<ItemExportRow>> = [
  { header: "Order", value: (r) => r.order_number },
  { header: "Date", value: (r) => r.created_at },
  { header: "Product", value: (r) => r.product },
  { header: "Size", value: (r) => r.size },
  { header: "Qty", value: (r) => r.quantity },
  { header: "Line total", value: (r) => r.line_total },
  { header: "Unit cost", value: (r) => r.unit_cost },
  { header: "Status", value: (r) => r.status },
];

const EXPENSE_COLUMNS: Array<CsvColumn<ExpenseExportRow>> = [
  { header: "Date", value: (r) => r.expense_date },
  { header: "Category", value: (r) => r.category },
  { header: "Amount", value: (r) => r.amount },
  { header: "Status", value: (r) => r.status },
  { header: "Approved", value: (r) => r.approved },
];

const STOCK_COLUMNS: Array<CsvColumn<StockExportRow>> = [
  { header: "Item", value: (r) => r.item },
  { header: "Unit", value: (r) => r.unit },
  { header: "Quantity", value: (r) => r.quantity },
  { header: "Cost per unit", value: (r) => r.cost_per_unit },
  { header: "Stock value", value: (r) => r.value },
  { header: "Min qty", value: (r) => r.min_qty },
];

function isoDay(offsetDays: number) {
  const d = new Date();
  d.setDate(d.getDate() + offsetDays);
  return d.toISOString().slice(0, 10);
}

function StatCard({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-lg border border-border bg-card p-4">
      <p className="text-xs text-muted-foreground">{label}</p>
      <p className="mt-1 text-xl font-bold">{value}</p>
    </div>
  );
}

export function ReportsPage() {
  const { t, lang } = useI18n();
  const { can, me, currentBranchId } = useAuth();
  const currency = me?.company?.currency ?? "EGP";
  const [from, setFrom] = useState(isoDay(-29));
  const [to, setTo] = useState(isoDay(0));

  const canSales = can("reports.sales") || can("pos.view");
  const canExpenses = can("reports.expenses") || can("expenses.view");
  const canInventory = can("reports.inventory") || can("inventory.view");
  // Consumption & valuation is an owner/manager screen; the RPC enforces it too.
  const canCogs = (me?.roleNames ?? []).some((role) => role === "Super Admin" || role === "Manager");

  const fromIso = `${from}T00:00:00.000Z`;
  const toIso = `${to}T23:59:59.999Z`;

  // All sales figures are aggregated on the server over the full range,
  // so no row cap can silently truncate revenue, COGS or the breakdowns.
  const salesQuery = useQuery({
    queryKey: ["report-sales", currentBranchId, from, to],
    enabled: canSales && Boolean(currentBranchId),
    queryFn: async () => {
      const { data, error } = await supabase.rpc("sales_period_summary", {
        _from: from,
        _to: to,
        _branch_id: currentBranchId!,
      });
      if (error) throw error;
      return data as unknown as SalesSummary;
    },
  });

  const expensesQuery = useQuery({
    queryKey: ["report-expenses", from, to],
    enabled: canExpenses,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("expenses_period_summary", {
        _from: from,
        _to: to,
      });
      if (error) throw error;
      return data as unknown as ExpensesSummary;
    },
  });

  const stock = useQuery({
    queryKey: ["report-stock", currentBranchId],
    enabled: canInventory && Boolean(currentBranchId),
    queryFn: async () => {
      const { data, error } = await supabase
        .from("branch_stock")
        .select("id, quantity, inventory_items(name, unit, cost_per_unit, min_qty)")
        .eq("branch_id", currentBranchId!);
      if (error) throw error;
      return data ?? [];
    },
  });

  const cogsQuery = useQuery({
    queryKey: ["report-cogs", currentBranchId, from, to],
    enabled: canCogs && Boolean(currentBranchId),
    queryFn: async () => {
      const { data, error } = await supabase.rpc("inventory_cogs_report", {
        _branch_id: currentBranchId!,
        _from: from,
        _to: to,
      });
      if (error) throw error;
      return data as unknown as CogsReport;
    },
  });
  const cogsItems = cogsQuery.data?.items ?? [];

  const sales: SalesSummary = salesQuery.data ?? {
    revenue: 0,
    refunds: 0,
    discounts: 0,
    cogs: 0,
    count: 0,
    cancelled: 0,
    avg: 0,
    by_day: [],
    by_product: [],
    by_method: [],
    by_cashier: [],
  };

  const expenseTotal = expensesQuery.data?.approved_total ?? 0;
  const expensePending = expensesQuery.data?.pending_total ?? 0;
  const expenseByCategory = expensesQuery.data?.by_category ?? [];

  const stockValue = (stock.data ?? []).reduce((sum, row) => {
    const item = row.inventory_items as unknown as { cost_per_unit: number } | null;
    return sum + Number(row.quantity) * Number(item?.cost_per_unit ?? 0);
  }, 0);

  // ---- Exports: fetched on demand, paged through the server ----
  const canReports = can("reports.view") || canSales || canExpenses || canInventory;

  const fetchOrderPages = useCallback(async () => {
    type Row = {
      order_number: string;
      created_at: string;
      status: string;
      subtotal: number;
      discount_amount: number;
      tax_amount: number;
      total: number;
      order_items: Array<{
        product_name: string;
        size_name: string | null;
        quantity: number;
        line_total: number;
        unit_cost: number;
        status: string;
      }>;
      order_payments: Array<{ method_key: string; amount: number }>;
      order_refunds: Array<{ amount: number; status: string; origin?: string | null }>;
      user_profiles: { display_name: string | null; first_name: string } | null;
    };
    const out: Row[] = [];
    const chunk = 500;
    for (let offset = 0; ; offset += chunk) {
      const { data, error } = await supabase
        .from("orders")
        .select(
          "order_number, status, total, subtotal, discount_amount, created_at, order_items(product_name, size_name, quantity, line_total, unit_cost, status), order_payments(method_key, amount), order_refunds(amount, status, origin), user_profiles!orders_created_by_fkey(display_name, first_name)",
        )
        .eq("branch_id", currentBranchId!)
        .gte("created_at", fromIso)
        .lte("created_at", toIso)
        .order("created_at", { ascending: false })
        .range(offset, offset + chunk - 1);
      if (error) throw error;
      out.push(...((data ?? []) as unknown as Row[]));
      if ((data ?? []).length < chunk) break;
    }
    return out;
  }, [currentBranchId, fromIso, toIso]);

  const fetchOrderRows = useCallback(async (): Promise<OrderExportRow[]> => {
    const list = await fetchOrderPages();
    return list.map((o) => ({
      order_number: o.order_number,
      created_at: o.created_at,
      status: o.status,
      subtotal: Number(o.subtotal),
      discount: Number(o.discount_amount),
      total: Number(o.total),
      refunded: saleRefundTotal(o.order_refunds),
      methods: (o.order_payments ?? []).map((p) => `${p.method_key}:${p.amount}`).join(" | "),
      cashier: o.user_profiles?.display_name || o.user_profiles?.first_name || "",
    }));
  }, [fetchOrderPages]);

  const fetchItemRows = useCallback(async (): Promise<ItemExportRow[]> => {
    const list = await fetchOrderPages();
    return list.flatMap((o) =>
      (o.order_items ?? []).map((i) => ({
        order_number: o.order_number,
        created_at: o.created_at,
        product: i.product_name,
        size: i.size_name ?? "",
        quantity: i.quantity,
        line_total: Number(i.line_total),
        unit_cost: Number(i.unit_cost),
        status: i.status,
      })),
    );
  }, [fetchOrderPages]);

  const fetchExpenseRows = useCallback(async (): Promise<ExpenseExportRow[]> => {
    const out: ExpenseExportRow[] = [];
    const chunk = 1000;
    for (let offset = 0; ; offset += chunk) {
      const { data, error } = await supabase
        .from("expenses")
        .select("amount, expense_date, status, approved_at, expense_categories(name)")
        .gte("expense_date", from)
        .lte("expense_date", to)
        .order("expense_date", { ascending: false })
        .range(offset, offset + chunk - 1);
      if (error) throw error;
      for (const e of data ?? []) {
        out.push({
          expense_date: e.expense_date,
          category: (e.expense_categories as unknown as { name: string } | null)?.name ?? "",
          amount: Number(e.amount),
          status: e.status,
          approved: e.approved_at ? "yes" : "no",
        });
      }
      if ((data ?? []).length < chunk) break;
    }
    return out;
  }, [from, to]);

  const stockRows = useMemo<StockExportRow[]>(
    () =>
      (stock.data ?? []).map((row) => {
        const item = row.inventory_items as unknown as {
          name: string;
          unit: string;
          cost_per_unit: number;
          min_qty: number;
        } | null;
        return {
          item: item?.name ?? "",
          unit: item?.unit ?? "",
          quantity: Number(row.quantity),
          cost_per_unit: Number(item?.cost_per_unit ?? 0),
          value: Number(row.quantity) * Number(item?.cost_per_unit ?? 0),
          min_qty: Number(item?.min_qty ?? 0),
        };
      }),
    [stock.data],
  );

  if (!canSales && !canExpenses && !canInventory)
    return <NoPermission message={t("common.noAccess")} />;

  const money = (value: number) => formatMoney(value, currency, lang);
  const maxDay = Math.max(1, ...sales.by_day.map((d) => Number(d.revenue)));

  return (
    <div>
      <PageHeader
        title={t("rep.title")}
        description={t("rep.subtitle")}
        action={
          canReports && (
            <div className="flex flex-wrap gap-2">
              <ExportCsvButton
                fetchRows={fetchOrderRows}
                columns={ORDER_COLUMNS}
                filePrefix="sales-orders"
                label={lang === "ar" ? "تصدير المبيعات" : "Export sales"}
              />
              <ExportCsvButton
                fetchRows={fetchItemRows}
                columns={ITEM_COLUMNS}
                filePrefix="sales-items"
                label={lang === "ar" ? "تصدير الأصناف المبيعة" : "Export sold items"}
              />
              {canExpenses && (
                <ExportCsvButton
                  fetchRows={fetchExpenseRows}
                  columns={EXPENSE_COLUMNS}
                  filePrefix="expenses"
                  label={lang === "ar" ? "تصدير المصروفات" : "Export expenses"}
                />
              )}

              {canInventory && (
                <ExportCsvButton
                  rows={stockRows}
                  columns={STOCK_COLUMNS}
                  filePrefix="inventory-stock"
                  label={lang === "ar" ? "تصدير المخزون" : "Export stock"}
                />
              )}
            </div>
          )
        }
      />

      <div className="mb-5 flex flex-wrap items-end gap-3">
        <div className="grid gap-1">
          <Label htmlFor="from">{t("rep.from")}</Label>
          <Input id="from" type="date" value={from} onChange={(e) => setFrom(e.target.value)} />
        </div>
        <div className="grid gap-1">
          <Label htmlFor="to">{t("rep.to")}</Label>
          <Input id="to" type="date" value={to} onChange={(e) => setTo(e.target.value)} />
        </div>
      </div>

      <div className="stagger mb-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <StatCard label={t("rep.revenue")} value={money(sales.revenue)} />
        <StatCard label={t("rep.orders")} value={String(sales.count)} />
        <StatCard label={t("rep.avgTicket")} value={money(sales.avg)} />
        <StatCard label={t("rep.grossProfit")} value={money(sales.revenue - sales.cogs)} />
        <StatCard label={t("rep.cogs")} value={money(sales.cogs)} />
        <StatCard label={t("rep.discounts")} value={money(sales.discounts)} />
        <StatCard label={t("rep.refunds")} value={money(sales.refunds)} />
        <StatCard label={t("rep.expenses")} value={canExpenses ? money(expenseTotal) : "—"} />
        {canExpenses && expensePending > 0 && (
          <StatCard label={t("rep.expensesPending")} value={money(expensePending)} />
        )}
        <StatCard label={t("rep.stockValue")} value={canInventory ? money(stockValue) : "—"} />
      </div>

      <Tabs defaultValue="daily">
        <div className="-mx-1 overflow-x-auto px-1 pb-1">
          <TabsList className="w-max">
            <TabsTrigger value="daily">{t("rep.daily")}</TabsTrigger>
            <TabsTrigger value="products">{t("rep.products")}</TabsTrigger>
            <TabsTrigger value="methods">{t("rep.methods")}</TabsTrigger>
            <TabsTrigger value="cashiers">{t("rep.cashiers")}</TabsTrigger>
            {canExpenses && <TabsTrigger value="expenses">{t("rep.expenses")}</TabsTrigger>}
            {canInventory && <TabsTrigger value="stock">{t("rep.stock")}</TabsTrigger>}
            {canCogs && (
              <TabsTrigger value="cogs">
                {lang === "ar" ? "استهلاك وتكلفة المخزون" : "Consumption & COGS"}
              </TabsTrigger>
            )}
          </TabsList>
        </div>

        <TabsContent value="daily" className="mt-4">
          {sales.by_day.length === 0 ? (
            <EmptyState message={t("rep.empty")} />
          ) : (
            <div className="rounded-lg border border-border bg-card p-4">
              <div className="space-y-2">
                {sales.by_day.map((row) => (
                  <div key={row.day} className="flex items-center gap-3 text-sm">
                    <span className="w-28 shrink-0 text-muted-foreground">
                      {formatDate(row.day, lang)}
                    </span>
                    <div className="h-2.5 flex-1 overflow-hidden rounded-full bg-muted">
                      <div
                        className="h-full rounded-full bg-primary"
                        style={{ width: `${(Number(row.revenue) / maxDay) * 100}%` }}
                      />
                    </div>
                    <span className="w-16 shrink-0 text-end text-xs text-muted-foreground">
                      {row.count}
                    </span>
                    <span className="w-28 shrink-0 text-end font-medium">
                      {money(Number(row.revenue))}
                    </span>
                  </div>
                ))}
              </div>
            </div>
          )}
        </TabsContent>

        <TabsContent value="products" className="mt-4">
          {sales.by_product.length === 0 ? (
            <EmptyState message={t("rep.empty")} />
          ) : (
            <div className="overflow-x-auto rounded-lg border border-border bg-card">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>{t("common.name")}</TableHead>
                    <TableHead>{t("rep.qty")}</TableHead>
                    <TableHead className="text-end">{t("rep.revenue")}</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {sales.by_product.map((row) => (
                    <TableRow key={row.name}>
                      <TableCell className="font-medium">{row.name}</TableCell>
                      <TableCell>{row.qty}</TableCell>
                      <TableCell className="text-end">{money(Number(row.revenue))}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          )}
        </TabsContent>

        <TabsContent value="methods" className="mt-4">
          {sales.by_method.length === 0 ? (
            <EmptyState message={t("rep.empty")} />
          ) : (
            <div className="overflow-x-auto rounded-lg border border-border bg-card">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>{t("pos.method")}</TableHead>
                    <TableHead className="text-end">{t("common.total")}</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {sales.by_method.map((row) => (
                    <TableRow key={row.method}>
                      <TableCell className="font-medium">{row.method}</TableCell>
                      <TableCell className="text-end">{money(Number(row.amount))}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          )}
        </TabsContent>

        <TabsContent value="cashiers" className="mt-4">
          {sales.by_cashier.length === 0 ? (
            <EmptyState message={t("rep.empty")} />
          ) : (
            <div className="overflow-x-auto rounded-lg border border-border bg-card">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>{t("audit.user")}</TableHead>
                    <TableHead>{t("rep.orders")}</TableHead>
                    <TableHead className="text-end">{t("rep.revenue")}</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {sales.by_cashier.map((row) => (
                    <TableRow key={row.name}>
                      <TableCell className="font-medium">{row.name}</TableCell>
                      <TableCell>{row.count}</TableCell>
                      <TableCell className="text-end">{money(Number(row.revenue))}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          )}
        </TabsContent>

        {canExpenses && (
          <TabsContent value="expenses" className="mt-4">
            {expenseByCategory.length === 0 ? (
              <EmptyState message={t("rep.empty")} />
            ) : (
              <div className="overflow-x-auto rounded-lg border border-border bg-card">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>{t("fin.category")}</TableHead>
                      <TableHead className="text-end">{t("common.total")}</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {expenseByCategory.map((row) => (
                      <TableRow key={row.category}>
                        <TableCell className="font-medium">{row.category}</TableCell>
                        <TableCell className="text-end">{money(Number(row.amount))}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </div>
            )}
          </TabsContent>
        )}

        {canInventory && (
          <TabsContent value="stock" className="mt-4">
            {(stock.data ?? []).length === 0 ? (
              <EmptyState message={t("rep.empty")} />
            ) : (
              <div className="overflow-x-auto rounded-lg border border-border bg-card">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>{t("common.name")}</TableHead>
                      <TableHead>{t("rep.qty")}</TableHead>
                      <TableHead className="text-end">{t("rep.value")}</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {(stock.data ?? []).map((row) => {
                      const item = row.inventory_items as unknown as {
                        name: string;
                        unit: string;
                        cost_per_unit: number;
                        min_qty: number;
                      } | null;
                      const low = Number(row.quantity) <= Number(item?.min_qty ?? 0);
                      return (
                        <TableRow key={row.id}>
                          <TableCell className="font-medium">{item?.name ?? "—"}</TableCell>
                          <TableCell className={low ? "font-medium text-destructive" : undefined}>
                            {Number(row.quantity)} {item?.unit}
                          </TableCell>
                          <TableCell className="text-end">
                            {money(Number(row.quantity) * Number(item?.cost_per_unit ?? 0))}
                          </TableCell>
                        </TableRow>
                      );
                    })}
                  </TableBody>
                </Table>
              </div>
            )}
          </TabsContent>
        )}

        {canCogs && (
          <TabsContent value="cogs" className="mt-4">
            <div className="mb-3 grid gap-3 sm:grid-cols-2">
              <StatCard
                label={lang === "ar" ? "تكلفة المستهلك في البيع" : "Cost of goods sold"}
                value={money(Number(cogsQuery.data?.total_consumed_cost ?? 0))}
              />
              <StatCard
                label={lang === "ar" ? "صافي قيمة المخزون المتبقي" : "Remaining stock value"}
                value={money(Number(cogsQuery.data?.total_valuation ?? 0))}
              />
            </div>
            {cogsItems.length === 0 ? (
              <EmptyState message={t("rep.empty")} />
            ) : (
              <div className="overflow-x-auto rounded-lg border border-border bg-card">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>{t("common.name")}</TableHead>
                      <TableHead>{lang === "ar" ? "الرصيد الحالي" : "On hand"}</TableHead>
                      <TableHead>{lang === "ar" ? "مستهلك بالبيع" : "Sold / consumed"}</TableHead>
                      <TableHead>{lang === "ar" ? "تكلفة المستهلك" : "Consumed cost"}</TableHead>
                      <TableHead>{lang === "ar" ? "هالك" : "Waste"}</TableHead>
                      <TableHead className="text-end">
                        {lang === "ar" ? "قيمة المتبقي" : "Valuation"}
                      </TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {cogsItems.map((row) => (
                      <TableRow key={row.item_id}>
                        <TableCell className="font-medium">
                          {lang === "ar" ? row.name_ar || row.name : row.name}
                        </TableCell>
                        <TableCell>
                          {Number(row.on_hand)} {row.unit}
                        </TableCell>
                        <TableCell>
                          {Number(row.consumed_qty)} {row.unit}
                        </TableCell>
                        <TableCell>{money(Number(row.consumed_cost))}</TableCell>
                        <TableCell>
                          {Number(row.waste_qty)} {row.unit}
                        </TableCell>
                        <TableCell className="text-end">{money(Number(row.valuation))}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </div>
            )}
          </TabsContent>
        )}
      </Tabs>
    </div>
  );
}
