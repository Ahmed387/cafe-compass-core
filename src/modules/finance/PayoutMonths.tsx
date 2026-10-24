import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { InfoTip } from "@/components/shared/InfoTip";
import { businessToday } from "@/core/finance/business-dates";
import { nextPayoutRange, type MonthPayout } from "@/core/finance/payout-months";
import { monthLabel } from "@/core/finance/salary-month";
import { cn } from "@/lib/utils";
import type { PayoutMonthFigures, PayoutRecord } from "@/modules/finance/finance-queries";

type Lang = "ar" | "en";

/** Every month since the first business day: paid out or not, with its net profit. */
export function PayoutMonths({
  months,
  figures,
  payouts,
  loading,
  canPay,
  onPay,
  money,
  lang,
  payHint,
}: {
  months: MonthPayout[];
  figures: PayoutMonthFigures[];
  payouts: PayoutRecord[];
  loading: boolean;
  canPay: boolean;
  /** Without it the cards are read-only (e.g. on the partners page). */
  onPay?: (range: { from: string; to: string }) => void;
  /** Shown under the cards when they are read-only. */
  payHint?: string;
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
                    ? ar
                      ? "اتوزع"
                      : "Paid out"
                    : m.status === "partial"
                      ? ar
                        ? `اتوزع ${m.paidDays} من ${m.days} يوم`
                        : `${m.paidDays}/${m.days} days paid`
                      : ar
                        ? "متوزعش"
                        : "Not paid out"}
                </Badge>
              </div>
              <p className="mt-1 text-xs text-muted-foreground">
                {m.start} → {m.end}
                {m.current && (ar ? " (الشهر ماخلصش)" : " (month running)")}
              </p>
              <p
                className={cn(
                  "mt-2 font-display text-lg font-bold tabular-nums",
                  Number(fig?.net_profit ?? 0) < 0 && "text-destructive",
                )}
              >
                {fig ? money(fig.net_profit) : "—"}
              </p>
              <p className="text-[11px] text-muted-foreground">
                {ar ? "صافي ربح الشهر" : "Month net profit"}
                {fig &&
                  Number(fig.payroll) === 0 &&
                  Number(fig.revenue) > 0 &&
                  (ar ? " · من غير رواتب" : " · no salaries recorded")}
              </p>
              {paidBy.length > 0 && (
                <p className="mt-1 text-[11px] text-muted-foreground">
                  {ar ? "اتوزع يوم" : "Paid on"}{" "}
                  {paidBy.map((x) => (x.distributed_at ?? "").slice(0, 10)).join("، ")}
                  {" · "}
                  {ar ? "للشركاء" : "to partners"}{" "}
                  {money(paidBy.reduce((s, x) => s + Number(x.partner_pool ?? 0), 0))}
                </p>
              )}
              {canPay && onPay && m.firstUnpaid && (
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
      {payHint && <p className="mt-2 text-xs text-muted-foreground">{payHint}</p>}
    </div>
  );
}

/**
 * One partner's months: was the month paid out, and was their share handed to them yet.
 * A month is paid out for everyone at once; the cash hand-over is per partner.
 */
export function PartnerPayoutMonths({
  partnerId,
  months,
  payouts,
  money,
  lang,
}: {
  partnerId: string;
  months: MonthPayout[];
  payouts: PayoutRecord[];
  money: (v: number | null | undefined) => string;
  lang: Lang;
}) {
  const ar = lang === "ar";
  if (!months.length) return null;
  const active = payouts.filter((x) => x.status === "active" && x.from && x.to);
  return (
    <div className="mt-3 border-t border-border pt-3">
      <p className="mb-2 text-xs font-medium text-muted-foreground">
        {ar ? "الأرباح شهر بشهر" : "Profit by month"}
      </p>
      <ul className="flex flex-wrap gap-2">
        {months.map((m) => {
          const lines = active
            .filter((x) => x.from! <= m.end && x.to! >= m.start)
            .flatMap((x) => x.lines.filter((l) => l.partner_id === partnerId));
          const amount = lines.reduce((s, l) => s + Number(l.amount ?? 0), 0);
          const handed = lines.length > 0 && lines.every((l) => l.paid);
          const state =
            m.status === "open" || lines.length === 0
              ? { text: ar ? "متوزعش" : "Not paid out", cls: "border-border text-muted-foreground" }
              : handed
                ? {
                    text: ar ? "اتوزع واستلمه" : "Paid & received",
                    cls: "border-success/40 bg-success/10 text-success",
                  }
                : {
                    text: ar ? "اتوزع، لسه ماستلمش" : "Paid out, not received",
                    cls: "border-amber-400/60 bg-amber-500/10 text-amber-700 dark:text-amber-300",
                  };
          return (
            <li key={m.month} className={cn("rounded-lg border px-2.5 py-1.5 text-xs", state.cls)}>
              <span className="font-semibold">{monthLabel(m.month, lang)}</span>
              {" · "}
              {state.text}
              {m.status === "partial" &&
                (ar ? ` (${m.paidDays}/${m.days} يوم)` : ` (${m.paidDays}/${m.days} days)`)}
              {amount > 0 && <span className="tabular-nums"> · {money(amount)}</span>}
            </li>
          );
        })}
      </ul>
    </div>
  );
}
