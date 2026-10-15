import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Pencil } from "lucide-react";
import { useEffect, useState } from "react";
import { toast } from "sonner";

import { JOB_TITLES } from "@/components/hr/EmployeeDrawer";
import { businessToday } from "@/core/finance/business-dates";
import { StaffAdjustmentsPanel } from "@/components/hr/StaffAdjustmentsPanel";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Switch } from "@/components/ui/switch";
import { supabase } from "@/integrations/supabase/client";
import { setUserActive, setUserEmail } from "@/lib/admin.functions";
import { useAuth } from "@/lib/auth";
import { friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";

type Form = {
  first_name: string; last_name: string; email: string; phone: string; employee_code: string;
  job_title: string; hire_date: string; salary: string; is_active: boolean; role_ids: string[];
};

/** Full edit of an employee: profile fields, salary, status and roles — all persisted via audited RPCs. */
export function EmployeeEditDialog({
  userId,
  isSelf,
  showLabel = false,
}: {
  userId: string;
  isSelf: boolean;
  /** Show the word "Edit" next to the icon (profile header). */
  showLabel?: boolean;
}) {
  const { t, lang } = useI18n();
  const ar = lang === "ar";
  const { can, me } = useAuth();
  const isSuperAdmin = Boolean(me?.isRoot || me?.roleNames.includes("Super Admin"));
  const qc = useQueryClient();
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState<Form | null>(null);
  const canSalary = can("payroll.view");
  const canRoles = can("users.manage_roles");

  const canAdjustPay = isSuperAdmin || can("payroll.manage");
  // Was this month's salary already issued for them? Then a new bonus rolls to next month.
  const monthIssued = useQuery({
    queryKey: ["employee-month-issued", userId],
    enabled: Boolean(userId) && canAdjustPay,
    queryFn: async () => {
      const today = businessToday();
      const { data, error } = await supabase
        .from("salary_payments")
        .select("id")
        .eq("user_id", userId!)
        .eq("status", "active")
        .lte("period_start", today)
        .gte("period_end", today)
        .limit(1);
      if (error) throw error;
      return (data ?? []).length > 0;
    },
  });
  const detail = useQuery({
    queryKey: ["employee-edit", userId],
    enabled: open,
    queryFn: async () => {
      const [p, s, r] = await Promise.all([
        supabase.from("user_profiles").select("first_name, last_name, email, phone, employee_code, job_title, hire_date, is_active, user_roles(role_id)").eq("id", userId).maybeSingle(),
        supabase.from("employee_salaries").select("base_salary").eq("user_id", userId).eq("is_active", true).order("effective_from", { ascending: false }).limit(1).maybeSingle(),
        supabase.from("roles").select("id, name").order("name"),
      ]);
      if (p.error) throw p.error;
      return { profile: p.data, salary: s.data?.base_salary ?? null, roles: r.data ?? [] };
    },
  });

  useEffect(() => {
    const p = detail.data?.profile;
    if (!open || !p) return;
    setForm({
      first_name: p.first_name ?? "", last_name: p.last_name ?? "", email: p.email ?? "", phone: p.phone ?? "",
      employee_code: p.employee_code ?? "", job_title: p.job_title ?? "", hire_date: p.hire_date ?? "",
      salary: detail.data?.salary != null ? String(detail.data.salary) : "",
      is_active: p.is_active, role_ids: (p.user_roles ?? []).map((x) => x.role_id),
    });
  }, [open, detail.data]);

  const save = useMutation({
    mutationFn: async () => {
      if (!form || !detail.data?.profile) return;
      const { error } = await supabase.rpc("admin_update_employee", {
        _user_id: userId,
        _first_name: form.first_name.trim(),
        _last_name: form.last_name.trim(),
        _display_name: "",
        _phone: form.phone.trim(),
        _employee_code: form.employee_code.trim(),
        _job_title: (form.job_title || null) as unknown as string,
        _base_salary: (canSalary && form.salary !== "" ? Number(form.salary) : null) as unknown as number,
        _hire_date: (form.hire_date || null) as unknown as string,
      });
      if (error) throw error;
      const newEmail = form.email.trim().toLowerCase();
      if (isSuperAdmin && newEmail && newEmail !== (detail.data.profile.email ?? "").toLowerCase()) {
        await setUserEmail({ data: { user_id: userId, email: newEmail } });
      }
      if (canRoles) {
        const { error: rErr } = await supabase.rpc("set_user_roles", { _user_id: userId, _role_ids: form.role_ids });
        if (rErr) throw rErr;
      }
      if (!isSelf && can("users.disable") && form.is_active !== detail.data.profile.is_active) {
        await setUserActive({ data: { user_id: userId, is_active: form.is_active } });
      }
    },
    onSuccess: () => {
      toast.success(ar ? "تم حفظ بيانات الموظف" : "Employee saved");
      ["users", "hr-preview", "staff", "employee-edit"].forEach((k) => qc.invalidateQueries({ queryKey: [k] }));
      setOpen(false);
    },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  const roleLabel = (name: string) => { const k = `role.${name}`; const l = t(k); return l === k ? name : l; };
  const set = (patch: Partial<Form>) => setForm((f) => (f ? { ...f, ...patch } : f));

  return (
    <>
      <Button size="sm" variant="outline" onClick={() => setOpen(true)} aria-label={ar ? "تعديل" : "Edit"}>
        <Pencil className="size-4" />
        {showLabel && (ar ? "تعديل البيانات" : "Edit details")}
      </Button>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="max-h-[85vh] overflow-y-auto" dir={ar ? "rtl" : "ltr"}>
          <DialogHeader><DialogTitle>{ar ? "تعديل بيانات الموظف" : "Edit employee"}</DialogTitle></DialogHeader>
          {!form ? (
            <p className="text-sm text-muted-foreground">{t("common.loading")}</p>
          ) : (
            <div className="space-y-3">
              <div className="grid gap-3 sm:grid-cols-2">
                <Field label={ar ? "الاسم الأول" : "First name"}><Input maxLength={80} value={form.first_name} onChange={(e) => set({ first_name: e.target.value })} /></Field>
                <Field label={ar ? "اسم العائلة" : "Last name"}><Input maxLength={80} value={form.last_name} onChange={(e) => set({ last_name: e.target.value })} /></Field>
                {isSuperAdmin && (
                  <Field label={ar ? "الإيميل (للدخول)" : "Email (sign-in)"}>
                    <Input type="email" dir="ltr" maxLength={120} value={form.email} onChange={(e) => set({ email: e.target.value })} />
                  </Field>
                )}
                <Field label={ar ? "الهاتف" : "Phone"}><Input maxLength={30} value={form.phone} onChange={(e) => set({ phone: e.target.value })} /></Field>
                <Field label={ar ? "كود الموظف" : "Employee code"}><Input maxLength={30} value={form.employee_code} onChange={(e) => set({ employee_code: e.target.value })} /></Field>
                <Field label={ar ? "المسمى الوظيفي" : "Job title"}>
                  <Select value={form.job_title} onValueChange={(v) => set({ job_title: v })}>
                    <SelectTrigger><SelectValue placeholder="—" /></SelectTrigger>
                    <SelectContent>{Object.entries(JOB_TITLES).map(([k, v]) => <SelectItem key={k} value={k}>{ar ? v.ar : v.en}</SelectItem>)}</SelectContent>
                  </Select>
                </Field>
                <Field label={ar ? "تاريخ التعيين" : "Hire date"}><Input type="date" value={form.hire_date} onChange={(e) => set({ hire_date: e.target.value })} /></Field>
                {canSalary && <Field label={ar ? "الراتب الأساسي" : "Base salary"}><Input type="number" min="0" value={form.salary} onChange={(e) => set({ salary: e.target.value })} /></Field>}
              </div>
              {!isSelf && can("users.disable") && (
                <label className="flex items-center justify-between rounded-xl border border-border p-3 text-sm">
                  <span className="font-medium">{ar ? "الحساب نشط" : "Account active"}</span>
                  <Switch checked={form.is_active} onCheckedChange={(v) => set({ is_active: v })} />
                </label>
              )}
              {canAdjustPay && (
                <div className="space-y-2">
                  <Label>{ar ? "مكافآت وخصومات" : "Bonuses & penalties"}</Label>
                  <StaffAdjustmentsPanel
                    key={userId}
                    staffId={userId}
                    canBonus={canAdjustPay}
                    canPenalty={isSuperAdmin}
                    monthIssued={monthIssued.data === true}
                  />
                </div>
              )}
              {canRoles && (
                <div className="space-y-2">
                  <Label>{t("users.roles")}</Label>
                  <div className="grid gap-2 sm:grid-cols-2">
                    {(detail.data?.roles ?? []).map((role) => (
                      <label key={role.id} className="flex items-center gap-2 rounded-md border border-border/60 p-2 text-sm">
                        <Checkbox checked={form.role_ids.includes(role.id)} onCheckedChange={(v) => set({ role_ids: v === true ? [...form.role_ids, role.id] : form.role_ids.filter((id) => id !== role.id) })} />
                        {roleLabel(role.name)}
                      </label>
                    ))}
                  </div>
                </div>
              )}
            </div>
          )}
          <DialogFooter>
            <Button variant="outline" onClick={() => setOpen(false)}>{t("common.cancel")}</Button>
            <Button disabled={!form?.first_name.trim() || save.isPending} onClick={() => save.mutate()}>{ar ? "حفظ" : "Save"}</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return <div className="space-y-1"><Label>{label}</Label>{children}</div>;
}
