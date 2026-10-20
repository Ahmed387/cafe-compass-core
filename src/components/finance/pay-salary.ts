import { supabase } from "@/integrations/supabase/client";
import { isMissingFunction } from "@/lib/supabase-errors";

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

/**
 * Pays an issued salary on the chosen day. The treasury line and the
 * salary's paid date both use that day.
 */
export async function paySalaryOn(salaryId: string, method: string, paidOn: string) {
  const { error } = await supabase.rpc("pay_salary", { _salary_id: salaryId, _method: method, _paid_on: paidOn } as never);
  if (!error) return;
  // Database without the pay-date migration: only today's date can still be honoured.
  if (isMissingFunction(error) && paidOn === cafeToday()) {
    const retry = await supabase.rpc("pay_salary", { _salary_id: salaryId, _method: method });
    if (retry.error) throw retry.error;
    return;
  }
  throw error;
}
