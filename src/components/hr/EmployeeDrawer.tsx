import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { businessToday } from "@/core/finance/business-dates";
import { StaffAdjustmentsPanel } from "@/components/hr/StaffAdjustmentsPanel";
import { Sheet, SheetContent, SheetFooter, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { supabase } from "@/integrations/supabase/client";
import { formatMoney, friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";

export type HrRow = {
  user_id: string;
  employee_name: string;
  job_title: string | null;
  hire_date: string | null;
  base_salary: number;
  prorated_salary: number;
  worked_days: number;
  worked_hours: number;
  shifts_count: number;
  absent_days: number;
  absence_deduction: number;
  penalties: number;
  bonuses: number;
  advances: number;
  /** Unrecovered penalties / advances owed in total (deducted this month shown in penalties / advances). */
  penalties_due: number;
  advances_due: number;
  /** Owed amount that rolls to next month because this month's pay can't cover it. */
  carried_forward: number;
  net_pay: number;
  already_generated: boolean;
};

export const JOB_TITLES: Record<string, { ar: string; en: string }> = {
  cashier: { ar: "كاشير", en: "Cashier" },
  barista: { ar: "باريستا", en: "Barista" },
  floor_staff: { ar: "خدمة صالة", en: "Floor Staff" },
  manager: { ar: "مدير", en: "Manager" },
  general_manager: { ar: "شريك مدير / مدير تشغيلي", en: "Managing partner / GM" },
};

export function EmployeeDrawer({
  row, onClose, editable, canBonus = false, currency, periodEnd,
}: { row: HrRow | null; onClose: () => void; editable: boolean; canBonus?: boolean; currency: string; periodEnd: string }) {
  const { lang } = useI18n();
  const ar = lang === "ar";
  const qc = useQueryClient();
  const money = (v: number) => formatMoney(Number(v), currency, lang);
  const [form, setForm] = useState({ name: "", job: "", salary: "", hire: "" });

  // Reset the form only when a different employee is opened — not on every
  // background refetch, which would wipe what the user is typing.
  const rowId = row?.user_id;
  useEffect(() => {
    if (row) setForm({ name: row.employee_name ?? "", job: row.job_title ?? "", salary: String(row.base_salary ?? 0), hire: row.hire_date ?? "" });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rowId]);

  const refresh = () => qc.invalidateQueries({ queryKey: ["hr-preview"] });
  const pastMonth = periodEnd < businessToday();

  const save = useMutation({
    mutationFn: async () => {
      if (!row) return;
      const { error } = await supabase.rpc("update_employee_profile", {
        _user_id: row.user_id,
        _name: form.name.trim(),
        _job_title: (form.job || null) as unknown as string,
        _base_salary: Number(form.salary || 0),
        _hire_date: (form.hire || null) as unknown as string,
      });
      if (error) throw error;
    },
    onSuccess: () => { toast.success(ar ? "تم حفظ بيانات الموظف" : "Employee saved"); refresh(); onClose(); },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  const ro = !editable;
  return (
    <Sheet open={!!row} onOpenChange={(o) => !o && onClose()}>
      <SheetContent side={ar ? "left" : "right"} className="w-full overflow-y-auto sm:max-w-md" dir={ar ? "rtl" : "ltr"}>
        <SheetHeader className="text-start">
          <SheetTitle>{row?.employee_name}</SheetTitle>
        </SheetHeader>
        {row && (
          <div className="mt-4 space-y-4">
            <div className="space-y-1">
              <Label>{ar ? "تعديل اسم الموظف" : "Employee name"}</Label>
              <Input value={form.name} disabled={ro} onChange={(e) => setForm({ ...form, name: e.target.value })} />
            </div>
            <div className="space-y-1">
              <Label>{ar ? "المسمى الوظيفي" : "Job title"}</Label>
              <Select value={form.job} disabled={ro} onValueChange={(v) => setForm({ ...form, job: v })}>
                <SelectTrigger><SelectValue placeholder="—" /></SelectTrigger>
                <SelectContent>
                  {Object.entries(JOB_TITLES).map(([k, v]) => <SelectItem key={k} value={k}>{ar ? v.ar : v.en}</SelectItem>)}
                </SelectContent>
              </Select>
            </div>
            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-1">
                <Label>{ar ? "الراتب الأساسي" : "Base salary"}</Label>
                <Input type="number" min="0" value={form.salary} disabled={ro} onChange={(e) => setForm({ ...form, salary: e.target.value })} />
              </div>
              <div className="space-y-1">
                <Label>{ar ? "تاريخ التعيين" : "Hire date"}</Label>
                <Input type="date" value={form.hire} disabled={ro} onChange={(e) => setForm({ ...form, hire: e.target.value })} />
              </div>
            </div>

            <div className="grid grid-cols-3 gap-2 rounded-lg border border-border p-3 text-center text-sm">
              <div><p className="text-xs text-muted-foreground">{ar ? "ورديات" : "Shifts"}</p><p className="font-bold">{row.shifts_count}</p></div>
              <div><p className="text-xs text-muted-foreground">{ar ? "أيام" : "Days"}</p><p className="font-bold">{row.worked_days}</p></div>
              <div><p className="text-xs text-muted-foreground">{ar ? "ساعات" : "Hours"}</p><p className="font-bold">{Number(row.worked_hours).toFixed(1)}</p></div>
            </div>

            <StaffAdjustmentsPanel
              key={row.user_id}
              staffId={row.user_id}
              canBonus={editable || canBonus}
              canPenalty={editable}
              bonusDate={pastMonth ? periodEnd : undefined}
              monthIssued={row.already_generated}
            />

            <div className="space-y-1 rounded-lg bg-muted p-3 text-sm">
              <div className="flex justify-between"><span>{ar ? "الراتب النسبي" : "Prorated salary"}</span><span className="tabular-nums">{money(row.prorated_salary)}</span></div>
              <div className="flex justify-between text-primary"><span>+ {ar ? "مكافآت" : "Bonuses"}</span><span className="tabular-nums">{money(row.bonuses)}</span></div>
              <div className="flex justify-between text-destructive"><span>− {ar ? "جزاءات وغياب" : "Penalties & absence"}</span><span className="tabular-nums">{money(Number(row.penalties) + Number(row.absence_deduction))}</span></div>
              <div className="flex justify-between text-destructive"><span>− {ar ? "سلف" : "Advances"}</span><span className="tabular-nums">{money(row.advances)}</span></div>
              <div className="flex justify-between border-t border-border pt-1 font-bold"><span>{ar ? "صافي المستحق" : "Net payable"}</span><span className="tabular-nums">{money(row.net_pay)}</span></div>
            </div>
          </div>
        )}
        {editable && (
          <SheetFooter className="mt-4">
            <Button className="w-full" disabled={!form.name.trim() || save.isPending} onClick={() => save.mutate()}>
              {ar ? "تحديث وحفظ بيانات الموظف" : "Save employee data"}
            </Button>
          </SheetFooter>
        )}
      </SheetContent>
    </Sheet>
  );
}
