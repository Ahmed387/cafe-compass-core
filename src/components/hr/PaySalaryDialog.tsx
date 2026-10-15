import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import type { HrRow } from "@/components/hr/EmployeeDrawer";
import { supabase } from "@/integrations/supabase/client";
import { formatMoney, friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";

const METHODS = [
  { key: "cash", ar: "كاش من الخزنة", en: "Cash (drawer safe)" },
  { key: "instapay", ar: "إنستاباي / محفظة", en: "InstaPay / wallet" },
  { key: "bank", ar: "تحويل بنكي", en: "Bank transfer" },
] as const;

const todayIso = () => new Date().toLocaleDateString("en-CA", { timeZone: "Africa/Cairo" });

/**
 * Pays one employee's salary for the selected month in a single step: the line
 * shown in the table is issued (penalties + advances recovered) and paid on the
 * chosen date. Replaces the old team-wide "generate payroll" step.
 */
/** A salary line already issued (old "run payroll" step) but not yet paid. */
export type IssuedSalary = {
  id: string;
  user_id: string;
  period_start: string;
  period_end: string;
  base_amount: number;
  bonus: number;
  absence_deduction: number | null;
  penalty_deduction: number | null;
  advance_deduction: number | null;
  net_amount: number;
  paid_at: string | null;
};

export function PaySalaryDialog({
  row,
  issued,
  start,
  end,
  currency,
  onClose,
}: {
  row: HrRow | null;
  /** When set, this exact issued line is paid with its own numbers. */
  issued?: IssuedSalary | null;
  start: string;
  end: string;
  currency: string;
  onClose: () => void;
}) {
  const { lang } = useI18n();
  const ar = lang === "ar";
  const qc = useQueryClient();
  const [payDate, setPayDate] = useState(todayIso);
  const [method, setMethod] = useState<(typeof METHODS)[number]["key"]>("cash");
  const money = (v: number | string) => formatMoney(Number(v), currency, lang);

  const pay = useMutation({
    mutationFn: async () => {
      if (!row) return;
      const { error } = await supabase.rpc(
        "pay_employee_salary" as never,
        {
          _user_id: row.user_id,
          _period_start: start,
          _period_end: end,
          _pay_date: payDate,
          _method: method,
        } as never,
      );
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success(
        ar ? "تم صرف المرتب وخصم السلف والجزاءات" : "Salary paid; advances and penalties deducted",
      );
      qc.invalidateQueries({ queryKey: ["hr-preview"] });
      qc.invalidateQueries({ queryKey: ["salary-payments"] });
      qc.invalidateQueries({ queryKey: ["treasury"] });
      onClose();
    },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  if (!row) return null;
  const n = (v: unknown) => Number(v ?? 0);
  const net = issued ? n(issued.net_amount) : n(row.net_pay);
  const lines: Array<{ label: string; value: number; sign: "+" | "-" }> = issued
    ? [
        { label: ar ? "المرتب المستحق" : "Salary", value: n(issued.base_amount), sign: "+" },
        { label: ar ? "مكافآت" : "Bonuses", value: n(issued.bonus), sign: "+" },
        { label: ar ? "غياب" : "Absence", value: n(issued.absence_deduction), sign: "-" },
        { label: ar ? "جزاءات" : "Penalties", value: n(issued.penalty_deduction), sign: "-" },
        { label: ar ? "سلف" : "Advances", value: n(issued.advance_deduction), sign: "-" },
      ]
    : [
        {
          label: ar ? "المرتب المستحق عن الشهر" : "Salary for the month",
          value: Number(row.prorated_salary),
          sign: "+",
        },
        { label: ar ? "مكافآت" : "Bonuses", value: Number(row.bonuses), sign: "+" },
        {
          label: ar ? `غياب (${row.absent_days} يوم)` : `Absence (${row.absent_days} days)`,
          value: Number(row.absence_deduction),
          sign: "-",
        },
        { label: ar ? "جزاءات" : "Penalties", value: Number(row.penalties), sign: "-" },
        { label: ar ? "سلف" : "Advances", value: Number(row.advances), sign: "-" },
      ];
  const fromDay = issued?.period_start ?? start;
  const toDay = issued?.period_end ?? end;

  return (
    <Dialog open={Boolean(row)} onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>
            {ar ? `صرف مرتب ${row.employee_name}` : `Pay ${row.employee_name}`}
          </DialogTitle>
          <DialogDescription>
            {ar ? `عن الفترة ${fromDay} → ${toDay}` : `For ${fromDay} → ${toDay}`}
            {issued &&
              (ar
                ? " — المرتب ده متسجل قبل كده ولسه متصرفش، هيتصرف بنفس أرقامه."
                : " — already issued but unpaid; it is paid with its own figures.")}
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-1.5 rounded-xl border border-border p-3 text-sm">
          {lines
            .filter((l) => l.value > 0 || l.sign === "+")
            .map((l) => (
              <div key={l.label} className="flex justify-between gap-3">
                <span className="text-muted-foreground">{l.label}</span>
                <span className={l.sign === "-" ? "tabular-nums text-destructive" : "tabular-nums"}>
                  {l.sign === "-" ? "−" : ""}
                  {money(l.value)}
                </span>
              </div>
            ))}
          <div className="mt-2 flex justify-between border-t border-border pt-2 font-bold">
            <span>{ar ? "الصافي اللي هيتصرف" : "Net to pay"}</span>
            <span className="tabular-nums text-primary">{money(net)}</span>
          </div>
          {!issued && Number(row.carried_forward) > 0 && (
            <p className="pt-1 text-xs text-amber-600">
              {ar
                ? `فاضل ${money(row.carried_forward)} سلف/جزاءات أكبر من المرتب — هتتخصم من الشهر الجاي تلقائياً.`
                : `${money(row.carried_forward)} of advances/penalties exceeds this pay and moves to next month automatically.`}
            </p>
          )}
        </div>

        <div className="grid grid-cols-2 gap-3">
          <div className="space-y-1">
            <Label>{ar ? "تاريخ الصرف" : "Pay date"}</Label>
            <Input
              type="date"
              value={payDate}
              onChange={(e) => e.target.value && setPayDate(e.target.value)}
            />
          </div>
          <div className="space-y-1">
            <Label>{ar ? "يتصرف من" : "Paid from"}</Label>
            <select
              className="h-9 w-full rounded-md border border-input bg-background px-2 text-sm"
              value={method}
              onChange={(e) => setMethod(e.target.value as typeof method)}
            >
              {METHODS.map((m) => (
                <option key={m.key} value={m.key}>
                  {ar ? m.ar : m.en}
                </option>
              ))}
            </select>
          </div>
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            {ar ? "إلغاء" : "Cancel"}
          </Button>
          <Button onClick={() => pay.mutate()} disabled={pay.isPending}>
            {ar ? `صرف ${money(net)}` : `Pay ${money(net)}`}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
