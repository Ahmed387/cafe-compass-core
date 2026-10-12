import { useQuery } from "@tanstack/react-query";
import { useMemo, useState } from "react";

import { EmptyState, NoPermission, PageHeader } from "@/components/layout/AppShell";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
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
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { formatDateTime, formatMoney } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { buildProductPlan, tierLabel, type PlanTier } from "@/lib/product-plan";

function isoDaysAgo(days: number) {
  const d = new Date();
  d.setDate(d.getDate() - days);
  return d.toISOString().slice(0, 10);
}

export function AnalyticsPage() {
  const { t, lang } = useI18n();
  const { can, me } = useAuth();
  const currency = me?.company?.currency ?? "EGP";
  const [from, setFrom] = useState(isoDaysAgo(30));
  const [to, setTo] = useState(new Date().toISOString().slice(0, 10));

  const canView = can("analytics.view") || can("reports.sales");

  const demand = useQuery({
    queryKey: ["product-demand", from, to],
    enabled: canView,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("product_demand", { _from: from, _to: to });
      if (error) throw error;
      return data ?? [];
    },
  });

  const rows = useMemo(() => {
    const list = (demand.data ?? []).map((row) => ({
      ...row,
      qty: Number(row.qty ?? 0),
      revenue: Number(row.revenue ?? 0),
      cost: Number(row.cost ?? 0),
      margin: Number(row.margin ?? 0),
    }));
    const maxQty = list.reduce((max, row) => Math.max(max, row.qty), 0);
    const star = [...list].sort((a, b) => b.qty - a.qty)[0] ?? null;
    return list.map((row) => ({
      ...row,
      marginPct: row.revenue > 0 ? (row.margin / row.revenue) * 100 : 0,
      plan: buildProductPlan(row, { maxQty, star, currency, lang }),
    }));
  }, [demand.data, currency, lang]);

  const [openPlan, setOpenPlan] = useState<string | null>(null);

  if (!canView) return <NoPermission message={t("common.noAccess")} />;

  const top = rows.filter((r) => r.qty > 0).slice(0, 5);
  const slow = [...rows].sort((a, b) => a.qty - b.qty).slice(0, 5);

  const name = (row: { name: string; name_ar: string | null }) =>
    lang === "ar" ? row.name_ar || row.name : row.name;

  const tierVariant: Record<PlanTier, "default" | "secondary" | "outline" | "destructive"> = {
    star: "default",
    steady: "secondary",
    thin: "outline",
    slow: "outline",
    dead: "destructive",
  };

  const active = rows.find((r) => r.product_id === openPlan) ?? null;

  return (
    <div className="space-y-6">
      <PageHeader title={t("ana.title")} description={t("ana.subtitle")} />

      <div className="flex flex-wrap items-end gap-3">
        <div className="grid gap-1">
          <Label htmlFor="from">{t("rep.from")}</Label>
          <Input id="from" type="date" value={from} onChange={(e) => setFrom(e.target.value)} />
        </div>
        <div className="grid gap-1">
          <Label htmlFor="to">{t("rep.to")}</Label>
          <Input id="to" type="date" value={to} onChange={(e) => setTo(e.target.value)} />
        </div>
      </div>

      <div className="grid gap-4 md:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>{t("ana.top")}</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2 text-sm">
            {top.length === 0 && <p className="text-muted-foreground">{t("ana.empty")}</p>}
            {top.map((row) => (
              <div key={row.product_id} className="flex items-center justify-between gap-2">
                <span className="font-medium">{name(row)}</span>
                <span className="text-muted-foreground">
                  {row.qty} · {formatMoney(row.revenue, currency, lang)}
                </span>
              </div>
            ))}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>{t("ana.slow")}</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2 text-sm">
            {slow.map((row) => (
              <div key={row.product_id} className="flex items-center justify-between gap-2">
                <span className="font-medium">{name(row)}</span>
                <span className="text-muted-foreground">
                  {row.qty === 0 ? t("ana.never") : `${row.qty}`}
                </span>
              </div>
            ))}
          </CardContent>
        </Card>
      </div>

      {rows.length === 0 ? (
        <EmptyState message={t("ana.empty")} />
      ) : (
        <div className="overflow-x-auto rounded-xl border border-border bg-card">
          <Table className="min-w-[1000px] text-sm tabular-nums">
            <TableHeader className="bg-muted/60">
              <TableRow className="hover:bg-transparent">
                <TableHead className="text-start font-semibold">{t("ana.product")}</TableHead>
                <TableHead className="text-center font-semibold">{t("ana.status")}</TableHead>
                <TableHead className="text-end font-semibold">{t("ana.qty")}</TableHead>
                <TableHead className="text-end font-semibold">{t("ana.revenue")}</TableHead>
                <TableHead className="text-end font-semibold">{t("ana.cost")}</TableHead>
                <TableHead className="text-end font-semibold">{t("ana.margin")}</TableHead>
                <TableHead className="text-center font-semibold">{t("ana.marginPct")}</TableHead>
                <TableHead className="text-end font-semibold">{t("ana.orders")}</TableHead>
                <TableHead className="text-start font-semibold">{t("ana.lastSold")}</TableHead>
                <TableHead className="text-start font-semibold">{t("ana.plan")}</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row) => (
                <TableRow key={row.product_id} className="odd:bg-muted/20">
                  <TableCell className="text-start font-medium whitespace-nowrap">
                    {name(row)}
                  </TableCell>
                  <TableCell className="text-center">
                    <Badge variant={tierVariant[row.plan.tier]} className="whitespace-nowrap">
                      {tierLabel[row.plan.tier][lang === "ar" ? "ar" : "en"]}
                    </Badge>
                  </TableCell>
                  <TableCell className="text-end">{row.qty}</TableCell>
                  <TableCell className="text-end whitespace-nowrap">
                    {formatMoney(row.revenue, currency, lang)}
                  </TableCell>
                  <TableCell className="text-end whitespace-nowrap text-muted-foreground">
                    {formatMoney(row.cost, currency, lang)}
                  </TableCell>
                  <TableCell className="text-end whitespace-nowrap font-medium">
                    {formatMoney(row.margin, currency, lang)}
                  </TableCell>
                  <TableCell className="text-center">
                    <Badge variant={row.marginPct >= 40 ? "secondary" : "outline"}>
                      {row.marginPct.toFixed(0)}%
                    </Badge>
                  </TableCell>
                  <TableCell className="text-end">{row.orders_count}</TableCell>
                  <TableCell className="text-start text-xs whitespace-nowrap text-muted-foreground">
                    {row.last_sold_at ? formatDateTime(row.last_sold_at, lang) : "—"}
                  </TableCell>
                  <TableCell className="text-start">
                    <div className="flex items-center gap-2">
                      <span className="max-w-[260px] truncate text-xs">{row.plan.headline}</span>
                      <Button
                        size="sm"
                        variant="outline"
                        onClick={() => setOpenPlan(row.product_id)}
                      >
                        {t("ana.viewPlan")}
                      </Button>
                    </div>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}

      <Dialog open={!!active} onOpenChange={(open) => !open && setOpenPlan(null)}>
        <DialogContent className="max-w-xl">
          {active && (
            <>
              <DialogHeader>
                <DialogTitle>
                  {t("ana.planFor")} — {name(active)}
                </DialogTitle>
                <DialogDescription>{active.plan.headline}</DialogDescription>
              </DialogHeader>
              <div className="grid gap-3 text-sm">
                <div className="grid grid-cols-2 gap-2 rounded-lg border border-border p-3 tabular-nums sm:grid-cols-4">
                  <div>
                    <p className="text-xs text-muted-foreground">{t("ana.price")}</p>
                    <p className="font-medium">
                      {formatMoney(Number(active.base_price ?? 0), currency, lang)}
                    </p>
                  </div>
                  <div>
                    <p className="text-xs text-muted-foreground">{t("ana.unitCost")}</p>
                    <p className="font-medium">
                      {formatMoney(Number(active.unit_cost ?? 0), currency, lang)}
                    </p>
                  </div>
                  <div>
                    <p className="text-xs text-muted-foreground">{t("ana.qty")}</p>
                    <p className="font-medium">{active.qty}</p>
                  </div>
                  <div>
                    <p className="text-xs text-muted-foreground">{t("ana.marginPct")}</p>
                    <p className="font-medium">{active.marginPct.toFixed(0)}%</p>
                  </div>
                </div>
                <div>
                  <p className="mb-1 font-semibold">{t("ana.steps")}</p>
                  <ul className="space-y-2">
                    {active.plan.steps.map((step, i) => (
                      <li key={i} className="rounded-md bg-muted/40 p-2 leading-relaxed">
                        {step}
                      </li>
                    ))}
                  </ul>
                </div>
                <p className="rounded-md border border-primary/30 bg-primary/5 p-2 text-xs font-medium">
                  {active.plan.guard}
                </p>
              </div>
            </>
          )}
        </DialogContent>
      </Dialog>
    </div>
  );
}
