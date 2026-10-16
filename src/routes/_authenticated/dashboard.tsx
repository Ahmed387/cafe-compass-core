import { useQuery } from "@tanstack/react-query";
import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useEffect } from "react";
import { Boxes, Handshake, Receipt, ShoppingCart, Users, Wallet } from "lucide-react";

import { PageHeader } from "@/components/layout/AppShell";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { auditLabels } from "@/lib/audit-labels";
import { formatDateTime, formatMoney } from "@/lib/format";
import { addDays, businessDayStartIso, businessToday, monthToDate } from "@/core/finance/business-dates";
import { useFinancialEngine } from "@/core/hooks/useFinancialEngine";
import { useI18n } from "@/lib/i18n";
import { OwnerStatementPanel } from "@/modules/governance/OwnerStatementPanel";
import { LivePositionPanel } from "@/modules/finance/LivePositionPanel";
import { BarLowStockAlert, useBarLowStock } from "@/modules/supply/bar-low-stock";

export const Route = createFileRoute("/_authenticated/dashboard")({
  head: () => ({
    meta: [
      { title: "Dashboard — 20s Coffee" },
      { name: "description", content: "Financial command center: revenue, profit, expenses and live shift status." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
      { property: "og:title", content: "Dashboard — 20s Coffee" },
      { property: "og:description", content: "Foundation overview of your coffee shop system." },
    ],
  }),
  component: DashboardPage,
});

function DashboardPage() {
  const { t, lang } = useI18n();
  const { me, can, currentBranchId } = useAuth();
  const navigateTo = useNavigate();
  const cashierOnly = Boolean(
    me?.roleNames.includes("Cashier") &&
      !me.roleNames.some((r) => ["Super Admin", "Manager", "Partner"].includes(r)),
  );
  useEffect(() => {
    if (cashierOnly) navigateTo({ to: "/pos", search: { mode: undefined }, replace: true });
  }, [cashierOnly, navigateTo]);
  const barLow = useBarLowStock(currentBranchId);
  const labels = auditLabels(t);
  const personName = (
    profile: {
      display_name: string | null;
      first_name: string | null;
      last_name: string | null;
    } | null,
  ) =>
    profile
      ? profile.display_name ||
        [profile.first_name, profile.last_name].filter(Boolean).join(" ") ||
        t("audit.system")
      : t("audit.system");

  const { data } = useQuery({
    queryKey: ["dashboard-foundation", me?.profile.company_id],
    enabled: Boolean(me),
    queryFn: async () => {
      const [users, branches, partners, audit] = await Promise.all([
        supabase.from("user_profiles").select("id, is_active"),
        supabase.from("branches").select("id, is_active"),
        can("partners.view")
          ? supabase.from("partners").select("id, status")
          : Promise.resolve({ data: null }),
        can("audit.view")
          ? supabase
              .from("audit_logs")
              .select(
                "id, action, module, entity_type, entity_id, reason, created_at, user_id, user_profiles(display_name, first_name, last_name)",
              )
              .order("created_at", { ascending: false })
              .limit(8)
          : Promise.resolve({ data: null }),
      ]);
      return {
        users: users.data ?? [],
        branches: branches.data ?? [],
        partners: partners.data ?? null,
        audit: audit.data ?? null,
      };
    },
  });

  const engineLang = lang === "ar" ? "ar" : "en";
  const ar = engineLang === "ar";
  const currency = me?.company?.currency ?? "EGP";
  const money = (v: number) => formatMoney(v, currency, lang);
  const allowedMoney = can("reports.profit") || can("expenses.view");
  const mtd = monthToDate();

  const ops = useQuery({
    queryKey: ["dashboard-ops", currentBranchId, mtd.start],
    enabled: Boolean(currentBranchId) && Boolean(data),
    queryFn: async () => {
      // Last 7 business days from the server's sales definition (same numbers as the
      // profit report: after offers, discounts, cashback and refunds; Cairo days).
      const today = businessToday();
      const first = addDays(today, -6);
      const [shifts, week] = await Promise.all([
        supabase.from("shifts").select("id, status, opened_at").eq("branch_id", currentBranchId!).gte("opened_at", businessDayStartIso(mtd.start)).limit(500),
        supabase.rpc("sales_period_summary", { _from: first, _to: today, _branch_id: currentBranchId! }),
      ]);
      const byDay = new Map(
        ((week.data as { by_day?: Array<{ day: string; revenue: number; count: number }> } | null)?.by_day ?? []).map(
          (d) => [d.day, d] as const,
        ),
      );
      const days: Array<{ day: string; sales: number; orders: number }> = [];
      for (let i = 0; i < 7; i++) {
        const iso = addDays(first, i);
        const row = byDay.get(iso);
        days.push({
          day: new Date(`${iso}T12:00:00Z`).toLocaleDateString(ar ? "ar-EG" : "en-GB", { weekday: "short", timeZone: "UTC" }),
          sales: Number(row?.revenue ?? 0),
          orders: Number(row?.count ?? 0),
        });
      }
      const rows = shifts.data ?? [];
      return { ids: rows.map((r) => r.id), open: rows.find((r) => r.status === "open") ?? null, days };
    },
  });
  const engine = useFinancialEngine({ branchId: currentBranchId, shiftIds: ops.data?.ids ?? [], enabled: allowedMoney });
  const t0 = engine.data?.totals;
  const maxDay = Math.max(1, ...(ops.data?.days ?? []).map((d) => d.sales));
  const weekTotal = (ops.data?.days ?? []).reduce((s, d) => s + d.sales, 0);
  const weekOrders = (ops.data?.days ?? []).reduce((s, d) => s + d.orders, 0);

  const actions = [
    { to: "/pos", label: ar ? "نقطة البيع" : "Point of sale", icon: ShoppingCart, perm: "pos.view" },
    { to: "/orders", label: ar ? "الطلبات والورديات" : "Orders & shifts", icon: Receipt, perm: "pos.view" },
    { to: "/inventory", label: ar ? "المخزون" : "Inventory", icon: Boxes, perm: "inventory.view" },
    { to: "/expenses", label: ar ? "المصروفات" : "Expenses", icon: Wallet, perm: "expenses.view" },
    { to: "/partners", label: ar ? "الشركاء" : "Partners", icon: Handshake, perm: "partners.view" },
    { to: "/hr", label: ar ? "الموارد البشرية" : "HR & payroll", icon: Users, perm: "payroll.view" },
  ].filter((a) => can(a.perm));

  return (
    <div className="space-y-6">
      <PageHeader
        title={t("dash.title")}
        description={me?.company?.name ?? undefined}
        action={
          <Badge variant="secondary" className="h-7">
            {t("dash.status")}: {ar ? "يعمل" : "Operational"}
          </Badge>
        }
      />

      {can("inventory.view") && <BarLowStockAlert items={barLow.items} showLink />}

      {allowedMoney && <LivePositionPanel />}

      <div className="grid gap-4 lg:grid-cols-[minmax(0,2fr)_minmax(0,1fr)]">
        <Card className="rounded-2xl shadow-sm">
          <CardHeader className="pb-2">
            <div className="grid grid-cols-[minmax(0,1fr)_auto] items-end gap-3">
              <div className="min-w-0">
                <CardTitle className="text-base">{ar ? "مبيعات آخر 7 أيام" : "Sales — last 7 days"}</CardTitle>
                <p className="text-xs text-muted-foreground">{weekOrders} {ar ? "طلب" : "orders"}</p>
              </div>
              <p className="shrink-0 font-display text-lg font-bold tabular-nums">{money(weekTotal)}</p>
            </div>
          </CardHeader>
          <CardContent>
            <div className="flex h-44 items-end gap-2" role="img" aria-label={ar ? "رسم المبيعات اليومية" : "Daily sales chart"}>
              {(ops.data?.days ?? []).map((d, i) => (
                <div key={i} className="flex min-w-0 flex-1 flex-col items-center gap-1.5" title={`${d.day}: ${money(d.sales)} · ${d.orders}`}>
                  <div className="flex w-full flex-1 items-end">
                    <div className="w-full rounded-t-lg opacity-80 transition-all hover:opacity-100" style={{ background: "var(--primary)", height: `${Math.max(4, Math.round((d.sales / maxDay) * 140))}px` }} />
                  </div>
                  <span className="truncate text-[11px] text-muted-foreground">{d.day}</span>
                </div>
              ))}
            </div>
          </CardContent>
        </Card>

        <Card className="rounded-2xl shadow-sm">
          <CardHeader className="pb-2"><CardTitle className="text-base">{ar ? "إجراءات سريعة" : "Quick actions"}</CardTitle></CardHeader>
          <CardContent className="grid grid-cols-2 gap-2">
            {actions.map((a) => (
              <Link key={a.to} to={a.to} className="flex min-h-16 flex-col items-start justify-center gap-1.5 rounded-xl border border-border bg-background/60 p-3 text-sm font-medium transition hover:border-primary/40 hover:bg-primary/5">
                <a.icon className="size-4 text-primary" />
                <span className="truncate">{a.label}</span>
              </Link>
            ))}
          </CardContent>
        </Card>
      </div>

      <div className="grid gap-4 lg:grid-cols-2">
        <Card className="rounded-2xl shadow-sm">
          <CardHeader className="pb-2"><CardTitle className="text-base">{ar ? "مؤشرات مالية سريعة" : "Financial breakdown"}</CardTitle></CardHeader>
          <CardContent className="space-y-0 text-sm">
            {[
              [ar ? "إجمالي الإيراد قبل الخصومات" : "Gross revenue", t0?.gross ?? 0],
              [ar ? "تكلفة البضاعة" : "Cost of goods", -(t0?.cogs ?? 0)],
              [ar ? "المرتجعات" : "Refunds", -(t0?.refunds ?? 0)],
              [ar ? "فارق الدرج" : "Drawer variance", t0?.variance ?? 0],
              [ar ? "المستخدمون النشطون" : "Active users", null],
            ].map(([label, v]) => (
              <div key={String(label)} className="flex items-center justify-between gap-3 border-b border-border/70 py-2.5 last:border-0">
                <span className="text-muted-foreground">{label}</span>
                <span className={`font-semibold tabular-nums ${typeof v === "number" && v < 0 ? "text-destructive" : ""}`}>
                  {v === null ? (data ? `${data.users.filter((u) => u.is_active).length} / ${data.users.length}` : "—") : money(Number(v))}
                </span>
              </div>
            ))}
          </CardContent>
        </Card>

        {can("audit.view") && (
          <Card className="rounded-2xl shadow-sm">
            <CardHeader className="pb-2">
              <CardTitle className="text-base">{t("dash.recent")}</CardTitle>
              <p className="text-xs text-muted-foreground">{t("dash.recentHint")}</p>
            </CardHeader>
            <CardContent className="space-y-0 text-sm">
              {data?.audit && data.audit.length > 0 ? (
                data.audit.map((entry) => (
                  <div key={entry.id} className="grid grid-cols-[minmax(0,1fr)_auto] items-start gap-3 border-b border-border/70 py-2 last:border-0">
                    <div className="min-w-0">
                      <div className="flex min-w-0 flex-wrap items-center gap-2">
                        <Badge variant={labels.tone(entry.action)} className="whitespace-nowrap">{labels.action(entry.action)}</Badge>
                        <span className="truncate font-medium">{personName(entry.user_profiles)}</span>
                      </div>
                      <p className="mt-1 truncate text-xs text-muted-foreground">
                        {labels.module(entry.module)}
                        {entry.entity_type ? ` · ${labels.entity(entry.entity_type, entry.entity_id)}` : ""}
                        {entry.reason ? ` · ${entry.reason}` : ""}
                      </p>
                    </div>
                    <span className="whitespace-nowrap text-xs tabular-nums text-muted-foreground">{formatDateTime(entry.created_at, lang)}</span>
                  </div>
                ))
              ) : (
                <p className="text-muted-foreground">{t("audit.empty")}</p>
              )}
            </CardContent>
          </Card>
        )}
      </div>

      <OwnerStatementPanel />
    </div>
  );
}
