import { businessDay } from "@/core/finance/business-dates";

/** Today in the cafe's business day (Africa/Cairo calendar day), as YYYY-MM-DD. */
export function cafeToday(now = new Date(), timeZone = "Africa/Cairo"): string {
  return businessDay(now, timeZone);
}

/** A pay date must be a real day and not in the future. */
export function validPayDate(value: string, today: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00Z`);
  if (Number.isNaN(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== value) return false;
  return value <= today;
}
