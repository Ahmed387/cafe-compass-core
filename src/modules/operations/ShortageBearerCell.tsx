import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Pencil } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import { supabase } from "@/integrations/supabase/client";
import { friendlyError } from "@/lib/format";
import { type ShortageMode, useStaffCandidates } from "@/modules/operations/shift-workflow";

const LABELS: Record<ShortageMode, { ar: string; en: string }> = {
  split: { ar: "تيم الوردية", en: "Shift team" },
  staff: { ar: "موظف محدد", en: "Specific staff" },
  venue: { ar: "المكان", en: "Venue" },
};

const validReason = (r: string) =>
  r.trim().length >= 8 && r.replace(/[^A-Za-z\u0621-\u064A]/g, "").length >= 5;

/**
 * Shows and sets who bears a closed shift's shortage; persisted via audited RPC.
 * A shortage closed by anyone but a super admin waits ("pending") for their call;
 * the first decision needs a reason only for the venue, a change always does.
 */
export function ShortageBearerCell({
  shiftId, shortage, mode, editable, lang,
}: { shiftId: string; shortage: number; mode: string | null; editable: boolean; lang: "ar" | "en" }) {
  const ar = lang === "ar";
  const qc = useQueryClient();
  const [open, setOpen] = useState(false);
  const pending = mode === "pending" || !mode;
  const [next, setNext] = useState<ShortageMode>(pending ? "split" : (mode as ShortageMode));
  const [staffId, setStaffId] = useState("");
  const [reason, setReason] = useState("");
  const staff = useStaffCandidates(open);

  const save = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc("reassign_shift_shortage", {
        _shift_id: shiftId, _mode: next, _staff_id: (next === "staff" ? staffId : null) as unknown as string,
        _reason: (reason.trim() || null) as unknown as string,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success(ar ? "تم تحديد مين يتحمل العجز" : "Shortage bearer saved");
      setOpen(false); setReason("");
      ["shifts", "hr-preview", "shift-ledger", "financial-engine", "pending-shortages", "notifications"].forEach((k) =>
        qc.invalidateQueries({ queryKey: [k] }),
      );
    },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  if (shortage <= 0) return <span className="text-muted-foreground">—</span>;
  const label = pending
    ? editable
      ? ar ? "مستني قرارك" : "Needs your decision"
      : ar ? "مستني السوبر أدمن" : "Waiting for super admin"
    : (ar ? LABELS[mode as ShortageMode]?.ar : LABELS[mode as ShortageMode]?.en) ?? mode;
  const needReason = !pending || next === "venue";

  return (
    <>
      <span className="inline-flex items-center gap-1">
        <Badge variant={pending ? "destructive" : mode === "venue" ? "secondary" : "outline"}>{label}</Badge>
        {editable && pending && (
          <Button size="sm" className="h-7 px-2 text-xs" onClick={() => setOpen(true)}>
            {ar ? "حدد" : "Decide"}
          </Button>
        )}
        {editable && !pending && (
          <Button size="icon" variant="ghost" className="size-7" aria-label={ar ? "تعديل المسؤول" : "Edit bearer"} onClick={() => setOpen(true)}>
            <Pencil className="size-3.5" />
          </Button>
        )}
      </span>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent dir={ar ? "rtl" : "ltr"}>
          <DialogHeader>
            <DialogTitle>
              {pending ? (ar ? "مين يتحمل العجز؟" : "Who bears the shortage?") : ar ? "تعديل المسؤول عن تحمل العجز" : "Change shortage bearer"}
            </DialogTitle>
          </DialogHeader>
          <div className="space-y-3">
            <div className="space-y-1">
              <Label>{ar ? "يتحمله" : "Borne by"}</Label>
              <Select value={next} onValueChange={(v) => setNext(v as ShortageMode)}>
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>
                  {(Object.keys(LABELS) as ShortageMode[]).map((k) => <SelectItem key={k} value={k}>{ar ? LABELS[k].ar : LABELS[k].en}</SelectItem>)}
                </SelectContent>
              </Select>
            </div>
            {next === "staff" && (
              <div className="space-y-1">
                <Label>{ar ? "الموظف" : "Staff member"}</Label>
                <Select value={staffId} onValueChange={setStaffId}>
                  <SelectTrigger><SelectValue placeholder="—" /></SelectTrigger>
                  <SelectContent>{(staff.data ?? []).map((s) => <SelectItem key={s.id} value={s.id}>{s.name}</SelectItem>)}</SelectContent>
                </Select>
              </div>
            )}
            {needReason && (
              <div className="space-y-1">
                <Label>
                  {next === "venue" && pending
                    ? ar ? "ليه المكان هيتحمله؟ (كتابة واضحة)" : "Why does the venue carry it? (clear text)"
                    : ar ? "سبب التعديل (كتابة واضحة)" : "Reason (clear written text)"}
                </Label>
                <Textarea value={reason} maxLength={300} onChange={(e) => setReason(e.target.value)} />
              </div>
            )}
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setOpen(false)}>{ar ? "إلغاء" : "Cancel"}</Button>
            <Button disabled={(needReason && !validReason(reason)) || (next === "staff" && !staffId) || save.isPending} onClick={() => save.mutate()}>
              {ar ? "حفظ" : "Save"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
