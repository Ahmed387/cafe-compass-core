import { addDays, daysBetween, monthBounds } from "./business-dates.ts";

export type PayoutRange = { from: string | null; to: string | null; status: string };

export type MonthPayout = {
  /** YYYY-MM */
  month: string;
  /** First counted day: the 1st, or the first business day in the first month. */
  start: string;
  /** Last counted day: month end, or today in the current month. */
  end: string;
  /** Today falls inside this month. */
  current: boolean;
  /** Days of [start, end] covered by an active payout. */
  paidDays: number;
  days: number;
  status: "paid" | "partial" | "open";
  /** First day of the month not covered by a payout, if any. */
  firstUnpaid: string | null;
};

function covered(day: string, ranges: PayoutRange[]): boolean {
  return ranges.some((r) => r.from !== null && r.to !== null && r.from <= day && day <= r.to);
}

/**
 * Every month from the first business day to today, with how much of it was
 * paid out. The super admin can pay out chosen months, so paid months need
 * not be contiguous.
 */
export function payoutMonths(
  firstDay: string,
  today: string,
  payouts: PayoutRange[],
): MonthPayout[] {
  if (!firstDay || firstDay > today) return [];
  const active = payouts.filter((p) => p.status === "active");
  const out: MonthPayout[] = [];
  let month = firstDay.slice(0, 7);
  while (month <= today.slice(0, 7)) {
    const b = monthBounds(month);
    const start = b.start < firstDay ? firstDay : b.start;
    const end = b.end > today ? today : b.end;
    let paidDays = 0;
    let firstUnpaid: string | null = null;
    for (let d = start; d <= end; d = addDays(d, 1)) {
      if (covered(d, active)) paidDays += 1;
      else firstUnpaid ??= d;
    }
    const days = daysBetween(start, end);
    out.push({
      month,
      start,
      end,
      current: b.end >= today,
      paidDays,
      days,
      status: paidDays === 0 ? "open" : paidDays >= days ? "paid" : "partial",
      firstUnpaid,
    });
    month = addDays(b.end, 1).slice(0, 7);
  }
  return out;
}

/**
 * Where the next payout starts: the first day not yet paid out, in the
 * earliest month that still has unpaid days. It ends at that month's end,
 * before any paid stretch, or yesterday when the month is still running.
 */
export function nextPayoutRange(
  months: MonthPayout[],
  today: string,
  payouts: PayoutRange[],
): { from: string; to: string } | null {
  const m = months.find((x) => x.firstUnpaid !== null);
  if (!m || !m.firstUnpaid) return null;
  const active = payouts.filter((p) => p.status === "active");
  // Stop before a later paid stretch in the same month, so the range never overlaps a payout.
  let to = m.firstUnpaid;
  while (to < m.end && !covered(addDays(to, 1), active)) to = addDays(to, 1);
  if (m.current && to >= today) {
    const yesterday = addDays(today, -1);
    to = yesterday < m.firstUnpaid ? today : yesterday;
  }
  return { from: m.firstUnpaid, to };
}
