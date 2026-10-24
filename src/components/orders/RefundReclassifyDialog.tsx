import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { ArrowLeftRight, CircleAlert } from "lucide-react";
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
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { supabase } from "@/integrations/supabase/client";
import { formatMoney, friendlyError } from "@/lib/format";

type Preview = {
  order_number: string;
  amount: number;
  is_cancellation: boolean;
  to_cancellation: boolean;
  can_change: boolean;
  blocker: string | null;
  effects: string[];
  reclassify_note: string | null;
};

/**
 * Super admin: switch one old auto-refund (a removed item) between "refund" and
 * "cancellation". Shows what changes before saving; every switch is audited.
 */
export function RefundReclassifyDialog({
  refundId,
  currency,
  lang,
  onClose,
}: {
  refundId: string | null;
  currency: string;
  lang: "ar" | "en";
  onClose: () => void;
}) {
  const ar = lang === "ar";
  const qc = useQueryClient();
  const [note, setNote] = useState("");

  const preview = useQuery({
    queryKey: ["refund-reclassify-preview", refundId],
    enabled: Boolean(refundId),
    queryFn: async () => {
      const { data, error } = await supabase.rpc(
        "refund_reclassify_preview" as never,
        { _refund_id: refundId } as never,
      );
      if (error) throw error;
      return data as unknown as Preview;
    },
  });

  const save = useMutation({
    mutationFn: async () => {
      const p = preview.data!;
      const { error } = await supabase.rpc(
        "reclassify_refund" as never,
        { _refund_id: refundId, _as_cancellation: p.to_cancellation, _note: note } as never,
      );
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success(
        ar ? "اتغيّر النوع واتسجل في سجل التعديلات" : "Switched and recorded in the audit log",
      );
      qc.invalidateQueries({ queryKey: ["refunds-log"] });
      qc.invalidateQueries({ queryKey: ["order-refunds"] });
      qc.invalidateQueries({ queryKey: ["orders-summary"] });
      setNote("");
      onClose();
    },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  const p = preview.data;
  const target = p?.to_cancellation
    ? ar
      ? "إلغاء (كأنه ما اتباعش)"
      : "cancellation (as if never sold)"
    : ar
      ? "مرتجع"
      : "refund";

  return (
    <Dialog open={Boolean(refundId)} onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-w-lg">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <ArrowLeftRight className="h-4 w-4" />
            {ar ? "تغيير نوع العملية" : "Switch record type"}
          </DialogTitle>
          <DialogDescription>
            {p
              ? ar
                ? `فاتورة #${p.order_number} · ${formatMoney(p.amount, currency, lang)} · هتتحول لـ ${target}`
                : `Invoice #${p.order_number} · ${formatMoney(p.amount, currency, lang)} · becomes a ${target}`
              : ar
                ? "بنحسب التأثير…"
                : "Working out the effect…"}
          </DialogDescription>
        </DialogHeader>

        {preview.isError && (
          <p className="text-sm text-destructive">{friendlyError(preview.error, lang)}</p>
        )}

        {p && (
          <div className="space-y-3 text-sm">
            <div className="rounded-lg border border-border bg-muted/40 p-3">
              <p className="mb-2 font-semibold">{ar ? "اللي هيتغير:" : "What changes:"}</p>
              <ul className="list-disc space-y-1 ps-5 text-muted-foreground">
                {p.effects.map((line) => (
                  <li key={line}>{line}</li>
                ))}
              </ul>
            </div>
            {!p.can_change && p.blocker && (
              <p className="flex items-start gap-2 rounded-lg border border-destructive/40 bg-destructive/5 p-3 text-destructive">
                <CircleAlert className="mt-0.5 h-4 w-4 shrink-0" />
                {p.blocker}
              </p>
            )}
            {p.can_change && (
              <div className="grid gap-1">
                <Label htmlFor="reclassify-note">
                  {ar ? "السبب (بيتسجل)" : "Reason (recorded)"}
                </Label>
                <Textarea
                  id="reclassify-note"
                  value={note}
                  onChange={(e) => setNote(e.target.value)}
                  placeholder={
                    ar
                      ? "مثال: الصنف اتلغى قبل ما يتعمل، مش مرتجع"
                      : "e.g. the item was cancelled, not returned"
                  }
                />
              </div>
            )}
          </div>
        )}

        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            {ar ? "رجوع" : "Back"}
          </Button>
          <Button
            disabled={!p?.can_change || note.trim().length < 3 || save.isPending}
            onClick={() => save.mutate()}
          >
            {ar ? "تأكيد التغيير" : "Confirm"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
