import { useState } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Loader2, Pencil } from "lucide-react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { supabase } from "@/integrations/supabase/client";
import { friendlyError } from "@/lib/format";

/** Corrects a closed shift's counted cash; variance is recomputed server-side and every dependent view refetches. */
export function EditClosingCashButton({ shiftId, current }: { shiftId: string; current: number | null }) {
  const qc = useQueryClient();
  const [open, setOpen] = useState(false);
  const [value, setValue] = useState(String(current ?? ""));
  const [reason, setReason] = useState("");

  const save = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc("update_shift_closing_cash" as never, {
        _shift_id: shiftId,
        _closing_cash: Number(value),
        _reason: reason.trim(),
      } as never);
      if (error) throw error;
    },
    onSuccess: async () => {
      toast.success("تم تحديث النقدية الختامية وإعادة احتساب العجز والتقارير");
      setOpen(false);
      setReason("");
      await qc.invalidateQueries();
    },
    onError: (e) => toast.error(friendlyError(e)),
  });

  const valid = value !== "" && Number(value) >= 0 && reason.trim().length >= 3;

  return (
    <>
      <Button
        size="icon"
        variant="ghost"
        className="size-7"
        aria-label="تعديل النقدية الختامية"
        onClick={() => {
          setValue(String(current ?? ""));
          setOpen(true);
        }}
      >
        <Pencil className="size-3.5" />
      </Button>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>تعديل النقدية الختامية</DialogTitle>
          </DialogHeader>
          <div className="grid gap-4">
            <div className="grid gap-2">
              <Label htmlFor="cc-value">النقدية المعدودة الفعلية</Label>
              <Input id="cc-value" type="number" min={0} inputMode="decimal" value={value} onChange={(e) => setValue(e.target.value)} />
            </div>
            <div className="grid gap-2">
              <Label htmlFor="cc-reason">سبب التعديل (إلزامي)</Label>
              <Input id="cc-reason" value={reason} onChange={(e) => setReason(e.target.value)} />
            </div>
            <p className="text-xs text-muted-foreground">
              سيُعاد احتساب العجز/الفارق تلقائيًا، وتتحدث تقارير الإغلاق والمالية وأرصدة الشركاء. يُسجَّل التعديل في سجل التدقيق، ولا يُسمح به في فترة مقفلة.
            </p>
          </div>
          <DialogFooter>
            <Button disabled={!valid || save.isPending} onClick={() => save.mutate()}>
              {save.isPending && <Loader2 className="size-4 animate-spin" />}
              حفظ وإعادة الاحتساب
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
