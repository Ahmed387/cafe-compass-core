/** Today in the cafe's day (Africa/Cairo), as YYYY-MM-DD. */
export function cafeToday(now = new Date(), timeZone = "Africa/Cairo"): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).format(now);
}

/** A pay date must be a real day and not in the future. */
export function validPayDate(value: string, today: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00Z`);
  if (Number.isNaN(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== value) return false;
  return value <= today;
}
