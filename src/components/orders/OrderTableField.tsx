import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Check, Pencil, X } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";

/**
 * Dine-in table of an invoice, with an inline edit. The cashier can change it
 * while the invoice's shift is open; a manager any time (set_order_table checks
 * the same and writes the audit log).
 */
export function OrderTableField({
  orderId,
  value,
  shiftClosed,
  onSaved,
}: {
  orderId: string;
  value: string | null;
  shiftClosed: boolean;
  onSaved: (table: string) => void;
}) {
  const { t, lang } = useI18n();
  const { can } = useAuth();
  const queryClient = useQueryClient();
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState("");
  const canEdit = can("shifts.close") || (!shiftClosed && can("pos.create_order"));

  const save = useMutation({
    mutationFn: async () => {
      const table = draft.trim().slice(0, 20);
      if (!table) throw new Error(t("pos.tableRequired"));
      const { error } = await supabase.rpc("set_order_table", {
        _order_id: orderId,
        _table_number: table,
      });
      if (error) throw error;
      return table;
    },
    onSuccess: async (table) => {
      setEditing(false);
      onSaved(table);
      toast.success(t("orders.tableSaved"));
      await queryClient.invalidateQueries({ queryKey: ["orders"] });
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  if (editing) {
    return (
      <form
        className="flex items-center gap-1"
        onSubmit={(e) => {
          e.preventDefault();
          save.mutate();
        }}
      >
        <Input
          autoFocus
          value={draft}
          onChange={(e) => setDraft(e.target.value.slice(0, 20))}
          aria-label={t("pos.tableNumber")}
          inputMode="numeric"
          className="h-8 w-24 text-center font-bold"
        />
        <Button
          type="submit"
          size="icon"
          className="size-8"
          disabled={!draft.trim() || save.isPending}
          aria-label={t("common.save")}
        >
          <Check className="size-4" />
        </Button>
        <Button
          type="button"
          size="icon"
          variant="ghost"
          className="size-8"
          onClick={() => setEditing(false)}
          aria-label={t("common.cancel")}
        >
          <X className="size-4" />
        </Button>
      </form>
    );
  }

  return (
    <div className="flex items-center gap-2">
      <p className="text-lg font-bold">{value || "—"}</p>
      {canEdit && (
        <Button
          size="sm"
          variant="ghost"
          className="h-7 px-2 text-xs print:hidden"
          icon={Pencil}
          onClick={() => {
            setDraft(value ?? "");
            setEditing(true);
          }}
        >
          {t("orders.editTable")}
        </Button>
      )}
    </div>
  );
}
