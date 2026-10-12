import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
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
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { formatMoney, friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import {
  WasteBearerPicker,
  bearerReady,
  type WasteBearer,
} from "@/modules/supply/WasteBearerPicker";

type Item = {
  id: string;
  name: string;
  name_ar: string | null;
  unit: string;
  cost_per_unit: number | string | null;
};

/**
 * Log damaged / wasted stock. Who bears the cost is mandatory: the business (an
 * operating loss in the P&L), one employee, or the whole team (payroll penalties).
 */
export function WasteLogDialog({
  open,
  onOpenChange,
  items,
  initialItemId,
  canChargeStaff,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  items: Item[];
  initialItemId?: string | undefined;
  canChargeStaff: boolean;
}) {
  const { t, lang } = useI18n();
  const ar = lang === "ar";
  const { me, currentBranchId } = useAuth();
  const currency = me?.company?.currency ?? "EGP";
  const qc = useQueryClient();

  const [itemId, setItemId] = useState("");
  const [qty, setQty] = useState("");
  const [reason, setReason] = useState("");
  const [bearer, setBearer] = useState<WasteBearer | null>(null);
  const [staffId, setStaffId] = useState("");

  useEffect(() => {
    if (!open) return;
    setItemId(initialItemId ?? "");
    setQty("");
    setReason("");
    setBearer(null);
    setStaffId("");
  }, [open, initialItemId]);

  const item = items.find((i) => i.id === itemId);
  const quantity = Number(qty);
  const cost = item && quantity > 0 ? quantity * Number(item.cost_per_unit ?? 0) : 0;
  const ready =
    Boolean(item) && quantity > 0 && reason.trim().length >= 3 && bearerReady(bearer, staffId);

  const save = useMutation({
    mutationFn: async () => {
      if (!currentBranchId) throw new Error(t("inv.branchRequired"));
      if (!bearer) throw new Error(ar ? "اختار مين يتحمل التكلفة" : "Choose who bears the cost");
      const { error } = await supabase.rpc("record_waste", {
        _branch_id: currentBranchId,
        _item_id: itemId,
        _qty: quantity,
        _reason: reason.trim(),
        _bearer: bearer,
        ...(bearer === "staff" ? { _staff_id: staffId } : {}),
      });
      if (error) throw error;
    },
    onSuccess: async () => {
      toast.success(ar ? "اتسجل الهالك" : "Waste logged");
      onOpenChange(false);
      for (const key of [
        "branch-stock",
        "stock-movements",
        "hr-preview",
        "hr-pending-penalties",
        "staff-penalties",
      ]) {
        await qc.invalidateQueries({ queryKey: [key] });
      }
    },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[92vh] overflow-y-auto sm:max-w-xl">
        <DialogHeader>
          <DialogTitle>{ar ? "تسجيل هالك / تالف" : "Log waste / damage"}</DialogTitle>
          <DialogDescription>
            {ar
              ? "الكمية بتتخصم من المخزن، والتكلفة بتروح على الجهة اللي تختارها."
              : "The quantity leaves stock and its cost goes to whoever you choose."}
          </DialogDescription>
        </DialogHeader>

        <form
          className="space-y-4"
          onSubmit={(e) => {
            e.preventDefault();
            if (ready) save.mutate();
          }}
        >
          <div className="grid gap-4 sm:grid-cols-[1fr_9rem]">
            <div className="flex min-w-0 flex-col gap-1.5">
              <Label htmlFor="waste-item" className="text-xs text-muted-foreground">
                {t("inv.item")}
              </Label>
              <Select value={itemId} onValueChange={setItemId}>
                <SelectTrigger id="waste-item">
                  <SelectValue placeholder={t("inv.selectItem")} />
                </SelectTrigger>
                <SelectContent>
                  {items.map((i) => (
                    <SelectItem key={i.id} value={i.id}>
                      {(ar ? i.name_ar || i.name : i.name) ?? i.name} ({i.unit})
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="waste-qty" className="text-xs text-muted-foreground">
                {t("inv.qty")}
              </Label>
              <div className="relative">
                <Input
                  id="waste-qty"
                  className="pe-12 text-end font-mono tabular-nums"
                  inputMode="decimal"
                  value={qty}
                  onChange={(e) => setQty(e.target.value)}
                />
                <span className="pointer-events-none absolute inset-y-0 end-3 flex items-center text-xs text-muted-foreground">
                  {item?.unit ?? ""}
                </span>
              </div>
            </div>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="waste-reason" className="text-xs text-muted-foreground">
              {t("inv.reason")}
            </Label>
            <Input
              id="waste-reason"
              value={reason}
              placeholder={ar ? "مثال: كرتونة لبن انتهت صلاحيتها" : "e.g. milk carton expired"}
              onChange={(e) => setReason(e.target.value)}
            />
          </div>

          <div className="flex items-center justify-between rounded-lg border border-border bg-muted px-3 py-2 text-sm">
            <span className="text-muted-foreground">{ar ? "تكلفة الهالك" : "Waste cost"}</span>
            <span className="font-mono font-bold tabular-nums">
              {formatMoney(cost, currency, lang)}
            </span>
          </div>

          <WasteBearerPicker
            idPrefix="waste"
            value={bearer}
            onChange={setBearer}
            staffId={staffId}
            onStaffIdChange={setStaffId}
            amount={cost}
            allowStaff={canChargeStaff}
          />

          <DialogFooter className="pt-1">
            <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
              {t("common.cancel")}
            </Button>
            <Button type="submit" variant="destructive" disabled={!ready || save.isPending}>
              {save.isPending
                ? ar
                  ? "جاري التسجيل…"
                  : "Saving…"
                : ar
                  ? "تسجيل الهالك"
                  : "Record waste"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
