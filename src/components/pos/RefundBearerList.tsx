import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { CircleAlert } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { supabase } from "@/integrations/supabase/client";
import { formatMoney, friendlyError } from "@/lib/format";
import type { StaffOption } from "@/modules/operations/shift-workflow";

export type RefundToDecide = {
  refund_id: string;
  order_id: string;
  order_number: string;
  amount: number;
  method: string;
  origin: string;
  reason: string | null;
  at: string;
};

/** Refunds of this shift that still need the manager to say who bears them. */
export function useRefundsToDecide(shiftId: string | null | undefined, enabled: boolean) {
  return useQuery({
    queryKey: ["refunds-to-decide", shiftId ?? null],
    enabled: Boolean(shiftId) && enabled,
    queryFn: async () => {
      const { data, error } = await supabase.rpc(
        "shift_refunds_to_decide" as never,
        { _shift_id: shiftId } as never,
      );
      if (error) throw error;
      return (data ?? []) as unknown as RefundToDecide[];
    },
  });
}

/**
 * Close-shift step: every refund of the shift needs a bearer before the shift can
 * close — the cafe, one employee, or the shift team (split equally between them).
 */
export function RefundBearerList({
  shiftId,
  refunds,
  staff,
  canDecide,
  currency,
  lang,
}: {
  shiftId: string;
  refunds: RefundToDecide[];
  staff: StaffOption[];
  canDecide: boolean;
  currency: string;
  lang: "ar" | "en";
}) {
  const ar = lang === "ar";
  const qc = useQueryClient();
  const [staffFor, setStaffFor] = useState<Record<string, string>>({});

  const decide = useMutation({
    mutationFn: async (v: {
      refundId: string;
      fault: "venue" | "staff" | "all_staff";
      staffId?: string;
    }) => {
      const { error } = await supabase.rpc(
        "set_refund_bearer" as never,
        { _refund_id: v.refundId, _fault: v.fault, _staff_id: v.staffId ?? null } as never,
      );
      if (error) throw error;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["refunds-to-decide", shiftId] });
      toast.success(ar ? "اتسجل مين يتحمل المرتجع" : "Bearer saved");
    },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  if (refunds.length === 0) return null;

  return (
    <section className="space-y-3 rounded-2xl border border-amber-500/40 bg-amber-500/10 p-4">
      <div className="flex items-start gap-2">
        <CircleAlert className="mt-0.5 size-4 shrink-0 text-amber-600" />
        <div className="min-w-0">
          <h3 className="font-bold">
            {ar
              ? `${refunds.length} مرتجع محتاج تحدد مين يتحمله`
              : `${refunds.length} refund(s) need a bearer`}
          </h3>
          <p className="text-xs text-muted-foreground">
            {canDecide
              ? ar
                ? "الوردية مش هتتقفل غير لما كل مرتجع ياخد قرار، حسب اللي الإدارة قالتهولك. «تيم الوردية» بيتقسم بالتساوي على اللي كانوا شغالين في الوردية دي بس. المدير يقدر يغيّر القرار بعدين من صفحة الورديات."
                : "The shift can't close until each refund has a bearer. “Shift team” is split equally between the people on this shift."
              : ar
                ? "اللي بيقفل الوردية بيحدد مين يتحمل كل مرتجع قبل القفل."
                : "Whoever closes the shift picks each refund's bearer first."}
          </p>
        </div>
      </div>

      <ul className="space-y-2">
        {refunds.map((r) => {
          const chosen = staffFor[r.refund_id] ?? "";
          const busy = decide.isPending && decide.variables?.refundId === r.refund_id;
          return (
            <li key={r.refund_id} className="space-y-2 rounded-xl border border-border bg-card p-3">
              <div className="flex flex-wrap items-baseline justify-between gap-2">
                <span className="font-semibold">
                  {ar ? "فاتورة" : "Invoice"} #{r.order_number}
                </span>
                <span className="font-bold tabular-nums text-destructive">
                  {formatMoney(Number(r.amount), currency, lang)}
                </span>
              </div>
              {r.reason && <p className="text-xs text-muted-foreground">{r.reason}</p>}
              {canDecide && (
                <div className="flex flex-wrap items-center gap-2">
                  <Button
                    size="sm"
                    variant="outline"
                    disabled={busy}
                    onClick={() => decide.mutate({ refundId: r.refund_id, fault: "venue" })}
                  >
                    {ar ? "على الكافيه" : "Cafe"}
                  </Button>
                  <Button
                    size="sm"
                    variant="outline"
                    disabled={busy}
                    onClick={() => decide.mutate({ refundId: r.refund_id, fault: "all_staff" })}
                  >
                    {ar ? "تيم الوردية" : "Shift team"}
                  </Button>
                  <select
                    aria-label={ar ? "الموظف" : "Employee"}
                    className="h-9 min-w-0 flex-1 rounded-md border border-input bg-background px-2 text-sm"
                    value={chosen}
                    onChange={(e) => setStaffFor((s) => ({ ...s, [r.refund_id]: e.target.value }))}
                  >
                    <option value="">{ar ? "اختار موظف…" : "Choose employee…"}</option>
                    {staff.map((p) => (
                      <option key={p.id} value={p.id}>
                        {p.name}
                      </option>
                    ))}
                  </select>
                  <Button
                    size="sm"
                    disabled={busy || !chosen}
                    onClick={() =>
                      decide.mutate({ refundId: r.refund_id, fault: "staff", staffId: chosen })
                    }
                  >
                    {ar ? "على الموظف" : "Employee"}
                  </Button>
                </div>
              )}
            </li>
          );
        })}
      </ul>
    </section>
  );
}
