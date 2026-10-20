import { supabase } from "@/integrations/supabase/client";
import { cafeToday } from "@/lib/pay-date";
import { isMissingFunction } from "@/lib/supabase-errors";

export { cafeToday, validPayDate } from "@/lib/pay-date";

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
