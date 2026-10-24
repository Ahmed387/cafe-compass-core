import { useQuery } from "@tanstack/react-query";
import { Banknote, CreditCard, Landmark, Users, WalletCards } from "lucide-react";

import { supabase } from "@/integrations/supabase/client";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Skeleton } from "@/components/ui/skeleton";
import { CollapsibleSection, KpiCard, KpiDetailRows } from "@/components/shared/KpiCard";
import { useFinancialEngine } from "@/core/hooks/useFinancialEngine";
import type { TenderKey } from "@/core/finance/formulas";
import { formatMoney } from "@/lib/format";

export type ShiftFilter = { number: string; from: string; to: string };

type ShiftLite = { id: string; opened_at: string };

/** Filters shifts by sequence number and opening date range (no money math here). */
export function filterShifts<T extends ShiftLite>(rows: T[], numbers: Record<string, number>, f: ShiftFilter) {
  const wanted = f.number.trim().replace(/^#/, "");
  return rows.filter((row) => {
    if (wanted && String(numbers[row.id] ?? "") !== wanted) return false;
    const day = row.opened_at.slice(0, 10);
    if (f.from && day < f.from) return false;
    if (f.to && day > f.to) return false;
    return true;
  });
}

const TENDER_LABELS: Record<TenderKey, { ar: string; en: string }> = {
  cash: { ar: "كاش", en: "Cash" },
  instapay: { ar: "انستاباي", en: "InstaPay" },
  visa: { ar: "فيزا", en: "Visa" },
  wallet: { ar: "المحافظ / فودافون كاش", en: "Wallets" },
  partner_tab: { ar: "على حساب الشريك", en: "Partner tab" },
};

export function ShiftFilterBar({
  value,
  onChange,
  lang,
}: {
  value: ShiftFilter;
  onChange: (v: ShiftFilter) => void;
  lang: "ar" | "en";
}) {
  const ar = lang === "ar";
  return (
    <div className="grid gap-3 rounded-lg border border-border bg-card p-3 sm:grid-cols-3">
      <div className="space-y-1">
        <Label>{ar ? "رقم الوردية" : "Shift #"}</Label>
        <Input
          inputMode="numeric"
          placeholder="#12"
          value={value.number}
          onChange={(e) => onChange({ ...value, number: e.target.value })}
        />
      </div>
      <div className="space-y-1">
        <Label>{ar ? "من تاريخ" : "From"}</Label>
        <Input type="date" value={value.from} onChange={(e) => onChange({ ...value, from: e.target.value })} />
      </div>
      <div className="space-y-1">
        <Label>{ar ? "إلى تاريخ" : "To"}</Label>
        <Input type="date" value={value.to} onChange={(e) => onChange({ ...value, to: e.target.value })} />
      </div>
    </div>
  );
}

export function ShiftLedgerKpis({
  branchId,
  shiftIds,
  currency,
  lang,
}: {
  branchId: string | null | undefined;
  shiftIds: string[];
  currency: string;
  lang: "ar" | "en";
}) {
  const engine = useFinancialEngine({ branchId, shiftIds });
  const ar = lang === "ar";
  const money = (v: number) => formatMoney(v, currency, lang);

  if (engine.isLoading) {
    return (
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {Array.from({ length: 6 }).map((_, i) => (
          <Skeleton key={i} className="h-24" />
        ))}
      </div>
    );
  }
  if (engine.isError) {
    return (
      <div className="rounded-lg border border-destructive/30 bg-destructive/10 p-3 text-sm text-destructive">
        {ar ? "تعذر حساب ملخص الورديات." : "Could not compute the shift summary."}
      </div>
    );
  }
  const zero = {
    gross: 0, cogs: 0, netSales: 0, refunds: 0, shiftExpenses: 0, waste: 0, shrinkage: 0, venueRefunds: 0,
    grossMargin: 0, variance: 0, shiftCount: 0,
    tenders: Object.fromEntries(Object.keys(TENDER_LABELS).map((k) => [k, 0])) as Record<TenderKey, number>,
    tenderCounts: Object.fromEntries(Object.keys(TENDER_LABELS).map((k) => [k, 0])) as Record<TenderKey, number>,
  };
  const t = engine.data?.totals ?? zero;
  const variance = t.variance;
  const drawer = { counted: 0, expected: 0, short: 0, over: 0 };
  for (const row of engine.data?.byShift.values() ?? []) {
    if (row.status !== "closed") continue;
    drawer.counted += Number(row.closingCash ?? 0);
    drawer.expected += Number(row.expectedCash ?? 0);
    const v = Number(row.variance ?? 0);
    if (v < 0) drawer.short += v;
    else drawer.over += v;
  }

  const shiftRows = [...(engine.data?.byShift.values() ?? [])];
  const detailRows = (pick: (row: (typeof shiftRows)[number]) => number | null) => (
    <KpiDetailRows
      empty={ar ? "لا توجد ورديات ضمن النطاق." : "No shifts in this range."}
      rows={shiftRows.map((row) => ({
        label: `${ar ? "وردية" : "Shift"} · ${new Date(row.openedAt).toLocaleDateString(ar ? "ar-EG" : "en-GB")}`,
        hint: row.status === "closed" ? (ar ? "مغلقة" : "Closed") : (ar ? "مفتوحة" : "Open"),
        value: money(Number(pick(row) ?? 0)),
      }))}
    />
  );
  return (
    <div className="space-y-4">
      <KpiCard
        size="master"
        label={ar ? "إجمالي الإيراد" : "Gross revenue"}
        value={money(t.gross)}
        hint={`${t.shiftCount} ${ar ? "وردية" : "shifts"}`}
        tone="brand"
        formula={ar ? "مجموع قيمة البنود قبل العروض والخصومات والمرتجعات." : "Sum of line values before offers, discounts, and refunds."}
        source={ar ? "المصدر: الفواتير المسجلة في الورديات المحددة." : "Source: invoices recorded in the selected shifts."}
        details={detailRows((row) => row.gross)}
      />
      <PaymentBreakdown tenders={t.tenders} counts={t.tenderCounts} currency={currency} lang={lang} byShift={shiftRows} />
      <CollapsibleSection title={ar ? "الربحية" : "Profitability"}>
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <KpiCard label={ar ? "تكلفة الخامات المباعة" : "COGS (ingredients sold)"} value={money(t.cogs)} formula={ar ? "تكلفة الوصفات وقت البيع بالظبط — نسبة الهالك مش بتتضاف عليها." : "Exact sale-time recipe cost — the waste % is never added to it."} source={ar ? "المصدر: بنود الفواتير والوصفات." : "Source: invoice items and recipes."} details={detailRows((row) => row.cogs)} />
        <KpiCard label={ar ? "مجمل ربح الوردية" : "Shift gross profit"} value={money(t.netSales - t.cogs)} tone={t.netSales - t.cogs < 0 ? "bad" : "good"} formula={ar ? "إيرادات فواتير الوردية دي ناقص تكلفة الخامات والوصفات اللي اتباعت فيها بس، عشان تعرف مكسب الوردية كام قبل المصروفات." : "Shift net sales − sale-time frozen ingredient cost of what was sold."} source={ar ? "المصدر: بنود فواتير الورديات المحددة؛ لا يُعاد تسعير المبيعات القديمة." : "Source: invoice lines in the selected shifts; historical sales are never repriced."} details={detailRows((row) => row.netSales - row.cogs)} />
        <KpiCard label={ar ? "ربح الورديات بعد مصروفاتها" : "Shift profit after shift expenses"} value={money(t.grossMargin - t.shiftExpenses)} tone="brand" formula={ar ? "هامش الورديات − المصروفات اللي اتصرفت من درجها. مش داخل فيه الإيجار والمصروفات العامة والرواتب، فده مش صافي الربح: صافي الربح في تبويب الربح." : "Shift margin − expenses paid from their drawers. Rent, general expenses and salaries are not in it, so this is not net profit: see the Profit tab."} source={ar ? "يشمل الهالك وعجز المخزون." : "Includes waste and stock shrinkage."} details={detailRows((row) => row.grossMargin - row.shiftExpenses)} />
      </div>
      </CollapsibleSection>
      <CollapsibleSection title={ar ? "المصروفات التشغيلية" : "Operating expenses"}>
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <KpiCard label={ar ? "مصروفات وهالك الورديات" : "Shift expenses & waste"} value={money(t.shiftExpenses + t.waste)} formula={ar ? "اللي اتصرف من درج الورديات دي (نثريات ومستلزمات) + الهالك. الإيجار والمصروفات العامة والرواتب مش هنا، دي في تبويب الربح. المرتجعات مش هنا لأنها مخصومة من الإيراد أصلاً." : "Paid from these shifts' drawers + waste. Rent, general expenses and salaries are in the Profit tab. Refunds are not here: they already come off revenue."} source={ar ? "المصدر: مصروفات الدرج وحركات المخزون." : "Source: drawer expenses and stock movements."} details={detailRows((row) => row.shiftExpenses + row.waste)} />
        <KpiCard label={ar ? "عجز المخزون على المكان" : "Venue stock shrinkage"} value={money(t.shrinkage)} formula={ar ? "مجموع فروق الجرد التي يتحملها المكان." : "Sum of stocktake shortages absorbed by the venue."} source={ar ? "المصدر: تسويات الجرد المعتمدة." : "Source: approved stocktake settlements."} details={detailRows((row) => row.shrinkage)} />
        <KpiCard label={ar ? "مبيعات الفواتير المسجلة" : "Invoiced sales revenue"} value={money(t.netSales)} formula={ar ? "الإجمالي − العروض − الخصومات − المرتجعات." : "Gross − offers − discounts − refunds."} source={ar ? "المصدر: الفواتير والمرتجعات." : "Source: invoices and refunds."} details={detailRows((row) => row.netSales)} />
      </div>
      </CollapsibleSection>
      <CollapsibleSection title={ar ? "تسوية الدرج" : "Drawer reconciliation"}>
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <KpiCard label={ar ? "نقدية الدرج المعدودة" : "Actual drawer cash"} value={money(drawer.counted)} hint={`${ar ? "المتوقع" : "Expected"}: ${money(drawer.expected)}`} formula={ar ? "مجموع النقدية التي أدخلها الكاشير عند إغلاق الورديات." : "Sum of cash entered by cashiers when closing shifts."} source={ar ? "المصدر: إغلاقات الورديات." : "Source: shift closings."} details={detailRows((row) => row.closingCash)} />
        <KpiCard label={ar ? "عجز الدرج" : "Drawer shortage"} value={money(drawer.short)} tone={drawer.short < 0 ? "bad" : undefined} formula={ar ? "الفروق السالبة فقط: المعدود − المتوقع." : "Negative variances only: counted − expected."} source={ar ? "المصدر: تسوية كل وردية مغلقة." : "Source: each closed shift reconciliation."} details={detailRows((row) => row.variance !== null && row.variance < 0 ? row.variance : 0)} />
        <KpiCard label={ar ? "زيادة الدرج" : "Drawer surplus"} value={money(drawer.over)} tone={drawer.over > 0 ? "good" : undefined} formula={ar ? "الفروق الموجبة فقط: المعدود − المتوقع." : "Positive variances only: counted − expected."} source={ar ? "المصدر: تسوية كل وردية مغلقة." : "Source: each closed shift reconciliation."} details={detailRows((row) => row.variance !== null && row.variance > 0 ? row.variance : 0)} />
        <KpiCard label={ar ? "صافي الفارق" : "Net over/short"} value={money(variance)} tone={variance < 0 ? "bad" : variance > 0 ? "good" : undefined} formula={ar ? "إجمالي المعدود − إجمالي المتوقع." : "Total counted − total expected."} source={ar ? "المصدر: الورديات المغلقة فقط." : "Source: closed shifts only."} details={detailRows((row) => row.variance)} />
      </div>
      </CollapsibleSection>
    </div>
  );
}

/** How each drawer shortage in the shown shifts was settled: venue, one staff member, or crew split. */
export function ShiftShortageBreakdown({
  shifts,
  numbers,
  currency,
  lang,
}: {
  shifts: Array<{ id: string; status: string; variance: number | null; resolution: string | null }>;
  numbers: Record<string, number>;
  currency: string;
  lang: "ar" | "en";
}) {
  const ar = lang === "ar";
  const short = shifts.filter((s) => s.status === "closed" && Number(s.variance ?? 0) < 0);
  const ids = short.map((s) => s.id);
  const penalties = useQuery({
    queryKey: ["shift-shortage-penalties", ids],
    enabled: ids.length > 0,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("staff_penalties")
        .select("shift_id, amount, staff_id, user_profiles!staff_penalties_staff_id_fkey(display_name, first_name)")
        .in("shift_id", ids);
      if (error) throw error;
      return (data ?? []) as unknown as Array<{ shift_id: string; amount: number; user_profiles: { display_name: string | null; first_name: string } | null }>;
    },
  });
  if (short.length === 0) return null;
  const money = (v: number) => formatMoney(v, currency, lang);
  const totals = { venue: 0, staff: 0, split: 0 };
  const cards = short.map((s) => {
    const lines = (penalties.data ?? []).filter((p) => p.shift_id === s.id);
    const mode: "venue" | "staff" | "split" | "unset" =
      s.resolution === "venue" || s.resolution === "staff" || s.resolution === "split" ? s.resolution : "unset";
    if (mode === "unset") return { s, lines, mode };
    totals[mode] += Math.abs(Number(s.variance));
    return { s, lines, mode };
  });
  const label = { unset: ar ? "غير مُسجّل" : "Not recorded", venue: ar ? "تحمل المكان" : "Venue absorbed", staff: ar ? "جزاء موظف" : "Staff penalty", split: ar ? "تقسيم على الطاقم" : "Crew split" };
  return (
    <CollapsibleSection title={ar ? "تسوية العجز في الورديات" : "How shortages were settled"}>
      <div className="space-y-3">
      <div className="grid grid-cols-3 gap-2">
        {(["venue", "staff", "split"] as const).map((k) => (
          <KpiCard
            key={k}
            label={label[k]}
            value={money(totals[k])}
            tone={k === "venue" ? "bad" : "warn"}
            formula={ar ? "مجموع عجز الورديات المسجل بهذه التسوية." : "Sum of shift shortages recorded with this settlement."}
            source={ar ? "المصدر: اختيار التسوية المحفوظ وإسنادات الجزاءات." : "Source: saved settlement choice and penalty assignments."}
            details={
              <KpiDetailRows
                empty={ar ? "لا توجد ورديات بهذه التسوية." : "No shifts with this settlement."}
                rows={cards.filter((card) => card.mode === k).map((card) => ({
                  label: `#${numbers[card.s.id] ?? "—"}`,
                  hint: label[card.mode],
                  value: money(Math.abs(Number(card.s.variance))),
                }))}
              />
            }
          />
        ))}
      </div>
      <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
        {cards.map(({ s, lines, mode }) => (
          <div key={s.id} className="rounded-xl border bg-card p-3 text-sm">
            <div className="flex items-center justify-between gap-2">
              <span className="font-semibold">#{numbers[s.id] ?? "—"}</span>
              <span className="rounded-full bg-muted px-2 py-0.5 text-xs">{label[mode]}</span>
            </div>
            <p className="mt-1 font-bold text-destructive tabular-nums">{money(Number(s.variance))}</p>
            {mode === "split" && lines.length > 0 && (
              <p className="mt-1 text-xs">{ar ? "نصيب الفرد" : "Per person"}: <strong className="tabular-nums">{money(Number(lines[0]!.amount))}</strong> × {lines.length}</p>
            )}
            {mode !== "venue" && lines.length > 0 && (
              <ul className="mt-2 space-y-0.5 text-xs text-muted-foreground">
                {lines.map((l, i) => (
                  <li key={i} className="flex justify-between gap-2">
                    <span className="truncate">{l.user_profiles?.display_name || l.user_profiles?.first_name || "—"}</span>
                    <span className="tabular-nums">{money(Number(l.amount))}</span>
                  </li>
                ))}
              </ul>
            )}
          </div>
        ))}
      </div>
      </div>
    </CollapsibleSection>
  );
}

/** "Revenue by payment method": total master card on top, one card per tender (amount + count) below. */
export function PaymentBreakdown({
  tenders,
  counts,
  currency,
  lang,
  byShift = [],
}: {
  tenders: Record<TenderKey, number>;
  counts: Record<TenderKey, number>;
  currency: string;
  lang: "ar" | "en";
  byShift?: Array<{ openedAt: string; tenders: Record<TenderKey, number>; tenderCounts: Record<TenderKey, number> }>;
}) {
  const ar = lang === "ar";
  const money = (v: number) => formatMoney(v, currency, lang);
  const keys = Object.keys(TENDER_LABELS) as TenderKey[];
  return (
    <CollapsibleSection title={ar ? "توزيع الإيرادات حسب طريقة الدفع" : "Revenue breakdown by payment method"}>
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-3 lg:grid-cols-5">
        {keys.map((key) => (
          <KpiCard
            key={key}
            label={TENDER_LABELS[key][lang]}
            value={money(tenders[key] ?? 0)}
            hint={`${counts[key] ?? 0} ${ar ? "عملية" : "txns"}`}
            formula={ar ? "اللي اتدفع بالطريقة دي − اللي رجع للعميل بيها (صنف اتشال، أوردر اتلغى، أو مرتجع). حساب الشريك = اللي متسجل على الشريك. مجموع الكروت = صافي الإيراد." : "Paid with this method − money handed back with it (removed item, cancelled order or refund). Partner tab = what is charged to the partner. The cards add up to net revenue."}
            source={ar ? "المصدر: مدفوعات الفواتير ومرتجعاتها وحسابات الشركاء." : "Source: invoice payments, refunds and partner tabs."}
            details={byShift.length ? <KpiDetailRows rows={byShift.filter((row) => row.tenders[key] || row.tenderCounts[key]).map((row) => ({ label: new Date(row.openedAt).toLocaleDateString(ar ? "ar-EG" : "en-GB"), value: money(row.tenders[key]), hint: `${row.tenderCounts[key]} ${ar ? "عملية" : "txns"}` }))} empty={ar ? "لا توجد عمليات بهذه الطريقة." : "No payments by this method."} /> : undefined}
          />
        ))}
      </div>
    </CollapsibleSection>
  );
}

/** Payment breakdown for one live shift (used in the cashier closing screen). */
export function ShiftPaymentBreakdown({ branchId, shiftId, currency, lang }: { branchId: string | null | undefined; shiftId: string; currency: string; lang: "ar" | "en" }) {
  const engine = useFinancialEngine({ branchId, shiftIds: [shiftId] });
  const t = engine.data?.totals;
  if (!t) return null;
  const ar = lang === "ar";
  const items: Array<{
    key: TenderKey;
    icon: typeof Banknote;
    featured?: boolean;
  }> = [
    { key: "cash", icon: Banknote, featured: true },
    { key: "instapay", icon: Landmark },
    { key: "visa", icon: CreditCard },
    { key: "wallet", icon: WalletCards },
    { key: "partner_tab", icon: Users },
  ];
  return (
    <section className="space-y-3" aria-labelledby="shift-revenue-heading">
      <div className="flex min-w-0 items-center gap-3">
        <span className="h-7 w-1.5 shrink-0 rounded-full bg-primary" />
        <div className="min-w-0">
          <h3 id="shift-revenue-heading" className="font-display text-base font-bold text-foreground">
            {ar ? "توزيع الإيرادات" : "Revenue breakdown"}
          </h3>
          <p className="text-xs text-muted-foreground">
            {ar ? "حسب طريقة الدفع المسجلة" : "By recorded payment method"}
          </p>
        </div>
      </div>
      <div className="space-y-2">
        {items.map(({ key, icon: Icon, featured }) => (
          <div
            key={key}
            className={
              featured
                ? "grid grid-cols-[minmax(0,1fr)_auto] items-center gap-4 rounded-2xl border border-primary/30 bg-primary/10 p-4 shadow-sm"
                : "grid grid-cols-[minmax(0,1fr)_auto] items-center gap-4 rounded-xl border border-border bg-card px-4 py-3"
            }
          >
            <div className="flex min-w-0 items-center gap-3">
              <span
                className={
                  featured
                    ? "grid size-11 shrink-0 place-items-center rounded-xl bg-primary text-primary-foreground shadow-sm"
                    : "grid size-9 shrink-0 place-items-center rounded-lg bg-accent/15 text-accent-foreground"
                }
              >
                <Icon className={featured ? "size-5" : "size-4"} />
              </span>
              <div className="min-w-0">
                <p className="truncate text-sm font-bold text-foreground">{TENDER_LABELS[key][lang]}</p>
                <p className="text-xs text-muted-foreground">
                  {t.tenderCounts[key] ?? 0} {ar ? "عملية" : "transactions"}
                </p>
              </div>
            </div>
            <p className={`${featured ? "text-xl" : "text-base"} shrink-0 font-display font-bold tabular-nums text-foreground`}>
              {formatMoney(t.tenders[key] ?? 0, currency, lang)}
            </p>
          </div>
        ))}
      </div>
    </section>
  );
}
