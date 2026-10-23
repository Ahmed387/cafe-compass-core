import { useQuery } from "@tanstack/react-query";

import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { useI18n } from "@/lib/i18n";
import { monthToDate } from "@/core/finance/business-dates";
import { ShiftLedgerKpis } from "@/modules/operations/ShiftLedgerKpis";

/** The core shift KPIs for this business month, from the shared engine. */
export function FinanceKpiStrip() {
  const { lang } = useI18n();
  const { me, can, currentBranchId } = useAuth();
  const ar = lang === "ar";
  const allowed = can("reports.profit") || can("expenses.view");
  const shifts = useQuery({
    queryKey: ["finance-month-shifts", currentBranchId, monthToDate().start],
    enabled: allowed && Boolean(currentBranchId),
    queryFn: async () => {
      const start = monthToDate().start;
      const { data, error } = await supabase
        .from("shifts")
        .select("id")
        .eq("branch_id", currentBranchId!)
        .gte("business_date", start)
        .limit(500);
      if (error) throw error;
      return { start, ids: (data ?? []).map((s) => s.id) };
    },
  });
  if (!allowed) return null;
  const start = shifts.data?.start ?? monthToDate().start;
  const ids = shifts.data?.ids ?? [];
  return (
    <section className="mb-5 space-y-2">
      <p className="text-xs font-medium text-muted-foreground">
        {ar ? `ورديات الشهر من ${start}` : `This month's shifts since ${start}`}
      </p>
      <ShiftLedgerKpis
        branchId={currentBranchId}
        shiftIds={ids}
        currency={me?.company?.currency ?? "EGP"}
        lang={ar ? "ar" : "en"}
      />
    </section>
  );
}
