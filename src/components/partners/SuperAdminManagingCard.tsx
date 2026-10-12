import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Switch } from "@/components/ui/switch";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { formatMoney, friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";

/** Super Admin switch: act as salaried General Manager (shows in HR) or pure owner (hidden). */
export function SuperAdminManagingCard() {
  const { lang } = useI18n();
  const ar = lang === "ar";
  const { me } = useAuth();
  const qc = useQueryClient();
  const [method, setMethod] = useState<"cash" | "bank">("cash");
  const [form, setForm] = useState({ salary: "", hire: "", job: "general_manager" });

  const info = useQuery({
    queryKey: ["super-admin-managing"],
    queryFn: async () => {
      const { data: pid } = await supabase.rpc("current_profile_id");
      const profileId = pid as string | null;
      if (!profileId) return null;
      const [profile, salary, unpaid] = await Promise.all([
        supabase.from("user_profiles").select("id, is_managing_staff, hire_date, job_title").eq("id", profileId).maybeSingle(),
        supabase.from("employee_salaries").select("base_salary").eq("user_id", profileId).eq("is_active", true).order("effective_from", { ascending: false }).limit(1),
        supabase.from("salary_payments").select("id, net_amount").eq("user_id", profileId).eq("status", "active").is("paid_at", null).order("period_start", { ascending: false }).limit(1),
      ]);
      return {
        profile: profile.data,
        base: Number(salary.data?.[0]?.base_salary ?? 0),
        unpaid: unpaid.data?.[0] ?? null,
      };
    },
  });

  useEffect(() => {
    const d = info.data;
    if (d?.profile) setForm({ salary: d.base ? String(d.base) : "", hire: d.profile.hire_date ?? "", job: d.profile.job_title || "general_manager" });
  }, [info.data]);

  const refresh = () => {
    qc.invalidateQueries({ queryKey: ["super-admin-managing"] });
    qc.invalidateQueries({ queryKey: ["hr-preview"] });
  };

  const save = useMutation({
    mutationFn: async (on: boolean) => {
      const { error } = await supabase.rpc("set_super_admin_managing", {
        _on: on,
        _base_salary: Number(form.salary || 0),
        _hire_date: (form.hire || null) as unknown as string,
        _job_title: form.job,
      });
      if (error) throw error;
    },
    onSuccess: () => { toast.success(ar ? "تم الحفظ" : "Saved"); refresh(); },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  const pay = useMutation({
    mutationFn: async () => {
      if (!info.data?.unpaid) return;
      const { error } = await supabase.rpc("pay_salary", { _salary_id: info.data.unpaid.id, _method: method });
      if (error) throw error;
    },
    onSuccess: () => { toast.success(ar ? "تم الصرف" : "Paid out"); refresh(); },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  const d = info.data;
  if (!d?.profile) return null;
  const on = Boolean(d.profile.is_managing_staff);
  const currency = me?.company?.currency ?? "EGP";

  return (
    <Card className="mb-4">
      <CardHeader className="flex flex-row items-center justify-between gap-2 space-y-0">
        <CardTitle className="text-base">{ar ? "السوبر أدمن كمدير عام / تشغيلي" : "Super Admin as General Manager"}</CardTitle>
        <label className="flex items-center gap-2 text-xs">
          {ar ? "تعيين السوبر أدمن كمدير عام / تشغيلي" : "Assign as General Manager"}
          <Switch checked={on} disabled={save.isPending} onCheckedChange={(v) => save.mutate(v)} />
        </label>
      </CardHeader>
      <CardContent className="grid gap-3">
        {!on && <p className="text-xs text-muted-foreground">{ar ? "مالك / مستثمر فقط — لا يظهر في قائمة الموظفين." : "Owner / investor only — hidden from the staff list."}</p>}
        {on && (
          <>
            <div className="grid gap-2 sm:grid-cols-4">
              <div className="space-y-1"><Label className="text-xs">{ar ? "المسمى" : "Title"}</Label>
                <Select value={form.job} onValueChange={(v) => setForm({ ...form, job: v })}>
                  <SelectTrigger><SelectValue /></SelectTrigger>
                  <SelectContent>
                    <SelectItem value="general_manager">{ar ? "مدير عام / General Manager" : "General Manager"}</SelectItem>
                    <SelectItem value="manager">{ar ? "مدير تشغيلي" : "Operations manager"}</SelectItem>
                  </SelectContent>
                </Select>
              </div>
              <div className="space-y-1"><Label className="text-xs">{ar ? "الراتب الأساسي الشهري" : "Base monthly salary"}</Label><Input type="number" min="0" value={form.salary} onChange={(e) => setForm({ ...form, salary: e.target.value })} /></div>
              <div className="space-y-1"><Label className="text-xs">{ar ? "تاريخ التعيين" : "Hire date"}</Label><Input type="date" value={form.hire} onChange={(e) => setForm({ ...form, hire: e.target.value })} /></div>
              <div className="flex items-end"><Button size="sm" variant="outline" className="w-full" disabled={save.isPending} onClick={() => save.mutate(true)}>💾 {ar ? "حفظ" : "Save"}</Button></div>
            </div>
            <p className="text-xs text-muted-foreground">{ar ? "الراتب يُحسب كمصروف تشغيلي قبل صافي الربح، ويظهر في الموارد البشرية." : "Salary counts as an operating cost before net profit and appears in HR."}</p>
            <div className="flex flex-wrap items-center gap-2 rounded-md bg-muted p-2">
              <span className="text-sm">{ar ? "راتب مستحق غير مصروف:" : "Unpaid salary:"} <b className="tabular-nums">{formatMoney(Number(d.unpaid?.net_amount ?? 0), currency, lang)}</b></span>
              <Select value={method} onValueChange={(v) => setMethod(v as "cash" | "bank")}>
                <SelectTrigger className="h-8 w-44"><SelectValue /></SelectTrigger>
                <SelectContent>
                  <SelectItem value="cash">{ar ? "نقداً من الخزينة" : "Cash from treasury"}</SelectItem>
                  <SelectItem value="bank">{ar ? "تحويل بنكي / إنستاباي" : "Bank / InstaPay"}</SelectItem>
                </SelectContent>
              </Select>
              <Button size="sm" disabled={!d.unpaid || pay.isPending} onClick={() => pay.mutate()}>💰 {ar ? "صرف الراتب" : "Pay salary"}</Button>
              {!d.unpaid && <span className="text-xs text-muted-foreground">{ar ? "أصدر رواتب الشهر من الموارد البشرية أولاً." : "Generate payroll in HR first."}</span>}
            </div>
          </>
        )}
      </CardContent>
    </Card>
  );
}
