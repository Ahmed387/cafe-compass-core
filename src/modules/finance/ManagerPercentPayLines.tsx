import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Briefcase, CheckCircle2, Wallet } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { CollapsibleSection } from "@/components/shared/KpiCard";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { formatMoney } from "@/lib/format";
import { useI18n } from "@/lib/i18n";

type Line = {
  partner_id: string; user_id: string; employee_name: string; pct: number; base_net_profit: number; amount: number;
  accounting_period_id: string; salary_id: string | null; recorded_amount: number | null; paid_at: string | null;
};

/** Formal payroll lines for General Managers paid a % of net profit: record the line, then pay it. */
export function ManagerPercentPayLines({ start, end }: { start: string; end: string }) {
  const { lang } = useI18n();
  const { me, can } = useAuth();
  const ar = lang === "ar";
  const qc = useQueryClient();
  const manage = can("payroll.manage");
  const money = (v: number) => formatMoney(Number(v), me?.company?.currency ?? "EGP", lang);
  const [method, setMethod] = useState("cash");

  const q = useQuery({
    queryKey: ["hr-manager-percent", start, end],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("hr_manager_percent_pay" as never, { _period_start: start, _period_end: end } as never);
      if (error) throw error;
      return (data ?? []) as unknown as Line[];
    },
  });

  const refresh = () => {
    qc.invalidateQueries({ queryKey: ["hr-manager-percent"] });
    qc.invalidateQueries({ queryKey: ["manager-percent-salary"] });
    qc.invalidateQueries({ queryKey: ["hr-preview"] });
  };

  const record = useMutation({
    mutationFn: async (partnerId: string) => {
      const { data, error } = await supabase.rpc("record_manager_percent_salary" as never, { _partner_id: partnerId, _period_start: start, _period_end: end } as never);
      if (error) throw error;
      return data as unknown as string;
    },
    onSuccess: () => { toast.success(ar ? "تم تسجيل بند الراتب" : "Pay line recorded"); refresh(); },
    onError: (e: Error) => toast.error(e.message),
  });

  const pay = useMutation({
    mutationFn: async (line: Line) => {
      let id = line.salary_id;
      if (!id || Number(line.recorded_amount) !== Number(line.amount)) {
        const { data, error } = await supabase.rpc("record_manager_percent_salary" as never, { _partner_id: line.partner_id, _period_start: start, _period_end: end } as never);
        if (error) throw error;
        id = data as unknown as string;
      }
      const { error } = await supabase.rpc("pay_salary", { _salary_id: id!, _method: method });
      if (error) throw error;
    },
    onSuccess: () => { toast.success(ar ? "تم صرف الراتب" : "Salary paid"); refresh(); },
    onError: (e: Error) => toast.error(e.message),
  });

  const lines = q.data ?? [];
  if (lines.length === 0) return null;

  return (
    <CollapsibleSection
      title={ar ? "رواتب الإدارة بالنسبة — كشف الشهر" : "Management % salaries — this month"}
      description={ar ? "صافي الربح × نسبة المدير. يُحدَّث تلقائيًا حتى الصرف، ثم يُثبَّت ولا يُخصم مرتين من الأرباح." : "Net profit × manager %. Updates live until paid, then it's fixed and never deducted twice."}
      icon={<Briefcase className="h-4 w-4" />}
      actions={manage ? (
        <Select value={method} onValueChange={setMethod}>
          <SelectTrigger className="h-8 w-28"><SelectValue /></SelectTrigger>
          <SelectContent>
            <SelectItem value="cash">{ar ? "نقدي" : "Cash"}</SelectItem>
            <SelectItem value="bank">{ar ? "بنك" : "Bank"}</SelectItem>
          </SelectContent>
        </Select>
      ) : undefined}
    >
      <div className="space-y-2">
        {lines.map((l) => {
          const paid = Boolean(l.paid_at);
          const shown = paid ? Number(l.recorded_amount) : Number(l.amount);
          return (
            <div key={l.partner_id} className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-border bg-card p-4 shadow-sm">
              <div className="min-w-0">
                <div className="font-medium">{l.employee_name}</div>
                <div className="text-xs text-muted-foreground">
                  {money(Number(l.base_net_profit))} × {Number(l.pct)}%
                </div>
              </div>
              <div className="flex items-center gap-3">
                <span className="font-display text-lg tabular-nums">{money(shown)}</span>
                {paid ? (
                  <Badge className="gap-1"><CheckCircle2 className="h-3.5 w-3.5" />{ar ? "مصروف" : "Paid"}</Badge>
                ) : l.salary_id ? (
                  <Badge variant="secondary">{ar ? "مسجل — بانتظار الصرف" : "Recorded — awaiting payment"}</Badge>
                ) : (
                  <Badge variant="outline">{ar ? "غير مسجل" : "Not recorded"}</Badge>
                )}
                {manage && !paid && (
                  <>
                    {!l.salary_id && (
                      <Button size="sm" variant="outline" disabled={record.isPending || Number(l.amount) <= 0} onClick={() => record.mutate(l.partner_id)}>
                        {ar ? "تسجيل في الكشف" : "Add to payroll"}
                      </Button>
                    )}
                    <Button size="sm" className="gap-1" disabled={pay.isPending || Number(l.amount) <= 0} onClick={() => pay.mutate(l)}>
                      <Wallet className="h-4 w-4" />{ar ? "صرف الراتب" : "Pay salary"}
                    </Button>
                  </>
                )}
              </div>
            </div>
          );
        })}
      </div>
    </CollapsibleSection>
  );
}
