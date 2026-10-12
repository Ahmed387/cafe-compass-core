import { useQuery } from "@tanstack/react-query";
import { Briefcase } from "lucide-react";

import { CollapsibleSection } from "@/components/shared/KpiCard";
import { businessMonth, monthBounds, rangeLabel } from "@/core/finance/business-dates";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { formatMoney } from "@/lib/format";
import { useI18n } from "@/lib/i18n";

type Line = { partner_id: string; employee_name: string; pct: number; base_net_profit: number; amount: number };

/** Percentage-based manager salary for the current business month, computed live from the shared P&L. */
export function ManagerSalaryPanel() {
  const { lang } = useI18n();
  const { me, can } = useAuth();
  const ar = lang === "ar";
  const currency = me?.company?.currency ?? "EGP";
  const money = (v: number) => formatMoney(Number(v), currency, lang);
  const { start, end } = monthBounds(businessMonth());

  const q = useQuery({
    queryKey: ["manager-percent-salary", start],
    enabled: can("payroll.view"),
    queryFn: async () => {
      const { data, error } = await supabase.rpc("hr_manager_percent_pay", { _period_start: start, _period_end: end });
      if (error) throw error;
      return (data ?? []) as Line[];
    },
  });

  const lines = q.data ?? [];
  if (lines.length === 0) return null;
  const total = lines.reduce((s, l) => s + Number(l.amount), 0);
  const base = Number(lines[0]?.base_net_profit ?? 0);

  return (
    <CollapsibleSection
      title={ar ? "راتب المدير (نسبة من صافي الربح)" : "Manager salary (% of net profit)"}
      description={
        ar
          ? `بيتحسب أوتوماتيك وبيتخصم كمصروف تشغيل قبل توزيع الأرباح — ${rangeLabel(start, end, lang)}`
          : `Calculated automatically and booked as an operating cost before payouts — ${rangeLabel(start, end, lang)}`
      }
      icon={<Briefcase className="h-4 w-4" />}
    >
      <div className="card-surface rounded-xl border border-border bg-card p-4 shadow-sm">
        <div className="mb-3 grid gap-3 text-sm sm:grid-cols-3">
          <div><div className="text-muted-foreground">{ar ? "صافي الربح قبل راتب الإدارة" : "Net profit before management"}</div><div className="font-display text-lg tabular-nums">{money(base)}</div></div>
          <div><div className="text-muted-foreground">{ar ? "إجمالي راتب الإدارة" : "Management salary"}</div><div className="font-display text-lg tabular-nums text-destructive">− {money(total)}</div></div>
          <div><div className="text-muted-foreground">{ar ? "صافي الربح بعد راتب الإدارة" : "Net profit after management"}</div><div className="font-display text-lg tabular-nums">{money(base - total)}</div></div>
        </div>
        <div className="space-y-2">
          {lines.map((l) => (
            <div key={l.partner_id} className="flex items-center justify-between gap-3 rounded-lg border border-border p-3 text-sm">
              <span>{l.employee_name} · {Number(l.pct)}%</span>
              <span className="font-semibold tabular-nums">{money(Number(l.amount))}</span>
            </div>
          ))}
        </div>
        {base <= 0 && (
          <p className="mt-2 text-xs text-muted-foreground">{ar ? "لسه مفيش صافي ربح، فالراتب = صفر." : "No net profit yet, so the salary is 0."}</p>
        )}
      </div>
    </CollapsibleSection>
  );
}
