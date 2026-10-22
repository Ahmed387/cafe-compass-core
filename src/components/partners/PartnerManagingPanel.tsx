import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Switch } from "@/components/ui/switch";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { formatMoney, formatPercent, friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { PartnerAccountLink } from "./PartnerAccountLink";
import { SalaryPayDateInput } from "@/components/finance/SalaryPayDateInput";
import { cafeToday, paySalaryOn, validPayDate } from "@/components/finance/pay-salary";
import { businessMonth, monthBounds as businessMonthBounds } from "@/core/finance/business-dates";

type SalaryRow = { user_id: string; base_salary: number; bonuses: number; penalties: number; advances: number; absence_deduction: number; net_pay: number };

function monthBounds() {
  return businessMonthBounds(businessMonth());
}

/** Equity card, managing-partner salary and combined settlement for one partner. */
export function PartnerManagingPanel({ partnerId, userId, partnerName = "" }: { partnerId: string; userId: string | null; partnerName?: string }) {
  const { lang } = useI18n();
  const ar = lang === "ar";
  const { me } = useAuth();
  const currency = me?.company?.currency ?? "EGP";
  const money = (v: number) => formatMoney(v, currency, lang);
  const qc = useQueryClient();
  const { start, end } = monthBounds();
  const [method, setMethod] = useState<"cash" | "bank">("cash");
  const [payDate, setPayDate] = useState(cafeToday());
  const [form, setForm] = useState({ salary: "", hire: "", job: "general_manager" });

  const superAdmin = useQuery({
    queryKey: ["is-super-admin"],
    queryFn: async () => Boolean((await supabase.rpc("is_super_admin")).data),
  });
  const isAdmin = superAdmin.data === true;

  const info = useQuery({
    queryKey: ["partner-managing", partnerId, start],
    queryFn: async () => {
      const [partner, own, profile] = await Promise.all([
        supabase.from("partners").select("is_managing_staff, dividends_paused").eq("id", partnerId).maybeSingle(),
        supabase.from("partner_ownership").select("total_contributions, ownership_percentage").eq("partner_id", partnerId).maybeSingle(),
        userId ? supabase.from("user_profiles").select("id, hire_date, job_title").eq("id", userId).maybeSingle() : Promise.resolve({ data: null }),
      ]);
      const profileId = (profile.data as { id: string } | null)?.id ?? null;
      let salaryRow = null as SalaryRow | null;
      let unpaidSalary: { id: string; net_amount: number } | null = null;
      if (profileId && partner.data?.is_managing_staff) {
        const [prev, sp] = await Promise.all([
          supabase.rpc("hr_payroll_preview", { _period_start: start, _period_end: end }),
          supabase.from("salary_payments").select("id, net_amount").eq("user_id", profileId).eq("status", "active").is("paid_at", null).order("period_start", { ascending: false }).limit(1),
        ]);
        salaryRow = ((prev.data ?? []) as unknown as SalaryRow[]).find((r) => r.user_id === profileId) ?? null;
        unpaidSalary = (sp.data ?? [])[0] ?? null;
      }
      // Latest payout with a dividend this partner hasn't received in cash yet
      const [dists, payouts, deds] = await Promise.all([
        supabase.from("profit_distributions").select("id, created_at, profit_distribution_lines(partner_id, amount)").eq("status", "active").order("created_at", { ascending: false }),
        supabase.from("partner_dividend_payouts").select("distribution_id").eq("partner_id", partnerId).eq("status", "active"),
        supabase.from("partner_ledger_transactions").select("reference_id, amount").eq("partner_id", partnerId).eq("reference_type", "partner_tab").eq("status", "active"),
      ]);
      const paid = new Set((payouts.data ?? []).map((p) => p.distribution_id));
      let dividend: { distribution_id: string; net: number } | null = null;
      for (const d of dists.data ?? []) {
        if (paid.has(d.id)) continue;
        const line = ((d.profit_distribution_lines ?? []) as Array<{ partner_id: string; amount: number }>).find((l) => l.partner_id === partnerId);
        if (!line) continue;
        const ded = -(deds.data ?? []).filter((x) => x.reference_id === d.id).reduce((s, x) => s + Number(x.amount), 0);
        dividend = { distribution_id: d.id, net: Number(line.amount) - ded };
        break;
      }
      return {
        managing: Boolean(partner.data?.is_managing_staff),
        capital: Number(own.data?.total_contributions ?? 0),
        equity: Number(own.data?.ownership_percentage ?? 0),
        paused: Boolean(partner.data?.dividends_paused),
        profile: profile.data as { id: string; hire_date: string | null; job_title: string | null } | null,
        salaryRow, unpaidSalary, dividend,
      };
    },
  });

  useEffect(() => {
    const d = info.data;
    if (d) setForm({ salary: String(d.salaryRow?.base_salary ?? ""), hire: d.profile?.hire_date ?? "", job: d.profile?.job_title || "general_manager" });
  }, [info.data]);

  const refresh = () => {
    qc.invalidateQueries({ queryKey: ["partner-managing", partnerId] });
    qc.invalidateQueries({ queryKey: ["partner-dividends", partnerId] });
    qc.invalidateQueries({ queryKey: ["partner-statement"] });
    qc.invalidateQueries({ queryKey: ["hr-preview"] });
  };

  const setManaging = useMutation({
    mutationFn: async (on: boolean) => {
      const { error } = await supabase.rpc("set_partner_managing", {
        _partner_id: partnerId, _on: on, _base_salary: Number(form.salary || 0),
        _hire_date: (form.hire || null) as unknown as string, _job_title: form.job,
      });
      if (error) throw error;
    },
    onSuccess: () => { toast.success(ar ? "تم الحفظ" : "Saved"); refresh(); },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  const pay = useMutation({
    mutationFn: async (kind: "salary" | "dividend" | "both") => {
      const d = info.data;
      if (!d) return;
      if (kind === "salary" && d.unpaidSalary) {
        if (!validPayDate(payDate, cafeToday())) throw new Error(ar ? "اختار تاريخ صرف صحيح ومش بعد النهارده" : "Pick a valid pay date, not in the future");
        await paySalaryOn(d.unpaidSalary.id, method, payDate);
      } else if (kind === "dividend" && d.dividend) {
        const { error } = await supabase.rpc("payout_partner_dividend", { _distribution_id: d.dividend.distribution_id, _partner_id: partnerId, _method: method });
        if (error) throw error;
      } else if (kind === "both" && d.dividend && d.unpaidSalary) {
        const { error } = await supabase.rpc("payout_partner_combined", {
          _distribution_id: d.dividend.distribution_id, _partner_id: partnerId, _salary_payment_id: d.unpaidSalary.id, _method: method,
        });
        if (error) throw error;
      }
    },
    onSuccess: () => { toast.success(ar ? "تم الصرف" : "Paid out"); refresh(); },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  const d = info.data;
  if (!d) return null;
  const salaryNet = d.unpaidSalary ? Number(d.unpaidSalary.net_amount) : Number(d.salaryRow?.net_pay ?? 0);
  const divNet = d.dividend?.net ?? 0;

  return (
    <div className="grid gap-3">
      <div className="grid gap-2 rounded-lg border border-border bg-card p-3 sm:grid-cols-3">
        <div><p className="text-xs text-muted-foreground">{ar ? "رأس المال المدفوع" : "Paid capital"}</p><p className="font-bold tabular-nums">{money(d.capital)}</p></div>
        <div><p className="text-xs text-muted-foreground">{ar ? "نسبة الشراكة" : "Equity"}</p><p className="font-bold tabular-nums">{formatPercent(d.equity, lang)}</p></div>
        <div><p className="text-xs text-muted-foreground">{ar ? "حالة التوزيع" : "Dividend status"}</p>
          {d.paused ? <Badge variant="outline" className="border-sky-400/60 text-sky-700 dark:text-sky-300">{ar ? "أرباحه متوقفة" : "Dividends paused"}</Badge> : <Badge variant="secondary">{ar ? "نشط" : "Active"}</Badge>}
        </div>
      </div>

      <div className="grid gap-3 rounded-lg border border-border bg-card p-3">
        <div className="flex items-center justify-between gap-2">
          <p className="text-sm font-semibold">{ar ? "الراتب الإداري (شريك مدير)" : "Managerial salary (managing partner)"}</p>
          {isAdmin && (
            <label className="flex items-center gap-2 text-xs">
              {ar ? "تعيين الشريك كمدير تشغيلي / موظف" : "Assign as managing staff"}
              <Switch checked={d.managing} disabled={setManaging.isPending || !userId} onCheckedChange={(on) => setManaging.mutate(on)} />
            </label>
          )}
        </div>
        {!userId && <p className="text-xs text-muted-foreground">{ar ? "يجب إنشاء حساب دخول للشريك أولاً." : "Create a login account for this partner first."}</p>}
        {!userId && isAdmin && <PartnerAccountLink partnerId={partnerId} partnerName={partnerName} />}
        {d.managing && (
          <>
            {isAdmin && (
              <div className="grid gap-2 sm:grid-cols-3">
                <div className="space-y-1"><Label className="text-xs">{ar ? "المسمى" : "Title"}</Label>
                  <Select value={form.job} onValueChange={(v) => setForm({ ...form, job: v })}>
                    <SelectTrigger><SelectValue /></SelectTrigger>
                    <SelectContent>
                      <SelectItem value="general_manager">{ar ? "شريك مدير / مدير تشغيلي" : "Managing partner / GM"}</SelectItem>
                      <SelectItem value="manager">{ar ? "مشرف" : "Supervisor"}</SelectItem>
                    </SelectContent>
                  </Select>
                </div>
                <div className="space-y-1"><Label className="text-xs">{ar ? "الراتب الأساسي" : "Base salary"}</Label><Input type="number" min="0" value={form.salary} onChange={(e) => setForm({ ...form, salary: e.target.value })} /></div>
                <div className="space-y-1"><Label className="text-xs">{ar ? "تاريخ التعيين" : "Hire date"}</Label><Input type="date" value={form.hire} onChange={(e) => setForm({ ...form, hire: e.target.value })} /></div>
                <Button size="sm" variant="outline" className="sm:col-span-3" disabled={setManaging.isPending} onClick={() => setManaging.mutate(true)}>💾 {ar ? "حفظ بيانات الراتب" : "Save salary data"}</Button>
              </div>
            )}
            {d.salaryRow && (
              <div className="space-y-1 rounded-md bg-muted p-2 text-sm">
                <div className="flex justify-between"><span>{ar ? "الراتب الأساسي" : "Base"}</span><span className="tabular-nums">{money(Number(d.salaryRow.base_salary))}</span></div>
                <div className="flex justify-between text-primary"><span>+ {ar ? "مكافآت" : "Bonuses"}</span><span className="tabular-nums">{money(Number(d.salaryRow.bonuses))}</span></div>
                <div className="flex justify-between text-destructive"><span>− {ar ? "جزاءات وسلف" : "Penalties & advances"}</span><span className="tabular-nums">{money(Number(d.salaryRow.penalties) + Number(d.salaryRow.advances) + Number(d.salaryRow.absence_deduction))}</span></div>
                <div className="flex justify-between border-t border-border pt-1 font-bold"><span>{ar ? "صافي الراتب المستحق" : "Net salary due"}</span><span className="tabular-nums">{money(Number(d.salaryRow.net_pay))}</span></div>
              </div>
            )}
            <p className="text-xs text-muted-foreground">{ar ? "الراتب يُحسب كمصروف تشغيلي قبل صافي الربح، ويظهر الشريك في الموارد البشرية." : "Salary counts as an operating cost before net profit; the partner now appears in HR."}</p>
          </>
        )}
      </div>

      <div className="grid gap-2 rounded-lg border border-primary/40 bg-primary/5 p-3">
        <p className="text-sm font-semibold">{ar ? "التصفية الإجمالية والصرف" : "Combined settlement"}</p>
        <div className="flex justify-between text-sm"><span>{ar ? "صافي حصة الأرباح" : "Net dividend"}</span><span className="tabular-nums">{money(divNet)}</span></div>
        {d.managing && <div className="flex justify-between text-sm"><span>{ar ? "صافي الراتب الإداري" : "Net salary"}</span><span className="tabular-nums">{money(salaryNet)}</span></div>}
        <div className="flex justify-between border-t border-border pt-1 font-bold"><span>{ar ? "إجمالي المستحق للشريك" : "Grand total"}</span><span className="tabular-nums">{money(divNet + (d.managing ? salaryNet : 0))}</span></div>
        {d.managing && !d.unpaidSalary && <p className="text-xs text-muted-foreground">{ar ? "لصرف الراتب أصدر رواتب الشهر أولاً من صفحة الموارد البشرية." : "Generate the month's payroll in HR before paying the salary."}</p>}
        {isAdmin && (
          <div className="flex flex-wrap items-center gap-2">
            <Select value={method} onValueChange={(v) => setMethod(v as "cash" | "bank")}>
              <SelectTrigger className="h-8 w-44"><SelectValue /></SelectTrigger>
              <SelectContent>
                <SelectItem value="cash">{ar ? "نقداً من الخزينة" : "Cash from treasury"}</SelectItem>
                <SelectItem value="bank">{ar ? "تحويل بنكي / إنستاباي" : "Bank / InstaPay"}</SelectItem>
              </SelectContent>
            </Select>
            {d.managing && <SalaryPayDateInput value={payDate} onChange={setPayDate} lang={lang} id={`pay-date-${partnerId}`} />}
            {d.managing && <Button size="sm" variant="outline" disabled={!d.unpaidSalary || pay.isPending} onClick={() => pay.mutate("salary")}>💰 {ar ? "صرف الراتب" : "Pay salary"}</Button>}
            <Button size="sm" variant="outline" disabled={!d.dividend || pay.isPending} onClick={() => pay.mutate("dividend")}>💰 {ar ? "صرف الأرباح" : "Pay dividend"}</Button>
            {d.managing && <Button size="sm" disabled={!d.dividend || !d.unpaidSalary || pay.isPending} onClick={() => pay.mutate("both")}>💰 {ar ? "صرف الإجمالي معاً" : "Pay both"}</Button>}
          </div>
        )}
      </div>
    </div>
  );
}
