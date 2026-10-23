import { formatDate } from "@/lib/format";

/** The café's business timezone. Every money date (P&L ranges, payroll months) uses it. */
export const BUSINESS_TZ = "Africa/Cairo";

/**
 * Money that belongs to a shift (bills, refunds, waste, drawer difference)
 * counts on the day the shift opened: the database stores it as business_date.
 * Anything else uses the plain Cairo calendar day, so the day starts at
 * midnight. Must match public.business_day_start_hour() in the database.
 */
export const BUSINESS_DAY_START_HOUR = 0;

/** YYYY-MM-DD Cairo calendar day of an instant. */
export function businessDay(at: Date = new Date(), tz = BUSINESS_TZ): string {
  const shifted = new Date(at.getTime() - BUSINESS_DAY_START_HOUR * 3_600_000);
  // en-CA formats as YYYY-MM-DD.
  return new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(shifted);
}

export function businessToday(tz = BUSINESS_TZ): string {
  return businessDay(new Date(), tz);
}

/** Business day of a shift: the Cairo day it opened, however long it stays open. */
export function shiftBusinessDay(openedAt: string | Date, tz = BUSINESS_TZ): string {
  return businessDay(typeof openedAt === "string" ? new Date(openedAt) : openedAt, tz);
}

/** YYYY-MM of the current business month. */
export function businessMonth(tz = BUSINESS_TZ): string {
  return businessToday(tz).slice(0, 7);
}

/** First and last calendar day of a YYYY-MM month (pure date math, no timezone drift). */
export function monthBounds(month: string): { start: string; end: string } {
  const [y, m] = month.split("-").map(Number);
  const last = new Date(Date.UTC(y!, m!, 0)).getUTCDate();
  return { start: `${month}-01`, end: `${month}-${String(last).padStart(2, "0")}` };
}

/** Adds whole days to a YYYY-MM-DD string. */
export function addDays(day: string, days: number): string {
  const date = new Date(`${day}T00:00:00.000Z`);
  date.setUTCDate(date.getUTCDate() + days);
  return date.toISOString().slice(0, 10);
}

/** Inclusive number of days in a range. */
export function daysBetween(from: string, to: string): number {
  return Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000) + 1;
}

/** Month-to-date range in business time. */
export function monthToDate(tz = BUSINESS_TZ): { start: string; end: string } {
  const today = businessToday(tz);
  return { start: `${today.slice(0, 7)}-01`, end: today };
}

/** Previous complete business month. */
export function previousMonth(tz = BUSINESS_TZ): { start: string; end: string } {
  const firstOfThis = `${businessMonth(tz)}-01`;
  return monthBounds(addDays(firstOfThis, -1).slice(0, 7));
}

/** UTC instant where a Cairo calendar day starts (for filtering timestamptz columns). */
export function businessDayStartIso(day: string, tz = BUSINESS_TZ): string {
  // Find the offset of `tz` at noon that day (DST-safe for whole-hour zones like Cairo).
  const noonUtc = new Date(`${day}T12:00:00.000Z`);
  const local = new Date(noonUtc.toLocaleString("en-US", { timeZone: tz }));
  const offsetMs = local.getTime() - new Date(noonUtc.toLocaleString("en-US", { timeZone: "UTC" })).getTime();
  return new Date(Date.parse(`${day}T00:00:00.000Z`) + BUSINESS_DAY_START_HOUR * 3_600_000 - offsetMs).toISOString();
}

export function rangeLabel(from: string, to: string, lang: "en" | "ar" = "en"): string {
  return from === to ? formatDate(from, lang) : `${formatDate(from, lang)} – ${formatDate(to, lang)}`;
}
