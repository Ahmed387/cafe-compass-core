import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Gavel, Gift } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { supabase } from "@/integrations/supabase/client";
import { friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";

/**
 * Bonus & penalty entry for one employee. Works for every employee, whether or
 * not this month's payroll was already issued: a bonus for a month that is
 * already paid is dated today, so it lands in the next payroll; penalties are
 * always carried until they are recovered.
 */
export function StaffAdjustmentsPanel({
  staffId,
  canBonus,
  canPenalty,
  bonusDate,
  monthIssued = false,
}: {
  staffId: string;
  canBonus: boolean;
  canPenalty: boolean;
  /** Date to stamp the bonus with (e.g. last day of a past month). Defaults to today. */
  bonusDate?: string | undefined;
  /** The selected month's payroll is already issued for this employee. */
  monthIssued?: boolean;
}) {
  const { lang } = useI18n();
  const ar = lang === "ar";
  const qc = useQueryClient();
  const [bonus, setBonus] = useState({ amount: "", reason: "" });
  const [pen, setPen] = useState({ amount: "", reason: "" });

  const refresh = () => {
    ["hr-preview", "hr-pending-penalties", "staff-penalties", "users"].forEach((k) =>
      qc.invalidateQueries({ queryKey: [k] }),
    );
  };

  const addBonus = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc("add_staff_bonus", {
        _staff_id: staffId,
        _amount: Number(bonus.amount),
        _reason: bonus.reason.trim(),
        ...(bonusDate && !monthIssued ? { _bonus_date: bonusDate } : {}),
      });
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success(ar ? "تمت إضافة المكافأة" : "Bonus added");
      setBonus({ amount: "", reason: "" });
      refresh();
    },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  const addPenalty = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc("hr_add_penalty", {
        _staff_id: staffId,
        _amount: Number(pen.amount),
        _reason: pen.reason.trim(),
      });
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success(ar ? "تم تسجيل الخصم" : "Penalty recorded");
      setPen({ amount: "", reason: "" });
      refresh();
    },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  if (!canBonus && !canPenalty) return null;
  const valid = (f: { amount: string; reason: string }) =>
    Number(f.amount) > 0 && f.reason.trim().length >= 3;

  return (
    <div className="space-y-3 rounded-xl border border-border bg-muted p-3">
      {canBonus && (
        <div className="space-y-2">
          <p className="flex items-center gap-2 text-sm font-semibold text-success">
            <span className="flex size-6 items-center justify-center rounded-md bg-success/15">
              <Gift className="size-3.5" />
            </span>
            {ar ? "إضافة مكافأة / بونص" : "Add bonus"}
          </p>
          <div className="flex gap-2">
            <Input
              className="w-28"
              type="number"
              min="0"
              inputMode="decimal"
              placeholder={ar ? "المبلغ" : "Amount"}
              value={bonus.amount}
              onChange={(e) => setBonus({ ...bonus, amount: e.target.value })}
            />
            <Input
              placeholder={ar ? "السبب" : "Reason"}
              value={bonus.reason}
              onChange={(e) => setBonus({ ...bonus, reason: e.target.value })}
            />
            <Button
              size="sm"
              className="h-9"
              disabled={!valid(bonus) || addBonus.isPending}
              onClick={() => addBonus.mutate()}
            >
              {ar ? "إضافة" : "Add"}
            </Button>
          </div>
          {monthIssued && (
            <p className="text-xs text-muted-foreground">
              {ar
                ? "مرتب الشهر ده اتصرف خلاص — المكافأة هتنزل في مرتب الشهر الجاي."
                : "This month is already paid — the bonus goes into next month's payroll."}
            </p>
          )}
        </div>
      )}
      {canPenalty && (
        <div className="space-y-2">
          <p className="flex items-center gap-2 text-sm font-semibold text-destructive">
            <span className="flex size-6 items-center justify-center rounded-md bg-destructive/12">
              <Gavel className="size-3.5" />
            </span>
            {ar ? "تسجيل خصم / جزاء" : "Record penalty"}
          </p>
          <div className="flex gap-2">
            <Input
              className="w-28"
              type="number"
              min="0"
              inputMode="decimal"
              placeholder={ar ? "المبلغ" : "Amount"}
              value={pen.amount}
              onChange={(e) => setPen({ ...pen, amount: e.target.value })}
            />
            <Input
              placeholder={ar ? "السبب" : "Reason"}
              value={pen.reason}
              onChange={(e) => setPen({ ...pen, reason: e.target.value })}
            />
            <Button
              size="sm"
              variant="destructive"
              className="h-9"
              disabled={!valid(pen) || addPenalty.isPending}
              onClick={() => addPenalty.mutate()}
            >
              {ar ? "تسجيل" : "Add"}
            </Button>
          </div>
          <p className="text-xs text-muted-foreground">
            {ar
              ? "الخصم بيتخصم من أقرب مرتب، واللي ميكفيهوش المرتب بيترحّل للشهر اللي بعده."
              : "Deducted from the next payroll; anything the pay can't cover carries forward."}
          </p>
        </div>
      )}
    </div>
  );
}
