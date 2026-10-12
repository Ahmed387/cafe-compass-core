import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Loader2, Trash2 } from "lucide-react";
import { useEffect, useState } from "react";
import { toast } from "sonner";

import { Input } from "@/components/ui/input";
import { supabase } from "@/integrations/supabase/client";
import { friendlyError } from "@/lib/format";

/**
 * Per-ingredient expected waste % (spillage / loss). Internal tracking only: it never
 * changes the item cost, sale cost or menu price; it sets the stocktake tolerance.
 * Defaults to 0. Saves on blur / Enter.
 */
export function WasteCell({
  itemId,
  value,
  editable,
  lang,
}: {
  itemId: string;
  value: number;
  editable: boolean;
  lang: "ar" | "en";
}) {
  const qc = useQueryClient();
  const [text, setText] = useState(String(value));
  useEffect(() => setText(String(value)), [value]);

  const save = useMutation({
    mutationFn: async (pct: number) => {
      const { error } = await supabase.rpc("set_item_waste_pct", {
        _item_id: itemId,
        _waste_pct: pct,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success(lang === "ar" ? "اتحفظت نسبة الهالك" : "Waste % saved");
      qc.invalidateQueries({ queryKey: ["inventory-items"] });
    },
    onError: (e) => {
      setText(String(value));
      toast.error(friendlyError(e, lang));
    },
  });

  // Waste level at a glance: normal up to 5%, worth watching up to 15%, high above that.
  const level = (pct: number) =>
    pct <= 0
      ? "text-muted-foreground bg-muted"
      : pct > 15
      ? "text-destructive bg-destructive/10"
      : pct > 5
        ? "text-warning-foreground bg-warning/20"
        : "text-success bg-success/12";

  if (!editable)
    return (
      <span
        className={`inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-semibold tabular-nums ${level(Number(value))}`}
      >
        <Trash2 className="size-3" aria-hidden />
        {value}%
      </span>
    );

  const commit = () => {
    const pct = Number(text);
    if (!Number.isFinite(pct) || pct < 0 || pct > 100) {
      setText(String(value));
      return;
    }
    if (pct !== Number(value)) save.mutate(pct);
  };

  return (
    <div className="flex items-center justify-center gap-1">
      <span
        className={`flex size-7 items-center justify-center rounded-md transition-colors ${level(Number(text) || 0)}`}
        aria-hidden
      >
        {save.isPending ? (
          <Loader2 className="size-3.5 animate-spin" />
        ) : (
          <Trash2 className="size-3.5" />
        )}
      </span>
      <Input
        aria-label={lang === "ar" ? "نسبة الهالك" : "Waste %"}
        className="h-8 w-16 text-center tabular-nums"
        inputMode="decimal"
        value={text}
        disabled={save.isPending}
        onChange={(e) => setText(e.target.value)}
        onBlur={commit}
        onKeyDown={(e) => {
          if (e.key === "Enter") (e.target as HTMLInputElement).blur();
        }}
      />
      <span className="text-xs text-muted-foreground">%</span>
    </div>
  );
}
