import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { ArrowDownLeft, ArrowUpRight, Briefcase, Landmark, Wallet } from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { supabase } from "@/integrations/supabase/client";
import { formatMoney, formatPercent, friendlyError } from "@/lib/format";

export type FlowPartner = {
  id: string;
  name: string;
  user_id: string | null;
  is_managing_staff: boolean | null;
  management_salary_type?: string | null;
  management_salary_pct?: number | null;
  capital: number;
  equity: number;
  balance: number;
};

/** Per-partner money-in / money-out cards: capital & equity, management salary, distributed profit, net balance. */
export function PartnerMoneyFlowCards({
  partners,
  currency,
  lang,
  isSuper,
  openNetProfit,
}: {
  partners: FlowPartner[];
  currency: string;
  lang: "ar" | "en";
  isSuper: boolean;
  openNetProfit: number | undefined;
}) {
  const ar = lang === "ar";
  const money = (v: number) => formatMoney(v, currency, lang);
  const ids = partners.map((p) => p.id);
  const userIds = partners.map((p) => p.user_id).filter(Boolean) as string[];

  const flows = useQuery({
    queryKey: ["partner-money-flow", ids.join(","), userIds.join(",")],
    enabled: ids.length > 0,
    queryFn: async () => {
      const [lines, salaries] = await Promise.all([
        supabase
          .from("profit_distribution_lines")
          .select("partner_id, amount, profit_distributions!inner(status)")
          .in("partner_id", ids)
          .eq("profit_distributions.status", "active"),
        userIds.length
          ? supabase.from("salary_payments").select("user_id, net_amount").in("user_id", userIds).eq("status", "active").not("paid_at", "is", null)
          : Promise.resolve({ data: [] as Array<{ user_id: string; net_amount: number }>, error: null }),
      ]);
      if (lines.error) throw lines.error;
      const dist: Record<string, number> = {};
      for (const l of (lines.data ?? []) as Array<{ partner_id: string; amount: number }>) dist[l.partner_id] = (dist[l.partner_id] ?? 0) + Number(l.amount);
      const sal: Record<string, number> = {};
      for (const s of (salaries.data ?? []) as Array<{ user_id: string; net_amount: number }>) sal[s.user_id] = (sal[s.user_id] ?? 0) + Number(s.net_amount);
      return { dist, sal };
    },
  });

  if (!partners.length) return <p className="text-sm text-muted-foreground">{ar ? "لا يوجد شركاء نشطون." : "No active partners."}</p>;

  return (
    <div className="grid gap-4 lg:grid-cols-2">
      {partners.map((p) => {
        const distributed = flows.data?.dist[p.id] ?? 0;
        const salary = p.user_id ? flows.data?.sal[p.user_id] ?? 0 : 0;
        const pctMode = p.management_salary_type === "percent";
        return (
          <article key={p.id} className="card-surface rounded-2xl border border-border bg-card p-4 shadow-sm sm:p-5">
            <header className="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-3">
              <div className="min-w-0">
                <h4 className="truncate font-display text-base font-semibold">{p.name}</h4>
                <p className="text-xs text-muted-foreground">
                  {p.is_managing_staff ? (ar ? "شريك ومدير عام" : "Partner & general manager") : ar ? "شريك مستثمر" : "Investing partner"}
                </p>
              </div>
              {p.is_managing_staff && (
                <Badge variant="secondary" className="shrink-0">
                  {pctMode ? `${ar ? "راتب نسبة" : "Profit %"} ${formatPercent(Number(p.management_salary_pct ?? 0), lang)}` : ar ? "راتب ثابت" : "Fixed salary"}
                </Badge>
              )}
            </header>

            <dl className="mt-4 grid grid-cols-2 gap-3">
              <Metric icon={<Landmark className="size-4" />} label={ar ? "رأس المال" : "Capital"} value={money(p.capital)} hint={`${ar ? "الحصة" : "Equity"} ${formatPercent(p.equity, lang)}`} />
              <Metric icon={<ArrowDownLeft className="size-4" />} label={ar ? "أرباح موزعة" : "Profit distributed"} value={money(distributed)} hint={ar ? "كل التوزيعات" : "All payouts"} tone="good" />
              <Metric
                icon={<Briefcase className="size-4" />}
                label={ar ? "راتب الإدارة المستلم" : "Management salary paid"}
                value={p.is_managing_staff ? money(salary) : "—"}
                hint={
                  p.is_managing_staff && pctMode && openNetProfit !== undefined
                    ? `${ar ? "تقديري من بعد آخر توزيع" : "Estimate since last payout"}: ${money(Math.max(0, openNetProfit) * Number(p.management_salary_pct ?? 0) / 100)}`
                    : ar ? "يُحسب مصروفًا تشغيليًا" : "Booked as operating expense"
                }
              />
              <Metric
                icon={p.balance < 0 ? <ArrowUpRight className="size-4" /> : <Wallet className="size-4" />}
                label={ar ? "الرصيد الصافي المستحق" : "Net balance due"}
                value={money(p.balance)}
                hint={p.balance < 0 ? (ar ? "مدين للمكان" : "Owes the venue") : ar ? "مستحق للشريك" : "Owed to partner"}
                tone={p.balance < 0 ? "bad" : "good"}
              />
            </dl>

            {isSuper && p.is_managing_staff && <SalaryTypeEditor partner={p} lang={lang} />}
          </article>
        );
      })}
    </div>
  );
}

function Metric({ icon, label, value, hint, tone }: { icon: React.ReactNode; label: string; value: string; hint?: string; tone?: "good" | "bad" }) {
  return (
    <div className="min-w-0 rounded-xl border border-border bg-card p-3">
      <dt className="flex items-center gap-1.5 text-xs text-muted-foreground">
        <span className="shrink-0 text-primary">{icon}</span>
        <span className="truncate">{label}</span>
      </dt>
      <dd className={`mt-1 break-words font-display text-base font-bold leading-tight tabular-nums ${tone === "bad" ? "text-destructive" : tone === "good" ? "text-success" : ""}`}>{value}</dd>
      {hint && <p className="mt-0.5 text-[11px] leading-snug text-muted-foreground">{hint}</p>}
    </div>
  );
}

function SalaryTypeEditor({ partner, lang }: { partner: FlowPartner; lang: "ar" | "en" }) {
  const ar = lang === "ar";
  const qc = useQueryClient();
  const [type, setType] = useState(partner.management_salary_type === "percent" ? "percent" : "fixed");
  const [pct, setPct] = useState(String(partner.management_salary_pct ?? 0));
  const save = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc("set_partner_salary_type" as never, { _partner_id: partner.id, _type: type, _pct: Number(pct || 0) } as never);
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success(ar ? "تم حفظ نوع الراتب" : "Salary type saved");
      void qc.invalidateQueries();
    },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });
  return (
    <div className="mt-4 grid gap-2 border-t border-border pt-3 sm:grid-cols-[minmax(0,1fr)_7rem_auto] sm:items-center">
      <Select value={type} onValueChange={setType}>
        <SelectTrigger className="h-9"><SelectValue /></SelectTrigger>
        <SelectContent>
          <SelectItem value="fixed">{ar ? "راتب شهري ثابت" : "Fixed monthly salary"}</SelectItem>
          <SelectItem value="percent">{ar ? "نسبة من صافي الربح" : "% of net profit"}</SelectItem>
        </SelectContent>
      </Select>
      {type === "percent" ? (
        <Input className="h-9" type="number" min={0} max={100} step="0.5" value={pct} onChange={(e) => setPct(e.target.value)} aria-label="%" />
      ) : (
        <span className="hidden sm:block" />
      )}
      <Button size="sm" variant="outline" disabled={save.isPending} onClick={() => save.mutate()}>
        {ar ? "حفظ نوع الراتب" : "Save"}
      </Button>
    </div>
  );
}
