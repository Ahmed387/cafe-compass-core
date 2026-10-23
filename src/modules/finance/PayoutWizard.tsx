import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { CircleCheckBig, CircleX, Target } from "lucide-react";
import { useEffect, useState } from "react";
import { toast } from "sonner";

import { InfoTip } from "@/components/shared/InfoTip";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Switch } from "@/components/ui/switch";
import { Textarea } from "@/components/ui/textarea";
import { addDays, businessToday, previousMonth, rangeLabel } from "@/core/finance/business-dates";
import { supabase } from "@/integrations/supabase/client";
import { formatMoney, formatPercent, friendlyError } from "@/lib/format";
import { cn } from "@/lib/utils";
import type { PayoutPreview } from "@/modules/finance/finance-queries";

type Lang = "ar" | "en";

const CHECK_TEXT: Record<keyof PayoutPreview["checks"], { ar: string; en: string }> = {
  range_valid: { ar: "الفترة بتنتهي النهارده أو قبله", en: "Range ends today or earlier" },
  no_overlap: { ar: "الأيام دي متوزعش أرباحها قبل كده", en: "These days were never paid out before" },
  no_open_shifts: { ar: "مفيش وردية مفتوحة في الفترة", en: "No open shift in the range" },
  no_open_orders: { ar: "مفيش طلبات متدفعتش في الفترة", en: "No unpaid orders in the range" },
  net_positive: { ar: "فيه ربح موجب بعد الاحتياطي ورواتب الإدارة", en: "Positive profit after reserve and management pay" },
  fund_within_limit: { ar: "صندوق التطوير مش أكبر من الربح المتاح", en: "Development fund within available profit" },
  partner_pool_positive: { ar: "فاضل نصيب للشركاء بعد الصندوق", en: "Something left for partners after the fund" },
  shares_total_100: { ar: "نسب الشركاء مجموعها ١٠٠٪", en: "Partner shares total 100%" },
};

function useDebounced<T>(value: T, ms = 400): T {
  const [v, setV] = useState(value);
  useEffect(() => {
    const id = setTimeout(() => setV(value), ms);
    return () => clearTimeout(id);
  }, [value, ms]);
  return v;
}

/** Three steps: pick the dates, set the development fund, review every partner line and confirm. */
export function PayoutWizard({
  open,
  onOpenChange,
  defaultFrom,
  currency,
  lang,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  defaultFrom: string;
  currency: string;
  lang: Lang;
}) {
  const ar = lang === "ar";
  const qc = useQueryClient();
  const money = (v: number) => formatMoney(v, currency, lang);
  const yesterday = addDays(businessToday(), -1);

  const [step, setStep] = useState(1);
  const [from, setFrom] = useState(defaultFrom);
  const [to, setTo] = useState(yesterday < defaultFrom ? businessToday() : yesterday);
  const [fundOn, setFundOn] = useState(false);
  const [fundText, setFundText] = useState("0");
  const [notes, setNotes] = useState("");

  useEffect(() => {
    if (!open) return;
    setStep(1);
    setFrom(defaultFrom);
    setTo(yesterday < defaultFrom ? businessToday() : yesterday);
    setFundOn(false);
    setFundText("0");
    setNotes("");
  }, [open, defaultFrom, yesterday]);

  const fund = fundOn ? Math.max(Number(fundText) || 0, 0) : 0;
  const debouncedFund = useDebounced(fund);
  const validRange = Boolean(from && to && from <= to);

  const preview = useQuery({
    queryKey: ["payout-preview", from, to, debouncedFund],
    enabled: open && validRange,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("payout_preview", { _from: from, _to: to, _development_fund: debouncedFund });
      if (error) throw error;
      return data as unknown as PayoutPreview;
    },
  });
  const p = preview.data;
  const checks = p?.checks;
  const blockers = checks ? (Object.keys(checks) as Array<keyof PayoutPreview["checks"]>).filter((k) => !checks[k]) : [];
  // Fund-related checks are only judged on step 2+.
  const rangeBlockers = blockers.filter((k) => k !== "fund_within_limit" && k !== "partner_pool_positive");

  const execute = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc("execute_payout", {
        _from: from, _to: to, _development_fund: fund, ...(notes.trim() ? { _notes: notes.trim() } : {}),
      });
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success(ar ? "تمام، الأرباح اتوزعت واتسجلت لكل شريك." : "Profit distributed to every partner.");
      for (const key of ["payout-history", "partners", "partner-dividends", "range-pnl", "partner-statement"]) {
        qc.invalidateQueries({ queryKey: [key] });
      }
      onOpenChange(false);
    },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  const stale = fund !== debouncedFund || preview.isFetching;

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent dir={ar ? "rtl" : "ltr"} className="max-h-[90vh] max-w-2xl overflow-y-auto rounded-2xl">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <Target className="size-5 text-primary" />
            {ar ? "توزيع الأرباح" : "Profit payout"}
          </DialogTitle>
          <DialogDescription>
            {ar
              ? "اختار الفترة، احجز صندوق التطوير لو محتاج، وراجع نصيب كل شريك قبل التأكيد."
              : "Pick the dates, reserve a development fund if needed, and review each partner's line before confirming."}
          </DialogDescription>
        </DialogHeader>

        <div className="flex gap-2" aria-hidden>
          {[1, 2, 3].map((n) => (
            <span key={n} className={cn("h-1.5 flex-1 rounded-full", n <= step ? "bg-primary" : "bg-muted")} />
          ))}
        </div>

        {step === 1 && (
          <div className="space-y-4">
            <div className="grid gap-3 sm:grid-cols-2">
              <div className="space-y-1">
                <Label htmlFor="po-from">{ar ? "من يوم" : "From"}</Label>
                <Input id="po-from" type="date" value={from} max={to} onChange={(e) => setFrom(e.target.value)} />
              </div>
              <div className="space-y-1">
                <Label htmlFor="po-to">{ar ? "لحد يوم" : "To"}</Label>
                <Input id="po-to" type="date" value={to} min={from} max={businessToday()} onChange={(e) => setTo(e.target.value)} />
              </div>
            </div>
            <div className="flex flex-wrap gap-2">
              <Button
                type="button"
                size="sm"
                variant="outline"
                onClick={() => {
                  const m = previousMonth();
                  setFrom(m.start);
                  setTo(m.end);
                }}
              >
                {ar ? "الشهر اللي فات" : "Last month"}
              </Button>
              <Button
                type="button"
                size="sm"
                variant="outline"
                onClick={() => {
                  setFrom(defaultFrom);
                  setTo(yesterday < defaultFrom ? businessToday() : yesterday);
                }}
              >
                {ar ? "من بعد آخر توزيع لحد امبارح" : "Since the last payout"}
              </Button>
            </div>
            <p className="rounded-xl bg-muted p-3 text-xs leading-6 text-muted-foreground">
              {ar
                ? "اختار أي فترة، حتى لو شهر واحد. كل وردية بتتحسب على يوم فتحها. اقترحنا عليك تبدأ من اليوم اللي بعد آخر توزيع عشان مفيش يوم يتوزع مرتين."
                : "Pick any period, even a single month. Each shift counts on the day it opened. We suggest starting right after the last payout so no day is paid twice."}
            </p>
            {p && <PeriodSummary pnl={p.pnl} money={money} lang={lang} />}
            {p && (
              <div className="grid gap-2 sm:grid-cols-3">
                <Figure label={ar ? "صافي ربح الفترة" : "Net profit"} value={money(p.net_profit)} tone={p.net_profit < 0 ? "bad" : "good"} />
                <Figure label={ar ? "رواتب الإدارة المستحقة" : "Management pay due"} value={money(p.management_salary_due)} />
                <Figure label={ar ? "الاحتياطي التشغيلي" : "Operating reserve"} value={money(p.reserve_amount)} />
              </div>
            )}
            <ChecksList checks={checks} includeFund={false} lang={lang} loading={preview.isLoading} />
          </div>
        )}

        {step === 2 && p && (
          <div className="space-y-4">
            <div className="flex items-start justify-between gap-3 rounded-xl border p-4">
              <div>
                <div className="flex items-center gap-1.5">
                  <Label>{ar ? "صندوق التطوير والصيانة" : "Development & maintenance fund"}</Label>
                  <InfoTip title={ar ? "ليه الصندوق ده موجود؟" : "Why this fund?"}>
                    {ar
                      ? "عشان نحجز مبلغ ثابت للصيانة والمعدات قبل ما نوزع على الشركاء، فالمكان ميقفش لو مكنة باظت. الفلوس دي بتتسجل في رصيد الصندوق وتتصرف منه بس."
                      : "Sets aside a fixed amount for maintenance and equipment before partners are paid, tracked in its own balance."}
                  </InfoTip>
                </div>
                <p className="mt-1 text-xs text-muted-foreground">
                  {ar ? `المتاح قبل الصندوق: ${money(p.available_before_fund)}` : `Available before fund: ${money(p.available_before_fund)}`}
                </p>
              </div>
              <Switch checked={fundOn} onCheckedChange={setFundOn} aria-label={ar ? "تفعيل الصندوق" : "Enable fund"} />
            </div>
            {fundOn && (
              <div className="space-y-1">
                <Label htmlFor="po-fund">{ar ? "المبلغ الثابت" : "Fixed amount"}</Label>
                <Input id="po-fund" type="number" min="0" step="0.01" inputMode="decimal" value={fundText} onChange={(e) => setFundText(e.target.value)} />
              </div>
            )}
            <div className="space-y-2 rounded-xl border p-4 text-sm">
              <Row label={ar ? "صافي ربح الفترة" : "Net profit"} value={money(p.net_profit)} />
              <Row label={ar ? "− رواتب الإدارة بالنسبة (اللي لسه متسجلتش)" : "− Management % pay not yet in payroll"} value={money(p.management_salary_due)} />
              <Row label={ar ? `− الاحتياطي التشغيلي (${p.reserve_type === "amount" ? money(p.reserve_value) : formatPercent(p.reserve_value, lang)})` : `− Operating reserve (${p.reserve_type === "amount" ? money(p.reserve_value) : formatPercent(p.reserve_value, lang)})`} value={money(p.reserve_amount)} />
              {p.loan_repayment > 0 && (
                <Row label={ar ? "− سداد قروض الشركاء (قبل التوزيع)" : "− Partner loans repaid (before payout)"} value={money(p.loan_repayment)} />
              )}
              <Row label={ar ? "− صندوق التطوير" : "− Development fund"} value={money(fund)} />
              <Row strong label={ar ? "نصيب الشركاء" : "Partner pool"} value={stale ? "…" : money(p.partner_pool)} />
            </div>
            {!stale && (!checks?.fund_within_limit || !checks?.partner_pool_positive) && (
              <p className="rounded-xl bg-destructive/10 p-3 text-sm text-destructive">
                {ar ? "المبلغ ده أكبر من الربح المتاح، قلّله." : "That amount is larger than the available profit — lower it."}
              </p>
            )}
          </div>
        )}

        {step === 3 && p && (
          <div className="space-y-4">
            <p className="text-sm font-semibold">{rangeLabel(from, to, lang)}</p>
            {(p.segments?.length ?? 0) > 1 && (
              <div className="rounded-xl border border-amber-500/40 bg-amber-500/10 p-3 text-sm">
                <p className="font-medium">
                  {ar ? "النسب اتغيرت جوه الفترة دي، فكل جزء اتوزع بنسبه:" : "Shares changed inside this range, so each part uses its own shares:"}
                </p>
                <ul className="mt-1 space-y-0.5 text-xs text-muted-foreground">
                  {p.segments.map((s, i) => (
                    <li key={s.from}>
                      {rangeLabel(s.from, s.to, lang)}: {ar ? "ربح" : "profit"} {money(s.net_profit)} ·{" "}
                      {i === 0 ? (ar ? "بالنسب القديمة" : "old shares") : ar ? "بالنسب الجديدة" : "new shares"}
                    </li>
                  ))}
                </ul>
                <p className="mt-1 text-xs text-muted-foreground">
                  {ar ? "النسبة اللي جنب كل شريك تحت هي حصيلة الجزئين." : "The share shown next to each partner is the blend of both parts."}
                </p>
              </div>
            )}
            {p.loans?.some((l) => l.repay > 0) && (
              <div className="rounded-xl border p-3 text-sm">
                <p className="font-medium">{ar ? "قروض بترجع لأصحابها قبل التوزيع" : "Loans repaid before the payout"}</p>
                <ul className="mt-1 space-y-0.5 text-xs">
                  {p.loans.filter((l) => l.repay > 0).map((l) => (
                    <li key={l.contribution_id} className="flex justify-between gap-3">
                      <span>{l.name}</span>
                      <span className="tabular-nums">
                        {money(l.repay)}
                        {l.carried > 0 && <span className="text-amber-600"> · {ar ? `باقي ${money(l.carried)}` : `${money(l.carried)} left`}</span>}
                      </span>
                    </li>
                  ))}
                </ul>
                <p className="mt-1 text-xs text-muted-foreground">
                  {ar ? "المبلغ ده بيتضاف على رصيد صاحب القرض، وتقدر تصرفهوله زي الأرباح." : "This is added to the lender's balance and can be paid out like dividends."}
                </p>
              </div>
            )}
            <div className="overflow-x-auto rounded-xl border">
              <table className="w-full min-w-[600px] text-sm">
                <thead className="bg-muted text-xs text-muted-foreground">
                  <tr>
                    <th className="p-2 text-start font-medium">{ar ? "الشريك" : "Partner"}</th>
                    <th className="p-2 text-end font-medium">{ar ? "النصيب" : "Share"}</th>
                    <th className="p-2 text-end font-medium">{ar ? "خصم على الحساب" : "Tab deducted"}</th>
                    <th className="p-2 text-end font-medium">{ar ? "خصم سلف" : "Advances"}</th>
                    <th className="p-2 text-end font-medium">{ar ? "يتصرف له" : "Cash due"}</th>
                    <th className="p-2 text-end font-medium">{ar ? "باقي عليه" : "Still owed"}</th>
                  </tr>
                </thead>
                <tbody>
                  {p.lines.map((l) => (
                    <tr key={l.partner_id} className="border-t">
                      <td className="p-2">
                        {l.name} <span className="text-xs text-muted-foreground">{formatPercent(l.pct, lang)}</span>
                        {l.paused && <span className="ms-1 text-xs text-amber-600">{ar ? "(أرباحه متوقفة — نصيبه يفضل في المكان)" : "(paused — share stays in the café)"}</span>}
                      </td>
                      <td className="p-2 text-end tabular-nums">{money(l.amount)}</td>
                      <td className="p-2 text-end tabular-nums">{money(l.tab_deduct)}</td>
                      <td className="p-2 text-end tabular-nums">{money(l.advance_deduct)}</td>
                      <td className="p-2 text-end font-semibold tabular-nums">{money(l.cash_due)}</td>
                      <td className={cn("p-2 text-end tabular-nums", l.tab_carried + l.advance_carried > 0 && "text-amber-600")}>{money(l.tab_carried + l.advance_carried)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p className="text-xs leading-6 text-muted-foreground">
              {ar
                ? "بنخصم الأول فواتيره على الحساب، بعدين السلف اللي أخدها. «باقي عليه» هو اللي نصيبه مكفهوش — بيفضل دين ويتخصم من التوزيع الجاي، مش بيتمسح."
                : "Tabs are deducted first, then advances. “Still owed” is what the dividend couldn’t cover — it carries to the next payout and is never wiped."}
            </p>
            <div className="space-y-1">
              <Label htmlFor="po-notes">{ar ? "ملاحظة (اختياري)" : "Note (optional)"}</Label>
              <Textarea id="po-notes" rows={2} value={notes} onChange={(e) => setNotes(e.target.value)} />
            </div>
            <ChecksList checks={checks} includeFund lang={lang} loading={false} />
          </div>
        )}

        <DialogFooter className="gap-2 sm:justify-between">
          <Button variant="outline" onClick={() => (step === 1 ? onOpenChange(false) : setStep((s) => s - 1))}>
            {step === 1 ? (ar ? "إلغاء" : "Cancel") : ar ? "رجوع" : "Back"}
          </Button>
          {step < 3 ? (
            <Button
              disabled={!p || stale || (step === 1 ? rangeBlockers.length > 0 : blockers.length > 0)}
              onClick={() => setStep((s) => s + 1)}
            >
              {ar ? "التالي" : "Next"}
            </Button>
          ) : (
            <Button disabled={execute.isPending || stale || blockers.length > 0} onClick={() => execute.mutate()}>
              {execute.isPending ? (ar ? "جاري التنفيذ…" : "Processing…") : ar ? "تأكيد وتوزيع" : "Confirm & distribute"}
            </Button>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function ChecksList({
  checks,
  lang,
  loading,
  includeFund,
}: {
  checks: PayoutPreview["checks"] | undefined;
  lang: Lang;
  loading: boolean;
  includeFund: boolean;
}) {
  if (loading || !checks) return <p className="text-sm text-muted-foreground">{lang === "ar" ? "بنحسب…" : "Calculating…"}</p>;
  const keys = (Object.keys(CHECK_TEXT) as Array<keyof PayoutPreview["checks"]>).filter(
    (k) => includeFund || (k !== "fund_within_limit" && k !== "partner_pool_positive"),
  );
  return (
    <ul className="grid gap-1.5 sm:grid-cols-2">
      {keys.map((k) => (
        <li key={k} className="flex items-center gap-2 rounded-lg bg-muted px-3 py-2 text-sm">
          {checks[k] ? (
            <CircleCheckBig className="size-4 shrink-0 text-success" aria-label={lang === "ar" ? "تمام" : "OK"} />
          ) : (
            <CircleX className="size-4 shrink-0 text-destructive" aria-label={lang === "ar" ? "مش متحقق" : "Not met"} />
          )}
          <span className={checks[k] ? "" : "text-destructive"}>{CHECK_TEXT[k][lang]}</span>
        </li>
      ))}
    </ul>
  );
}

/** What happened in the chosen period: sales, what came off them, and the costs, down to net profit. */
function PeriodSummary({ pnl, money, lang }: { pnl: PayoutPreview["pnl"]; money: (v: number) => string; lang: Lang }) {
  const ar = lang === "ar";
  const v = (x: number | null | undefined) => Number(x ?? 0);
  const discounts = v(pnl.promo_discount) + v(pnl.manual_discounts) + v(pnl.points_redeemed);
  const waste = v(pnl.waste_business ?? pnl.waste_cost);
  const shortage = v(pnl.cash_shortage) - v(pnl.cash_over) + v(pnl.stocktake_shortage);
  return (
    <div className="space-y-2 rounded-xl border p-4 text-sm">
      <p className="font-semibold">
        {ar ? `اللي حصل في الفترة (${rangeLabel(pnl.from, pnl.to, lang)})` : `What happened (${rangeLabel(pnl.from, pnl.to, lang)})`}
      </p>
      <Row label={ar ? "عدد الفواتير" : "Invoices"} value={String(v(pnl.orders_count))} />
      <Row label={ar ? "إجمالي المبيعات" : "Gross sales"} value={money(v(pnl.gross_sales))} />
      <Row label={ar ? "− العروض والخصومات والكاش باك" : "− Offers, discounts and cashback"} value={money(discounts)} />
      <Row label={ar ? "− المرتجعات" : "− Refunds"} value={money(v(pnl.refunds_total))} />
      <Row strong label={ar ? "صافي المبيعات" : "Net sales"} value={money(v(pnl.revenue))} />
      <Row label={ar ? "− تكلفة الخامات المباعة" : "− Cost of ingredients sold"} value={money(v(pnl.cogs))} />
      <Row label={ar ? "− الهالك على المكان" : "− Waste carried by the café"} value={money(waste)} />
      <Row label={ar ? "− عجز الدرج والمخزن (بعد خصم الزيادة)" : "− Drawer and stock shortages (net of overs)"} value={money(shortage)} />
      <Row label={ar ? "− المصاريف" : "− Expenses"} value={money(v(pnl.expenses_total))} />
      <Row label={ar ? "− المرتبات" : "− Payroll"} value={money(v(pnl.payroll_total))} />
      <Row strong label={ar ? "صافي الربح" : "Net profit"} value={money(v(pnl.net_profit))} />
      {v(pnl.expenses_pending_count) > 0 && (
        <p className="rounded-lg bg-amber-500/10 p-2 text-xs text-amber-700 dark:text-amber-300">
          {ar
            ? `فيه ${v(pnl.expenses_pending_count)} مصروف لسه مستني الاعتماد (${money(v(pnl.expenses_pending))}) ومش محسوب هنا.`
            : `${v(pnl.expenses_pending_count)} expense(s) still waiting for approval (${money(v(pnl.expenses_pending))}) are not counted.`}
        </p>
      )}
    </div>
  );
}

function Figure({ label, value, tone }: { label: string; value: string; tone?: "good" | "bad" }) {
  return (
    <div className="rounded-xl border p-3">
      <p className="text-xs text-muted-foreground">{label}</p>
      <p className={cn("mt-1 font-bold tabular-nums", tone === "bad" && "text-destructive")}>{value}</p>
    </div>
  );
}

function Row({ label, value, strong = false }: { label: string; value: string; strong?: boolean }) {
  return (
    <div className={cn("flex justify-between gap-3", strong && "border-t pt-2 font-bold")}>
      <span className={strong ? "" : "text-muted-foreground"}>{label}</span>
      <span className="tabular-nums">{value}</span>
    </div>
  );
}
