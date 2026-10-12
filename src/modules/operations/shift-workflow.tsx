// Shift workflow building blocks: roster picker, roster editor, drawer expense and shortage attribution.
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
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
import { Textarea } from "@/components/ui/textarea";
import { supabase } from "@/integrations/supabase/client";
import { formatMoney, friendlyError } from "@/lib/format";

type Lang = "ar" | "en";
export type StaffOption = { id: string; name: string; job_title: string | null };
export type ShortageMode = "split" | "staff" | "venue";

export function useStaffCandidates(enabled = true) {
  return useQuery({
    queryKey: ["shift-staff-candidates"],
    enabled,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("shift_staff_candidates");
      if (error) throw error;
      return (data ?? []) as StaffOption[];
    },
  });
}

export function useShiftRoster(shiftId: string | null | undefined) {
  return useQuery({
    queryKey: ["shift-roster", shiftId ?? null],
    enabled: Boolean(shiftId),
    queryFn: async () => {
      const { data, error } = await supabase
        .from("shift_staff")
        .select("staff_id")
        .eq("shift_id", shiftId!);
      if (error) throw error;
      return (data ?? []).map((row) => row.staff_id);
    },
  });
}

export function useLastRetainedFloat(branchId: string | null | undefined) {
  return useQuery({
    queryKey: ["last-retained-float", branchId ?? null],
    enabled: Boolean(branchId),
    queryFn: async () => {
      const { data, error } = await supabase.rpc("last_retained_float", { _branch_id: branchId! });
      if (error) throw error;
      return data === null ? null : Number(data);
    },
  });
}

/** Multi-select checklist of active floor staff. */
export function StaffPicker({
  value,
  onChange,
  lang,
}: {
  value: string[];
  onChange: (ids: string[]) => void;
  lang: Lang;
}) {
  const staff = useStaffCandidates();
  const ar = lang === "ar";
  if (staff.isLoading) return <p className="text-sm text-muted-foreground">{ar ? "جارٍ التحميل..." : "Loading..."}</p>;
  if (!staff.data?.length)
    return <p className="text-sm text-muted-foreground">{ar ? "لا يوجد موظفون نشطون" : "No active staff"}</p>;
  return (
    <div className="grid max-h-56 gap-1 overflow-y-auto rounded-lg border border-border p-2">
      {staff.data.map((person) => {
        const checked = value.includes(person.id);
        return (
          <label
            key={person.id}
            className="flex cursor-pointer items-center gap-2 rounded-md px-2 py-1.5 text-sm hover:bg-muted"
          >
            <Checkbox
              checked={checked}
              onCheckedChange={(next) =>
                onChange(next ? [...value, person.id] : value.filter((id) => id !== person.id))
              }
            />
            <span className="font-medium">{person.name}</span>
            {person.job_title && <span className="text-xs text-muted-foreground">· {person.job_title}</span>}
          </label>
        );
      })}
    </div>
  );
}

/** POS header action: edit who is working the active shift. */
export function ShiftRosterDialog({
  shiftId,
  open,
  onOpenChange,
  lang,
}: {
  shiftId: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  lang: Lang;
}) {
  const ar = lang === "ar";
  const queryClient = useQueryClient();
  const roster = useShiftRoster(open ? shiftId : null);
  const [ids, setIds] = useState<string[]>([]);
  useEffect(() => {
    if (open && roster.data) setIds(roster.data);
  }, [open, roster.data]);
  const save = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc("set_shift_roster", { _shift_id: shiftId, _staff_ids: ids });
      if (error) throw error;
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ["shift-roster", shiftId] });
      toast.success(ar ? "تم تحديث طاقم الوردية" : "Shift roster updated");
      onOpenChange(false);
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{ar ? "تعديل طاقم الوردية" : "Edit shift roster"}</DialogTitle>
        </DialogHeader>
        <StaffPicker value={ids} onChange={setIds} lang={lang} />
        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            {ar ? "إلغاء" : "Cancel"}
          </Button>
          <Button disabled={save.isPending} onClick={() => save.mutate()}>
            {ar ? "حفظ" : "Save"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

/** Manager-only: expense paid straight out of the open shift's drawer. */
export function ShiftExpenseDialog({
  shiftId,
  shiftLabel,
  open,
  onOpenChange,
  lang,
}: {
  shiftId: string;
  shiftLabel: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  lang: Lang;
}) {
  const ar = lang === "ar";
  const queryClient = useQueryClient();
  const [amount, setAmount] = useState("");
  const [description, setDescription] = useState("");
  const save = useMutation({
    mutationFn: async () => {
      const value = Number(amount);
      if (!(value > 0)) throw new Error(ar ? "أدخل مبلغًا صحيحًا" : "Enter a valid amount");
      if (description.trim().length < 2) throw new Error(ar ? "أدخل وصف المصروف" : "Enter a description");
      const { error } = await supabase.rpc("create_shift_expense", {
        _shift_id: shiftId,
        _amount: value,
        _description: description.trim().slice(0, 200),
      });
      if (error) throw error;
    },
    onSuccess: async () => {
      setAmount("");
      setDescription("");
      await queryClient.invalidateQueries({ queryKey: ["shift-cash"] });
      await queryClient.invalidateQueries({ queryKey: ["financial-engine"] });
      toast.success(ar ? "تم خصم المصروف من درج الوردية" : "Expense deducted from the shift drawer");
      onOpenChange(false);
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{ar ? "مصروف من الدرج" : "Drawer expense"}</DialogTitle>
          <DialogDescription>
            {ar ? `خصم من درج الوردية المفتوحة #${shiftLabel}` : `Deduct from open shift drawer #${shiftLabel}`}
          </DialogDescription>
        </DialogHeader>
        <div className="grid gap-3">
          <div className="grid gap-2">
            <Label htmlFor="sx-amount">{ar ? "المبلغ" : "Amount"}</Label>
            <Input id="sx-amount" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} />
          </div>
          <div className="grid gap-2">
            <Label htmlFor="sx-desc">{ar ? "الوصف" : "Description"}</Label>
            <Input id="sx-desc" maxLength={200} value={description} onChange={(e) => setDescription(e.target.value)} />
          </div>
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            {ar ? "إلغاء" : "Cancel"}
          </Button>
          <Button disabled={save.isPending} onClick={() => save.mutate()}>
            {ar ? "خصم من الدرج" : "Deduct from drawer"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

/** Mandatory attribution when counted cash is below expected. */
export function ShortageDialog({
  open,
  onOpenChange,
  shortage,
  currency,
  staff,
  canAbsorb,
  pending,
  onConfirm,
  lang,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  shortage: number;
  currency: string;
  staff: StaffOption[];
  canAbsorb: boolean;
  pending: boolean;
  onConfirm: (mode: ShortageMode, staffId: string | null, reason: string | null) => void;
  lang: Lang;
}) {
  const ar = lang === "ar";
  const [mode, setMode] = useState<ShortageMode>("split");
  const [staffId, setStaffId] = useState("");
  const [venueReason, setVenueReason] = useState("");
  const trimmedReason = venueReason.trim();
  const writtenCharacters = trimmedReason.match(/[A-Za-zء-ي]/g)?.length ?? 0;
  const venueReasonValid = trimmedReason.length >= 8 && writtenCharacters >= 5;
  const options: Array<{ key: ShortageMode; label: string; hint: string; disabled?: boolean }> = [
    {
      key: "split",
      label: ar ? "توزيع بالتساوي على طاقم الوردية" : "Split equally across shift staff",
      hint: ar ? `${staff.length} موظف — جزاء معلّق لكل منهم` : `${staff.length} staff — pending penalty each`,
    },
    {
      key: "staff",
      label: ar ? "تحميل على موظف محدد" : "Charge one staff member",
      hint: ar ? "جزاء معلّق بكامل العجز" : "Pending penalty for the full shortage",
    },
    {
      key: "venue",
      label: ar ? "تحمل المكان" : "Venue absorbed",
      hint: canAbsorb
        ? ar ? "فرق تشغيل معتمد من الإدارة" : "Manager-approved operating variance"
        : ar ? "يتطلب صلاحية مدير" : "Requires a manager",
      disabled: !canAbsorb,
    },
  ];
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{ar ? "عجز في الدرج" : "Drawer shortage"}</DialogTitle>
          <DialogDescription>
            {ar ? "العجز:" : "Shortage:"}{" "}
            <b className="text-destructive">{formatMoney(shortage, currency, lang)}</b>{" "}
            {ar ? "— اختر طريقة التحميل لإغلاق الوردية" : "— choose who carries it to close the shift"}
          </DialogDescription>
        </DialogHeader>
        <div className="grid gap-2">
          {options.map((option) => (
            <button
              key={option.key}
              type="button"
              disabled={option.disabled}
              onClick={() => setMode(option.key)}
              className={`rounded-lg border p-3 text-start transition disabled:cursor-not-allowed disabled:opacity-50 ${
                mode === option.key ? "border-primary bg-primary/10" : "border-border hover:bg-muted"
              }`}
            >
              <p className="font-semibold">{option.label}</p>
              <p className="text-xs text-muted-foreground">{option.hint}</p>
            </button>
          ))}
          {mode === "staff" && (
            <select
              value={staffId}
              onChange={(e) => setStaffId(e.target.value)}
              className="h-10 rounded-md border border-input bg-background px-3 text-sm"
            >
              <option value="">{ar ? "اختر الموظف" : "Select staff"}</option>
              {staff.map((person) => (
                <option key={person.id} value={person.id}>
                  {person.name}
                </option>
              ))}
            </select>
          )}
          {mode === "venue" && (
            <div className="grid gap-2 pt-1">
              <Label htmlFor="venue-shortage-reason">
                {ar ? "سبب تحميل العجز على المكان" : "Reason for venue-absorbed shortage"}
              </Label>
              <Textarea
                id="venue-shortage-reason"
                value={venueReason}
                onChange={(event) => setVenueReason(event.target.value)}
                maxLength={300}
                placeholder={
                  ar
                    ? "اكتب سببًا واضحًا، مثال: فرق بسبب خطأ في عد النقدية"
                    : "Write a clear reason, e.g. cash counting discrepancy"
                }
                aria-invalid={trimmedReason.length > 0 && !venueReasonValid}
              />
              {!venueReasonValid && (
                <p className="text-xs text-destructive">
                  {ar
                    ? "السبب إلزامي ويجب أن يكون كلامًا واضحًا، وليس نقطة أو أرقامًا فقط."
                    : "A clear written reason is required; punctuation or numbers alone are not accepted."}
                </p>
              )}
            </div>
          )}
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            {ar ? "رجوع" : "Back"}
          </Button>
          <Button
            variant="destructive"
            disabled={
              pending ||
              (mode === "staff" && !staffId) ||
              (mode === "split" && staff.length === 0) ||
              (mode === "venue" && !venueReasonValid)
            }
            onClick={() =>
              onConfirm(
                mode,
                mode === "staff" ? staffId : null,
                mode === "venue" ? trimmedReason : null,
              )
            }
          >
            {ar ? "تأكيد وإغلاق الوردية" : "Confirm & close shift"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
