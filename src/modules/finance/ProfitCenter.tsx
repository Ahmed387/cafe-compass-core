import { useMutation, useQueryClient } from "@tanstack/react-query";
import {
  AlertTriangle, BarChart3, BriefcaseBusiness, CircleGauge, FileSpreadsheet, Landmark, LayoutGrid, PiggyBank, ShieldCheck, Sparkles, Undo2, Warehouse, Wrench,
} from "lucide-react";
import { useState } from "react";
import { Bar, BarChart, CartesianGrid, Cell, ReferenceLine, XAxis, YAxis } from "recharts";
import { toast } from "sonner";

import { DateRangeFilter, RANGE_PRESETS, type DateRange } from "@/components/shared/DateRangeFilter";
import { InfoTip } from "@/components/shared/InfoTip";
import { KpiCard, KpiGrid } from "@/components/shared/KpiCard";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { ChartContainer, ChartTooltip } from "@/components/ui/chart";
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Progress } from "@/components/ui/progress";
import { Skeleton } from "@/components/ui/skeleton";
import { businessToday, rangeLabel } from "@/core/finance/business-dates";
import { nextPayoutRange, type MonthPayout } from "@/core/finance/payout-months";
import { monthLabel } from "@/core/finance/salary-month";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { formatDate, formatMoney, formatPercent, friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { cn } from "@/lib/utils";
import {
  payoutPlan, usePayoutHistory, useRangePnl, useSustainability, type PayoutMonthFigures, type PayoutRecord, type RangePnl,
} from "@/modules/finance/finance-queries";
import { PayoutWizard } from "@/modules/finance/PayoutWizard";
import { SectionTitle } from "@/components/shared/SectionTitle";

type Lang = "ar" | "en";

/** P&L for any date range, self-sustainability, on-demand payouts and the development fund. */
export function ProfitCenter() {
  const { lang } = useI18n();
  const ar = lang === "ar";
  const { can, me } = useAuth();
  const currency = me?.company?.currency ?? "EGP";
  const money = (v: number | null | undefined) => formatMoney(Number(v ?? 0), currency, lang);
  const isSuperAdmin = Boolean(me?.isRoot || me?.roleNames.includes("Super Admin"));
  const canPayouts = isSuperAdmin || can("partners.manage_profit_distribution");

  const [range, setRange] = useState<DateRange>(() => {
    const m = RANGE_PRESETS.thisMonth();
    return { from: m.from, to: RANGE_PRESETS.today().to };
  });
  const [wizardOpen, setWizardOpen] = useState(false);
  const [wizardRange, setWizardRange] = useState<{ from: string; to: string } | null>(null);

  const pnl = useRangePnl(range.from, range.to);
  const sustainability = useSustainability();
  const history = usePayoutHistory();
  const p = pnl.data;
  const plan = payoutPlan(history.data);
  const openWizard = (r: { from: string; to: string } | null) => {
    setWizardRange(r);
    setWizardOpen(true);
  };

  return (
    <div dir={ar ? "rtl" : "ltr"} className="space-y-5">
      <section className="space-y-2">
        <div className="flex items-center gap-1.5 text-sm font-semibold">
          {ar ? "الفترة اللي عايز تشوفها" : "Range to review"}
          <InfoTip title={ar ? "ليه بتختار تواريخ؟" : "Why pick dates?"}>
            {ar
              ? "مفيش فترات محاسبية بتتقفل خلاص. اختار أي من يوم لحد يوم، والأرقام بتتحسب في ساعتها بتوقيت القاهرة من نفس المعادلة اللي بتستخدمها الورديات والتوزيعات."
              : "No more period closing. Pick any range; figures are computed live in Cairo time with the same formula used by shifts and payouts."}
          </InfoTip>
        </div>
        <DateRangeFilter value={range} onChange={setRange} />
      </section>

      {p && p.expenses_pending_count > 0 && (
        <div className="flex items-start gap-2 rounded-xl border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900 dark:border-amber-500/40 dark:bg-amber-500/10 dark:text-amber-200">
          <AlertTriangle className="mt-0.5 size-4 shrink-0" />
          <span>
            {ar
              ? `فيه ${p.expenses_pending_count} مصروف لسه مستني الموافقة (${money(p.expenses_pending)}) ومش داخل في الحساب. وافق عليهم من صفحة المصروفات عشان الربح يبقى مظبوط.`
              : `${p.expenses_pending_count} expenses (${money(p.expenses_pending)}) are awaiting approval and are not counted yet.`}
          </span>
        </div>
      )}

      {p && Number(p.payroll_total) === 0 && Number(p.revenue) > 0 && (
        <div className="flex items-start gap-2 rounded-xl border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900 dark:border-amber-500/40 dark:bg-amber-500/10 dark:text-amber-200">
          <AlertTriangle className="mt-0.5 size-4 shrink-0" />
          <span>
            {ar
              ? "مفيش رواتب متسجلة في الفترة دي، فصافي الربح هنا أعلى من الحقيقي بقيمة الرواتب. سجّل رواتب الشهر من صفحة الموظفين (أو اختار إنها تتحسب على الشهر ده) والرقم هيتظبط لوحده. التوزيع مقفول لحد ما تتسجل."
              : "No salaries are recorded in this range, so net profit here is higher than the real figure by the payroll. Record the month's salaries on the HR page and it corrects itself. Payouts stay blocked until then."}
          </span>
        </div>
      )}

      {pnl.isLoading || !p ? (
        <Skeleton className="h-40 w-full rounded-2xl" />
      ) : (
        <>
          <NetHero pnl={p} money={money} lang={lang} />
          <KpiGrid cols={4}>
            <KpiCard label={ar ? "إجمالي المبيعات" : "Gross sales"} value={money(p.gross_sales)} hint={`${p.orders_count} ${ar ? "طلب" : "orders"}`}
              formula={ar ? "سعر كل الأصناف المباعة قبل أي عرض أو خصم، من غير ضريبة." : "Full price of every item sold, before offers or discounts, excluding VAT."} />
            <KpiCard label={ar ? "صافي الإيراد" : "Net revenue"} value={money(p.revenue)} tone="brand"
              formula={ar ? "المبيعات − العروض − الخصومات − الكاش باك المستخدم − المرتجعات (من غير ضريبة)." : "Sales − offers − discounts − cashback used − refunds (ex-VAT)."} />
            <KpiCard label={ar ? "مجمل الربح" : "Gross profit"} value={money(p.gross_profit)} tone={p.gross_profit < 0 ? "bad" : "good"}
              formula={ar ? "صافي الإيراد − تكلفة الخامات − الهالك − عجز الجرد." : "Net revenue − COGS − waste − stocktake shortages."} />
            <KpiCard label={ar ? "مصاريف التشغيل" : "Operating costs"} value={money(p.operating_total)} tone="warn"
              formula={ar ? "المصروفات المعتمدة + الرواتب + عجز الدرج − زيادة الدرج." : "Approved expenses + payroll + drawer shortages − drawer overages."} />
          </KpiGrid>
          <Departments pnl={p} money={money} lang={lang} />
          <Statement pnl={p} money={money} lang={lang} />
        </>
      )}

      <SustainabilityCard data={sustainability.data} loading={sustainability.isLoading} money={money} lang={lang} />

      <section className="card-surface rounded-2xl border border-border bg-card p-4 shadow-sm sm:p-5">
        <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
          <div className="flex items-center gap-2">
            <SectionTitle icon={PiggyBank}>{ar ? "توزيع الأرباح" : "Profit payouts"}</SectionTitle>
            <InfoTip title={ar ? "إزاي التوزيع شغال؟" : "How payouts work"}>
              {ar
                ? "السوبر أدمن بيختار من يوم لحد يوم، والنظام بيحسب الربح ويخصم رواتب الإدارة والاحتياطي وصندوق التطوير، وبعدين يقسم على الشركاء ويخصم فواتيرهم على الحساب. نفس اليوم مينفعش يتوزع مرتين."
                : "The Super Admin picks a date range; profit is calculated, management pay, reserve and the fund are set aside, then it's split across partners with their tabs deducted. A day can't be paid twice."}
            </InfoTip>
          </div>
          {canPayouts && (
            <Button disabled={!isSuperAdmin || history.isLoading || !plan.next} onClick={() => openWizard(plan.next)}>
              <Sparkles className="me-1 size-4" />
              {ar ? "وزّع أرباح" : "Run a payout"}
            </Button>
          )}
        </div>
        {canPayouts && !isSuperAdmin && (
          <p className="mb-3 text-xs text-amber-600">{ar ? "التوزيع النهائي للسوبر أدمن بس." : "Only the Super Admin can run a payout."}</p>
        )}
        <PayoutMonths
          months={plan.months}
          figures={history.data?.months ?? []}
          payouts={history.data?.payouts ?? []}
          loading={history.isLoading}
          canPay={isSuperAdmin}
          onPay={(r) => openWizard(r)}
          money={money}
          lang={lang}
        />
        <PayoutHistory rows={history.data?.payouts ?? []} loading={history.isLoading} isSuperAdmin={isSuperAdmin} money={money} lang={lang} />
      </section>

      <DevelopmentFund balance={history.data?.development_fund_balance ?? 0} isSuperAdmin={isSuperAdmin} money={money} lang={lang} />

      {isSuperAdmin && (
        <PayoutWizard
          open={wizardOpen}
          onOpenChange={setWizardOpen}
          defaultFrom={(wizardRange ?? plan.next)?.from ?? businessToday()}
          defaultTo={(wizardRange ?? plan.next)?.to}
          currency={currency}
          lang={lang}
        />
      )}
    </div>
  );
}

function NetHero({ pnl, money, lang }: { pnl: RangePnl; money: (v: number) => string; lang: Lang }) {
  const ar = lang === "ar";
  const loss = pnl.net_profit < 0;
  return (
    <section className={cn(
      "rounded-2xl border p-5 shadow-sm sm:p-6",
      loss ? "border-destructive/30 bg-destructive/5" : "border-success/30 bg-success/5",
    )}>
      <div className="flex items-center gap-1.5 text-sm font-semibold text-muted-foreground">
        {loss ? (ar ? "صافي الخسارة" : "Net loss") : ar ? "صافي الربح" : "Net profit"}
        <InfoTip>
          {ar
            ? "ده اللي فضل فعلاً بعد كل حاجة: الخامات، الهالك، المصروفات، الرواتب وفروق الدرج. هو نفس الرقم اللي التوزيع بيبدأ منه."
            : "What is truly left after COGS, waste, expenses, payroll and drawer differences — the same figure payouts start from."}
        </InfoTip>
      </div>
      <p className={cn("mt-2 text-4xl font-black tabular-nums sm:text-5xl", loss ? "text-destructive" : "text-success")}>
        {money(Math.abs(pnl.net_profit))}
      </p>
      <p className="mt-2 text-xs text-muted-foreground">
        {rangeLabel(pnl.from, pnl.to, lang)} · {pnl.days} {ar ? "يوم" : "days"}
        {pnl.partner_tab_open > 0 && ` · ${ar ? "على حساب الشركاء لسه" : "Open partner tabs"}: ${money(pnl.partner_tab_open)}`}
      </p>
    </section>
  );
}

const DEPARTMENTS = {
  sales: {
    icon: BarChart3,
    ar: "البار والمبيعات", en: "Bar & sales",
    whyAr: "بيوريك البار كسب كام بعد تكلفة الخامات بس — يعني جودة التسعير والوصفات.",
    whyEn: "What the bar earned after ingredient cost — pricing and recipe quality.",
  },
  warehouse: {
    icon: Warehouse,
    ar: "المخزن الرئيسي", en: "Main warehouse",
    whyAr: "خساير المخزن: الهالك وعجز الجرد. تكلفة الخامات المباعة متحسبة على البار مش هنا، فمفيش حاجة بتتحسب مرتين.",
    whyEn: "Stock losses: waste and stocktake shortages. Sold-ingredient cost sits with the bar, never counted twice.",
  },
  operations: {
    icon: BriefcaseBusiness,
    ar: "التشغيل والرواتب", en: "Operations & payroll",
    whyAr: "المصروفات المعتمدة والرواتب وفروق الدرج — تكلفة إن المكان يفتح كل يوم.",
    whyEn: "Approved expenses, payroll and drawer differences — the cost of opening every day.",
  },
} as const;

function Departments({ pnl, money, lang }: { pnl: RangePnl; money: (v: number) => string; lang: Lang }) {
  const ar = lang === "ar";
  return (
    <section className="space-y-3">
      <div className="flex items-center gap-1.5">
        <SectionTitle icon={LayoutGrid}>{ar ? "القطاعات" : "Departments"}</SectionTitle>
        <InfoTip>{ar ? "مجموع نتيجة القطاعات التلاتة = صافي الربح بالظبط." : "The three results add up exactly to net profit."}</InfoTip>
      </div>
      <div className="grid gap-3 md:grid-cols-3">
        {pnl.departments.map((d) => {
          const meta = DEPARTMENTS[d.key];
          const Icon = meta.icon;
          return (
            <article key={d.key} className="card-surface rounded-2xl border border-border bg-card p-4 shadow-sm">
              <div className="mb-3 flex items-center justify-between">
                <span className="grid size-9 place-items-center rounded-xl bg-muted text-foreground"><Icon className="size-4" /></span>
                <InfoTip title={ar ? "ليه القسم ده؟" : "Why this section?"}>{ar ? meta.whyAr : meta.whyEn}</InfoTip>
              </div>
              <h3 className="font-semibold">{ar ? meta.ar : meta.en}</h3>
              <dl className="mt-3 space-y-1.5 text-sm">
                <div className="flex justify-between text-muted-foreground"><dt>{ar ? "دخل" : "Income"}</dt><dd className="tabular-nums text-foreground">{money(d.income)}</dd></div>
                <div className="flex justify-between text-muted-foreground"><dt>{ar ? "تكلفة" : "Cost"}</dt><dd className="tabular-nums text-foreground">{money(d.cost)}</dd></div>
                <div className="flex justify-between border-t pt-1.5 font-semibold">
                  <dt>{ar ? "النتيجة" : "Result"}</dt>
                  <dd className={cn("tabular-nums", d.result < 0 ? "text-destructive" : "text-success")}>{money(d.result)}</dd>
                </div>
              </dl>
            </article>
          );
        })}
      </div>
    </section>
  );
}

function Statement({ pnl, money, lang }: { pnl: RangePnl; money: (v: number) => string; lang: Lang }) {
  const ar = lang === "ar";
  const rows: Array<[string, number, "plus" | "minus" | "total"]> = [
    [ar ? "إجمالي المبيعات" : "Gross sales", pnl.gross_sales, "plus"],
    [ar ? "العروض" : "Offers", pnl.promo_discount, "minus"],
    [ar ? "الخصومات اليدوية" : "Manual discounts", pnl.manual_discounts, "minus"],
    [ar ? "الكاش باك المستخدم" : "Cashback used", pnl.points_redeemed, "minus"],
    [ar ? "المرتجعات" : "Refunds", pnl.refunds_total, "minus"],
    [ar ? "صافي الإيراد" : "Net revenue", pnl.revenue, "total"],
    [ar ? "تكلفة الخامات المباعة" : "COGS (ingredients sold)", pnl.cogs, "minus"],
    [ar ? "هالك المخزن — على المكان" : "Stock waste — borne by the business", pnl.waste_business ?? pnl.waste_cost, "minus"],
    [ar ? "هالك متحمّل على الموظفين (بيرجع من المرتبات)" : "Waste charged to staff (recovered via payroll)", pnl.waste_charged_staff ?? 0, "minus"],
    [ar ? "عجز الجرد" : "Stocktake shortages", pnl.stocktake_shortage, "minus"],
    [ar ? "مجمل الربح" : "Gross profit", pnl.gross_profit, "total"],
    [ar ? "المصروفات المعتمدة" : "Approved expenses", pnl.expenses_total, "minus"],
    [ar ? "الرواتب (شامل رواتب الإدارة)" : "Payroll (incl. management pay)", pnl.payroll_total, "minus"],
    [ar ? "عجز الدرج" : "Drawer shortages", pnl.cash_shortage, "minus"],
    [ar ? "زيادة الدرج" : "Drawer overages", pnl.cash_over, "plus"],
  ];
  return (
    <section className="card-surface rounded-2xl border border-border bg-card p-4 shadow-sm sm:p-5">
      <div className="mb-3 flex items-center gap-2">
        <Landmark className="size-5 text-primary" />
        <SectionTitle icon={FileSpreadsheet}>{ar ? "قائمة الدخل" : "Income statement"}</SectionTitle>
        <InfoTip>{ar ? "رحلة الفلوس من أول البيع لحد صافي النتيجة، سطر بسطر." : "The full path from sales to the final result, line by line."}</InfoTip>
      </div>
      <div className="divide-y divide-border text-sm">
        {rows.map(([label, value, kind]) => (
          <div key={label} className={cn("flex justify-between gap-3 py-2", kind === "total" && "font-semibold")}>
            <span className={kind === "total" ? "" : "text-muted-foreground"}>{label}</span>
            <span className="tabular-nums">{kind === "minus" && value ? "− " : ""}{money(value)}</span>
          </div>
        ))}
        <div className="flex justify-between gap-3 py-3 text-base font-black">
          <span>{pnl.net_profit < 0 ? (ar ? "صافي الخسارة" : "Net loss") : ar ? "صافي الربح" : "Net profit"}</span>
          <span className={cn("tabular-nums", pnl.net_profit < 0 ? "text-destructive" : "text-success")}>{money(pnl.net_profit)}</span>
        </div>
      </div>
    </section>
  );
}

function SustainabilityCard({
  data, loading, money, lang,
}: {
  data: ReturnType<typeof useSustainability>["data"];
  loading: boolean;
  money: (v: number | null | undefined) => string;
  lang: Lang;
}) {
  const ar = lang === "ar";
  if (loading) return <Skeleton className="h-56 w-full rounded-2xl" />;
  if (!data) return null;
  const months = [...data.history].reverse();
  const headline = data.complete_months === 0
    ? ar ? "محتاجين شهر كامل على الأقل" : "Needs at least one full month"
    : data.reached
      ? ar ? "المكان صارف على نفسه" : "Self-sustaining"
      : ar ? `فاضل ${data.months_remaining} شهر رابح` : `${data.months_remaining} more profitable month(s) needed`;

  return (
    <section className="card-surface rounded-2xl border border-border bg-card p-4 shadow-sm sm:p-5">
      <div className="grid gap-5 lg:grid-cols-[.8fr_1.2fr] lg:items-center">
        <div>
          <div className="flex items-center gap-2">
            <SectionTitle icon={CircleGauge}>{ar ? "الاستقلال المالي والمدى" : "Self-sustainability & runway"}</SectionTitle>
            <InfoTip title={ar ? "ليه الحاسبة دي هنا؟" : "Why is this here?"}>
              {ar
                ? "بتقرا آخر شهور كاملة وتقولك المكان بيصرف على نفسه ولا لأ. ده للمعلومة بس: توزيع الأرباح مش مستنيه، السوبر أدمن يقدر يوزع أي فترة يختارها."
                : "Reads the last complete months. For information only: payouts don't wait for it, the super admin can pay out any period."}
            </InfoTip>
          </div>
          <p className="mt-3 text-2xl font-black">{headline}</p>
          <div className="mt-3">
            <div className="mb-1 flex justify-between text-xs text-muted-foreground">
              <span>{ar ? "شهور رابحة ورا بعض" : "Profitable months in a row"}</span>
              <span className="tabular-nums">{Math.min(data.consecutive_profitable_months, 3)} / 3</span>
            </div>
            <Progress value={Math.min(data.consecutive_profitable_months / 3, 1) * 100} />
          </div>
          <dl className="mt-4 grid grid-cols-2 gap-3 text-sm">
            <div className="rounded-xl bg-muted/60 p-3">
              <dt className="text-xs text-muted-foreground">{ar ? "متوسط صافي الشهر" : "Avg. monthly net"}</dt>
              <dd className={cn("font-bold tabular-nums", (data.average_net_profit ?? 0) < 0 && "text-destructive")}>
                {data.average_net_profit === null ? "—" : money(data.average_net_profit)}
              </dd>
            </div>
            <div className="rounded-xl bg-muted/60 p-3">
              <dt className="flex items-center gap-1 text-xs text-muted-foreground">
                {ar ? "الخزنة تكفي" : "Runway"}
                <InfoTip>{ar ? "رصيد الخزنة ÷ متوسط الخسارة الشهرية. بيظهر بس لو المتوسط خسارة." : "Treasury balance ÷ average monthly loss. Shown only when averaging a loss."}</InfoTip>
              </dt>
              <dd className="font-bold tabular-nums">
                {data.runway_months === null ? (ar ? "مش محتاج" : "Not needed") : `${data.runway_months} ${ar ? "شهر" : "months"}`}
              </dd>
            </div>
          </dl>
        </div>
        <div>
          <ChartContainer
            config={{ net_profit: { label: ar ? "صافي الشهر" : "Monthly net" } }}
            className="h-56 w-full"
            aria-label={ar ? "صافي الربح شهر بشهر" : "Net profit by month"}
          >
            <BarChart data={months} margin={{ top: 8, right: 8, bottom: 0, left: 8 }} barCategoryGap="30%">
              <CartesianGrid vertical={false} strokeOpacity={0.4} />
              <XAxis dataKey="month" tickLine={false} axisLine={false} tickFormatter={(v: string) => v.slice(2).replace("-", "/")} />
              <YAxis hide />
              <ReferenceLine y={0} stroke="var(--border)" />
              <ChartTooltip
                cursor={{ fillOpacity: 0.08 }}
                content={({ active, payload }) => {
                  const row = active && payload?.[0]?.payload as (typeof months)[number] | undefined;
                  if (!row) return null;
                  return (
                    <div className="rounded-lg border bg-background px-3 py-2 text-xs shadow-md">
                      <p className="font-semibold">{row.month}{!row.complete && (ar ? " (لحد النهارده)" : " (to date)")}</p>
                      <p>{ar ? "الإيراد" : "Revenue"}: <span className="tabular-nums">{money(row.revenue)}</span></p>
                      <p>{row.net_profit < 0 ? (ar ? "خسارة" : "Loss") : ar ? "ربح" : "Profit"}: <span className="tabular-nums">{money(row.net_profit)}</span></p>
                    </div>
                  );
                }}
              />
              <Bar dataKey="net_profit" maxBarSize={28} radius={[4, 4, 4, 4]}>
                {months.map((m) => (
                  <Cell key={m.month} fill={m.net_profit < 0 ? "var(--destructive)" : "var(--success)"} fillOpacity={m.complete ? 1 : 0.45} />
                ))}
              </Bar>
            </BarChart>
          </ChartContainer>
          <p className="mt-1 text-center text-xs text-muted-foreground">
            {ar ? "أخضر = ربح، أحمر = خسارة، الباهت = الشهر الحالي لسه ماخلصش" : "Green = profit, red = loss, faded = current month to date"}
          </p>
        </div>
      </div>
    </section>
  );
}

function PayoutMonths({
  months, figures, payouts, loading, canPay, onPay, money, lang,
}: {
  months: MonthPayout[];
  figures: PayoutMonthFigures[];
  payouts: PayoutRecord[];
  loading: boolean;
  canPay: boolean;
  onPay: (range: { from: string; to: string }) => void;
  money: (v: number | null | undefined) => string;
  lang: Lang;
}) {
  const ar = lang === "ar";
  if (loading) return <Skeleton className="mb-4 h-20 w-full" />;
  if (!months.length) return null;
  const active = payouts.filter((x) => x.status === "active" && x.from && x.to);
  const label = (m: string) => monthLabel(m, lang);
  return (
    <div className="mb-4">
      <div className="mb-2 flex items-center gap-1.5">
        <p className="text-sm font-semibold">{ar ? "الشهور والتوزيع" : "Months and payouts"}</p>
        <InfoTip>
          {ar
            ? "كل شهر من أول يوم شغل: اتوزع ولا لأ. تقدر توزع أي شهر لوحده، وزرار «وزّع أرباح» بيبدأ دايماً من أول شهر لسه متوزعش."
            : "Every month since the first business day, paid out or not. Any month can be paid on its own; «Run a payout» always starts at the earliest unpaid month."}
        </InfoTip>
      </div>
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {months.map((m) => {
          const fig = figures.find((f) => f.month === m.month);
          const paidBy = active.filter((x) => x.from! <= m.end && x.to! >= m.start);
          const tone =
            m.status === "paid"
              ? "border-success/40 bg-success/5"
              : m.status === "partial"
                ? "border-amber-400/60 bg-amber-500/5"
                : "border-border bg-card";
          return (
            <div key={m.month} className={cn("rounded-xl border p-3", tone)}>
              <div className="flex items-center justify-between gap-2">
                <p className="font-semibold">{label(m.month)}</p>
                <Badge variant={m.status === "paid" ? "secondary" : "outline"}>
                  {m.status === "paid"
                    ? ar ? "اتوزع" : "Paid out"
                    : m.status === "partial"
                      ? ar ? `اتوزع ${m.paidDays} من ${m.days} يوم` : `${m.paidDays}/${m.days} days paid`
                      : ar ? "متوزعش" : "Not paid out"}
                </Badge>
              </div>
              <p className="mt-1 text-xs text-muted-foreground">
                {m.start} → {m.end}
                {m.current && (ar ? " (الشهر ماخلصش)" : " (month running)")}
              </p>
              <p className={cn("mt-2 font-display text-lg font-bold tabular-nums", Number(fig?.net_profit ?? 0) < 0 && "text-destructive")}>
                {fig ? money(fig.net_profit) : "—"}
              </p>
              <p className="text-[11px] text-muted-foreground">
                {ar ? "صافي ربح الشهر" : "Month net profit"}
                {fig && Number(fig.payroll) === 0 && Number(fig.revenue) > 0 && (ar ? " · من غير رواتب" : " · no salaries recorded")}
              </p>
              {paidBy.length > 0 && (
                <p className="mt-1 text-[11px] text-muted-foreground">
                  {ar ? "اتوزع يوم" : "Paid on"}{" "}
                  {paidBy.map((x) => (x.distributed_at ?? "").slice(0, 10)).join("، ")}
                  {" · "}
                  {ar ? "للشركاء" : "to partners"} {money(paidBy.reduce((s, x) => s + Number(x.partner_pool ?? 0), 0))}
                </p>
              )}
              {canPay && m.firstUnpaid && (
                <Button
                  size="sm"
                  variant="outline"
                  className="mt-2 w-full"
                  onClick={() => {
                    const r = nextPayoutRange([m], businessToday(), payouts);
                    if (r) onPay(r);
                  }}
                >
                  {ar ? `وزّع ${label(m.month)}` : `Pay out ${label(m.month)}`}
                </Button>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}

function PayoutHistory({
  rows, loading, isSuperAdmin, money, lang,
}: {
  rows: PayoutRecord[];
  loading: boolean;
  isSuperAdmin: boolean;
  money: (v: number | null | undefined) => string;
  lang: Lang;
}) {
  const ar = lang === "ar";
  const qc = useQueryClient();
  const reverse = useMutation({
    mutationFn: async (id: string) => {
      const reason = window.prompt(ar ? "سبب عكس التوزيع (إلزامي):" : "Reason for reversing this payout:");
      if (!reason || reason.trim().length < 5) throw new Error(ar ? "لازم سبب واضح" : "A clear reason is required");
      const { error } = await supabase.rpc("reverse_payout", { _distribution_id: id, _reason: reason.trim() });
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success(ar ? "اتعكس التوزيع ورجعت فواتير الحساب والصندوق." : "Payout reversed.");
      for (const key of ["payout-history", "partners", "partner-dividends", "partner-statement"]) qc.invalidateQueries({ queryKey: [key] });
    },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  if (loading) return <Skeleton className="h-24 w-full" />;
  if (!rows.length) {
    return <p className="rounded-xl border border-dashed py-8 text-center text-sm text-muted-foreground">{ar ? "لسه مفيش توزيعات." : "No payouts yet."}</p>;
  }
  return (
    <div className="space-y-3">
      {rows.map((d) => (
        <article key={d.id} className={cn("overflow-hidden rounded-xl border", d.status !== "active" && "opacity-60")}>
          <header className="flex flex-wrap items-center gap-x-3 gap-y-1 bg-muted/50 px-4 py-2.5 text-sm">
            <strong>{d.from && d.to ? rangeLabel(d.from, d.to, lang) : formatDate(d.distributed_at, lang)}</strong>
            <Badge variant={d.status === "active" ? "secondary" : "outline"}>
              {d.status === "active" ? (ar ? "ساري" : "Active") : ar ? "معكوس" : "Reversed"}
            </Badge>
            <span className="text-muted-foreground">{ar ? "للشركاء" : "To partners"}: <b className="tabular-nums text-foreground">{money(d.partner_pool)}</b></span>
            {d.development_fund > 0 && (
              <span className="text-muted-foreground"><Wrench className="me-1 inline size-3.5" />{money(d.development_fund)}</span>
            )}
            {d.drift !== null && Math.abs(d.drift) >= 1 && (
              <span className="flex items-center gap-1 text-amber-600">
                <AlertTriangle className="size-3.5" />
                {ar ? `الربح اتغير بعد التوزيع بـ ${money(d.drift)}` : `Profit changed by ${money(d.drift)} since payout`}
                <InfoTip>{ar ? "حد عدّل حاجة في الأيام دي بعد ما اتوزعت (مرتجع، مصروف…). راجع التعديل، ولو لازم اعكس التوزيع ووزّع تاني." : "Something changed in these days after the payout. Review it; reverse and redo the payout if needed."}</InfoTip>
              </span>
            )}
            {isSuperAdmin && d.status === "active" && (
              <Button size="sm" variant="ghost" className="ms-auto" disabled={reverse.isPending} onClick={() => reverse.mutate(d.id)}>
                <Undo2 className="me-1 size-4" />{ar ? "عكس" : "Reverse"}
              </Button>
            )}
          </header>
          {d.status === "active" && (
            <ul className="divide-y text-sm">
              {d.lines.map((l) => (
                <li key={l.partner_id} className="flex items-center justify-between gap-3 px-4 py-2">
                  <span>{l.name ?? "—"} <span className="text-xs text-muted-foreground">{formatPercent(l.pct, lang)}</span></span>
                  <span className="flex items-center gap-2">
                    <span className="font-semibold tabular-nums">{money(l.amount)}</span>
                    {l.paid && <Badge className="bg-primary/15 text-primary">{ar ? "اتصرف" : "Paid"}</Badge>}
                  </span>
                </li>
              ))}
            </ul>
          )}
          {d.status !== "active" && d.reverse_reason && (
            <p className="px-4 py-2 text-xs text-muted-foreground">{ar ? "السبب" : "Reason"}: {d.reverse_reason}</p>
          )}
        </article>
      ))}
    </div>
  );
}

function DevelopmentFund({
  balance, isSuperAdmin, money, lang,
}: {
  balance: number;
  isSuperAdmin: boolean;
  money: (v: number | null | undefined) => string;
  lang: Lang;
}) {
  const ar = lang === "ar";
  const qc = useQueryClient();
  const [open, setOpen] = useState(false);
  const [amount, setAmount] = useState("");
  const [desc, setDesc] = useState("");
  const spend = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc("spend_development_fund", { _amount: Number(amount), _description: desc.trim() });
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success(ar ? "اتسجل الصرف من الصندوق" : "Fund spending recorded");
      setOpen(false); setAmount(""); setDesc("");
      qc.invalidateQueries({ queryKey: ["payout-history"] });
    },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });
  const valid = Number(amount) > 0 && Number(amount) <= balance && desc.trim().length >= 3;

  return (
    <section className="flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-border bg-card p-4 shadow-sm">
      <div className="flex items-center gap-3">
        <span className="grid size-10 place-items-center rounded-xl bg-muted"><Wrench className="size-5" /></span>
        <div>
          <p className="flex items-center gap-1 text-sm text-muted-foreground">
            {ar ? "رصيد صندوق التطوير والصيانة" : "Development & maintenance fund"}
            <InfoTip>{ar ? "الفلوس اللي اتحجزت من التوزيعات للصيانة والمعدات. بتتصرف من هنا بس عشان تفضل متابعة." : "Money set aside from payouts for maintenance and equipment, spent only from here so it stays traceable."}</InfoTip>
          </p>
          <p className="text-xl font-black tabular-nums">{money(balance)}</p>
        </div>
      </div>
      {isSuperAdmin && (
        <Button variant="outline" disabled={balance <= 0} onClick={() => setOpen(true)}>{ar ? "صرف من الصندوق" : "Spend from fund"}</Button>
      )}
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent dir={ar ? "rtl" : "ltr"}>
          <DialogHeader><DialogTitle>{ar ? "صرف من صندوق التطوير" : "Spend from development fund"}</DialogTitle></DialogHeader>
          <div className="space-y-3">
            <div className="space-y-1">
              <Label htmlFor="fund-amt">{ar ? "المبلغ" : "Amount"}</Label>
              <Input id="fund-amt" type="number" min="0" step="0.01" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} />
              <p className="text-xs text-muted-foreground">{ar ? "المتاح" : "Available"}: {money(balance)}</p>
            </div>
            <div className="space-y-1">
              <Label htmlFor="fund-desc">{ar ? "اتصرف على إيه؟" : "What was it for?"}</Label>
              <Input id="fund-desc" value={desc} onChange={(e) => setDesc(e.target.value)} placeholder={ar ? "مثال: صيانة مكنة الإسبريسو" : "e.g. Espresso machine service"} />
            </div>
          </div>
          <DialogFooter>
            <Button disabled={!valid || spend.isPending} onClick={() => spend.mutate()}>{ar ? "سجّل الصرف" : "Record"}</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </section>
  );
}
