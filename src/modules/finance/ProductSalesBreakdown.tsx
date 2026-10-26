import { useQuery } from "@tanstack/react-query";
import { Fragment, useMemo, useState } from "react";

import { EmptyState } from "@/components/layout/AppShell";
import { ExportCsvButton } from "@/components/ui/export-button";
import { Input } from "@/components/ui/input";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { groupProductSales, type ProductSaleRow } from "@/core/finance/product-sales";
import { supabase } from "@/integrations/supabase/client";
import type { CsvColumn } from "@/lib/csv";
import { formatMoney } from "@/lib/format";
import { useI18n } from "@/lib/i18n";

type Breakdown = {
  rows: ProductSaleRow[];
  excluded: { count: number; total: number };
  invoice_discounts: number;
  with_costs: boolean;
};

const CSV_COLUMNS: Array<CsvColumn<ProductSaleRow>> = [
  { header: "Product", value: (r) => r.product },
  { header: "Size", value: (r) => r.size },
  { header: "Sold at", value: (r) => Number(r.price) },
  { header: "Qty", value: (r) => Number(r.qty) },
  { header: "Total", value: (r) => Number(r.revenue) },
  { header: "Cost", value: (r) => (r.cost === null ? "" : Number(r.cost)) },
  { header: "Profit", value: (r) => (r.profit === null ? "" : Number(r.profit)) },
];

/**
 * Every product sold in the range, by size and by each price it was sold at:
 * how many at that price, their total, cost and profit. Clean sales only;
 * invoices with any refund or cancellation are left out (counted apart).
 */
export function ProductSalesBreakdown({
  from,
  to,
  branchId,
  currency,
}: {
  from: string;
  to: string;
  branchId: string | null;
  currency: string;
}) {
  const { lang } = useI18n();
  const ar = lang === "ar";
  const money = (v: number) => formatMoney(v, currency, lang);
  const [q, setQ] = useState("");

  const report = useQuery({
    queryKey: ["product-sales-breakdown", branchId, from, to],
    enabled: Boolean(branchId),
    queryFn: async () => {
      const { data, error } = await supabase.rpc("product_sales_breakdown", {
        _from: from,
        _to: to,
        _branch_id: branchId!,
      });
      if (error) throw error;
      return data as unknown as Breakdown;
    },
  });

  const rows = report.data?.rows ?? [];
  const withCosts = Boolean(report.data?.with_costs);
  const groups = useMemo(() => groupProductSales(rows), [rows]);
  const shown = q.trim()
    ? groups.filter((g) => g.product.toLowerCase().includes(q.trim().toLowerCase()))
    : groups;
  const totals = shown.reduce(
    (acc, g) => ({
      qty: acc.qty + g.qty,
      revenue: acc.revenue + g.revenue,
      cost: acc.cost + (g.cost ?? 0),
      profit: acc.profit + (g.profit ?? 0),
    }),
    { qty: 0, revenue: 0, cost: 0, profit: 0 },
  );
  const margin = (profit: number | null, revenue: number) =>
    profit === null || revenue <= 0 ? "—" : `${Math.round((profit / revenue) * 100)}%`;
  const excluded = report.data?.excluded;

  if (report.isLoading)
    return <p className="text-sm text-muted-foreground">{ar ? "بيحمّل…" : "Loading…"}</p>;
  if (groups.length === 0)
    return <EmptyState message={ar ? "مفيش مبيعات في الفترة دي." : "No sales in this range."} />;

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <Input
          value={q}
          onChange={(e) => setQ(e.target.value)}
          placeholder={ar ? "ابحث باسم المنتج…" : "Search product…"}
          className="max-w-xs"
        />
        <ExportCsvButton
          rows={rows}
          columns={CSV_COLUMNS}
          filePrefix="product-sales"
          label={ar ? "تصدير الجدول" : "Export table"}
        />
      </div>
      <p className="text-xs text-muted-foreground">
        {ar
          ? "المبيعات السليمة بس: أي فاتورة فيها مرتجع أو إلغاء مش محسوبة هنا."
          : "Clean sales only: any invoice with a refund or cancellation is left out."}
        {excluded && excluded.count > 0
          ? ar
            ? ` (اتستبعد ${excluded.count} فاتورة بقيمة ${money(Number(excluded.total))})`
            : ` (${excluded.count} invoices left out, ${money(Number(excluded.total))})`
          : ""}
        {Number(report.data?.invoice_discounts ?? 0) > 0
          ? ar
            ? ` · خصومات على الفواتير مش متوزعة على المنتجات: ${money(Number(report.data?.invoice_discounts))}`
            : ` · Invoice discounts not split over products: ${money(Number(report.data?.invoice_discounts))}`
          : ""}
      </p>

      <div className="overflow-x-auto rounded-lg border border-border bg-card">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead className="min-w-44 text-start">
                {ar ? "المنتج / الحجم" : "Product / size"}
              </TableHead>
              <TableHead className="w-28 whitespace-nowrap text-center">
                {ar ? "اتباع بـ" : "Sold at"}
              </TableHead>
              <TableHead className="w-20 whitespace-nowrap text-center">
                {ar ? "الكمية" : "Qty"}
              </TableHead>
              <TableHead className="w-32 whitespace-nowrap text-end">
                {ar ? "المجموع" : "Total"}
              </TableHead>
              {withCosts && (
                <>
                  <TableHead className="w-32 whitespace-nowrap text-end">
                    {ar ? "التكلفة" : "Cost"}
                  </TableHead>
                  <TableHead className="w-32 whitespace-nowrap text-end">
                    {ar ? "الربح" : "Profit"}
                  </TableHead>
                  <TableHead className="w-20 whitespace-nowrap text-center">
                    {ar ? "الهامش" : "Margin"}
                  </TableHead>
                </>
              )}
              <TableHead className="w-0 p-0" />
            </TableRow>
          </TableHeader>
          <TableBody>
            {shown.map((g) => (
              <Fragment key={g.product}>
                <TableRow className="bg-muted/40 font-semibold hover:bg-muted/40">
                  <TableCell className="text-start">{g.product}</TableCell>
                  <TableCell className="text-center text-xs font-normal text-muted-foreground">
                    {g.lines.length > 1
                      ? ar
                        ? `${g.lines.length} أسعار/أحجام`
                        : `${g.lines.length} prices/sizes`
                      : ""}
                  </TableCell>
                  <TableCell className="text-center tabular-nums">{g.qty}</TableCell>
                  <TableCell className="whitespace-nowrap text-end tabular-nums">
                    {money(g.revenue)}
                  </TableCell>
                  {withCosts && (
                    <>
                      <TableCell className="whitespace-nowrap text-end tabular-nums">
                        {money(g.cost ?? 0)}
                      </TableCell>
                      <TableCell
                        className={`whitespace-nowrap text-end tabular-nums ${(g.profit ?? 0) < 0 ? "text-destructive" : ""}`}
                      >
                        {money(g.profit ?? 0)}
                      </TableCell>
                      <TableCell className="text-center tabular-nums">
                        {margin(g.profit, g.revenue)}
                      </TableCell>
                    </>
                  )}
                  <TableCell className="w-0 p-0" />
                </TableRow>
                {g.lines.map((l) => (
                  <TableRow key={`${g.product}|${l.size}|${l.price}`} className="text-sm">
                    <TableCell className="ps-8 text-start text-muted-foreground">
                      {l.size || "—"}
                    </TableCell>
                    <TableCell className="whitespace-nowrap text-center tabular-nums">
                      {money(l.price)}
                    </TableCell>
                    <TableCell className="text-center tabular-nums">× {l.qty}</TableCell>
                    <TableCell className="whitespace-nowrap text-end tabular-nums">
                      {money(l.revenue)}
                    </TableCell>
                    {withCosts && (
                      <>
                        <TableCell className="whitespace-nowrap text-end tabular-nums text-muted-foreground">
                          {money(l.cost ?? 0)}
                        </TableCell>
                        <TableCell
                          className={`whitespace-nowrap text-end tabular-nums ${(l.profit ?? 0) < 0 ? "text-destructive" : ""}`}
                        >
                          {money(l.profit ?? 0)}
                        </TableCell>
                        <TableCell className="text-center tabular-nums text-muted-foreground">
                          {margin(l.profit, l.revenue)}
                        </TableCell>
                      </>
                    )}
                    <TableCell className="w-0 p-0" />
                  </TableRow>
                ))}
              </Fragment>
            ))}
            <TableRow className="border-t-2 font-bold">
              <TableCell className="text-start">{ar ? "الإجمالي" : "Total"}</TableCell>
              <TableCell />
              <TableCell className="text-center tabular-nums">{totals.qty}</TableCell>
              <TableCell className="whitespace-nowrap text-end tabular-nums">
                {money(totals.revenue)}
              </TableCell>
              {withCosts && (
                <>
                  <TableCell className="whitespace-nowrap text-end tabular-nums">
                    {money(totals.cost)}
                  </TableCell>
                  <TableCell className="whitespace-nowrap text-end tabular-nums">
                    {money(totals.profit)}
                  </TableCell>
                  <TableCell className="text-center tabular-nums">
                    {margin(totals.profit, totals.revenue)}
                  </TableCell>
                </>
              )}
              <TableCell className="w-0 p-0" />
            </TableRow>
          </TableBody>
        </Table>
      </div>
    </div>
  );
}
