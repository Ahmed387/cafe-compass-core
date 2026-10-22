import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { toast } from "sonner";

import { PreparedDisposition, useDisposition } from "@/components/orders/PreparedDisposition";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { supabase } from "@/integrations/supabase/client";
import { friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { invoiceSequence } from "@/lib/receipt";

/** Cancels an unpaid order (pending / open, or an unsettled partner-tab invoice). */
export function OrderCancelDialog({
  order,
  onClose,
}: {
  order: { id: string; number: string } | null;
  onClose: () => void;
}) {
  const { t, lang } = useI18n();
  const queryClient = useQueryClient();
  const disposition = useDisposition();
  const [reason, setReason] = useState("");

  const close = () => {
    setReason("");
    disposition.reset();
    onClose();
  };

  const cancel = useMutation({
    mutationFn: async () => {
      if (!order) throw new Error("Missing order");
      const { error } = await supabase.rpc("cancel_pos_order", {
        _order_id: order.id,
        _reason: reason.trim(),
        ...disposition.args,
      });
      if (error) throw error;
    },
    onSuccess: async () => {
      close();
      await Promise.all(
        ["orders", "orders-summary", "branch-stock", "order-invoice"].map((key) =>
          queryClient.invalidateQueries({ queryKey: [key] }),
        ),
      );
      toast.success(t("orders.cancelled"));
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  return (
    <Dialog open={Boolean(order)} onOpenChange={(open) => !open && close()}>
      <DialogContent className="sm:max-w-xl">
        <DialogHeader>
          <DialogTitle>
            {t("orders.cancel")} — #{invoiceSequence(order?.number ?? "1")}
          </DialogTitle>
        </DialogHeader>
        <div className="space-y-4">
          <PreparedDisposition idPrefix="cancel" value={disposition.value} onChange={disposition.setValue} />
          <div className="grid gap-1.5">
            <Label htmlFor="reason" className="text-xs text-muted-foreground">
              {t("orders.reason")}
            </Label>
            <Input id="reason" value={reason} onChange={(e) => setReason(e.target.value)} />
            <p className="text-xs text-muted-foreground">{t("orders.cancelHint")}</p>
          </div>
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={close}>
            {t("common.cancel")}
          </Button>
          <Button
            variant="destructive"
            disabled={reason.trim().length < 3 || !disposition.ready || cancel.isPending}
            onClick={() => cancel.mutate()}
          >
            {t("orders.confirmCancel")}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
