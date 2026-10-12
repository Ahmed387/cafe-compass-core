import { useQuery } from "@tanstack/react-query";
import { useState } from "react";

import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Label } from "@/components/ui/label";
import { supabase } from "@/integrations/supabase/client";
import { formatDateTime, formatMoney } from "@/lib/format";

export type Settlement = { mode: "venue" | "staff" | "shift"; staffId?: string | undefined; shiftId?: string | undefined };

const MODES: { key: Settlement["mode"]; label: string; hint: string }[] = [
  { key: "venue", label: "تحمل المكان", hint: "يُسجل كخسارة تشغيلية على المكان، بدون أي خصم من الموظفين." },
  { key: "staff", label: "تحميل على موظف محدد", hint: "يتحول 100% من العجز إلى جزاء معلّق على الموظف." },
  { key: "shift", label: "توزيع على طاقم وردية محددة", hint: "يُقسم العجز بالتساوي على طاقم الوردية كجزاءات." },
];

export function StocktakeSettlementDialog({
  open,
  onOpenChange,
  branchId,
  shortage,
  pending,
  onConfirm,
}: {
  open: boolean;
  onOpenChange: (v: boolean) => void;
  branchId: string;
  shortage: number;
  pending: boolean;
  onConfirm: (s: Settlement) => void;
}) {
  const [mode, setMode] = useState<Settlement["mode"]>("venue");
  const [staffId, setStaffId] = useState("");
  const [shiftId, setShiftId] = useState("");

  const staff = useQuery({
    queryKey: ["settle-staff"],
    enabled: open && mode === "staff",
    queryFn: async () => {
      const { data, error } = await supabase
        .from("user_profiles")
        .select("id,display_name,first_name,last_name")
        .eq("is_active", true)
        .order("first_name");
      if (error) throw error;
      return data;
    },
  });
  const shifts = useQuery({
    queryKey: ["settle-shifts", branchId],
    enabled: open && mode === "shift",
    queryFn: async () => {
      const { data, error } = await supabase
        .from("shifts")
        .select("id,opened_at,status,shift_staff(staff_id)")
        .eq("branch_id", branchId)
        .order("opened_at", { ascending: false })
        .limit(20);
      if (error) throw error;
      return data;
    },
  });

  const ready = mode === "venue" || (mode === "staff" && staffId) || (mode === "shift" && shiftId);
  const sel = "mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm";

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent dir="rtl">
        <DialogHeader>
          <DialogTitle>تسوية عجز الجرد</DialogTitle>
        </DialogHeader>
        <p className="text-sm">
          العجز التقديري: <strong className="text-destructive">{formatMoney(shortage)}</strong>
          <span className="block text-xs text-muted-foreground">
            المبلغ النهائي يُحسب عند الاعتماد بعد خصم جزاءات الهدر المسجلة منذ آخر جرد.
          </span>
        </p>
        <div className="grid gap-2">
          {MODES.map((m) => (
            <button
              key={m.key}
              type="button"
              onClick={() => setMode(m.key)}
              className={`rounded-lg border p-3 text-start ${mode === m.key ? "border-primary bg-primary/10" : "border-border"}`}
            >
              <div className="font-semibold">{m.label}</div>
              <div className="text-xs text-muted-foreground">{m.hint}</div>
            </button>
          ))}
        </div>
        {mode === "staff" && (
          <div>
            <Label>الموظف</Label>
            <select className={sel} value={staffId} onChange={(e) => setStaffId(e.target.value)}>
              <option value="">اختر موظفًا…</option>
              {(staff.data ?? []).map((s) => (
                <option key={s.id} value={s.id}>
                  {s.display_name || [s.first_name, s.last_name].filter(Boolean).join(" ")}
                </option>
              ))}
            </select>
          </div>
        )}
        {mode === "shift" && (
          <div>
            <Label>الوردية</Label>
            <select className={sel} value={shiftId} onChange={(e) => setShiftId(e.target.value)}>
              <option value="">اختر وردية…</option>
              {(shifts.data ?? []).map((s) => (
                <option key={s.id} value={s.id} disabled={(s.shift_staff ?? []).length === 0}>
                  {formatDateTime(s.opened_at)} · {s.status === "open" ? "مفتوحة" : "مغلقة"} ·{" "}
                  {(s.shift_staff ?? []).length} موظف
                </option>
              ))}
            </select>
          </div>
        )}
        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            تراجع
          </Button>
          <Button
            disabled={!ready || pending}
            onClick={() => onConfirm({ mode, staffId: staffId || undefined, shiftId: shiftId || undefined })}
          >
            اعتماد الجرد والتسوية
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
