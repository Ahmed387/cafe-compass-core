import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Undo2 } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { supabase } from "@/integrations/supabase/client";
import { formatMoney, friendlyError } from "@/lib/format";

type Fault = "venue" | "staff" | "all_staff";

type RefundRow = {
  id: string;
  amount: number;
  reason: string | null;
  fault: string | null;
  blamed_staff_id: string | null;
  method_key: string | null;
  orders: { order_number: string } | null;
};

const FAULT_LABEL: Record<string, { ar: string; en: string }> = {
  venue: { ar: "على الكافيه", en: "Cafe" },
  business: { ar: "على الكافيه", en: "Cafe" },
  all_staff: { ar: "تيم الوردية", en: "Shift team" },
  staff: { ar: "موظف", en: "Employee" },
};

/**
 * Closed shift: the manager (or super admin) can change who bears each refund
 * after the cashier closed it. Penalties already taken in payroll stay put.
 */
export function ShiftRefundBearersButton({ shiftId, currency, lang }: { shiftId: string; currency: string; lang: "ar" | "en" }) {
  const ar = lang === "ar";
  const qc = useQueryClient();
  const [open, setOpen] = useState(false);
  const [staffFor, setStaffFor] = useState<Record<string, string>>({});

  const refunds = useQuery({
    queryKey: ["shift-refunds-bearers", shiftId],
    enabled: open,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("order_refunds")
        .select("id, amount, reason, fault, blamed_staff_id, method_key, orders(order_number)" as "id")
        .eq("shift_id", shiftId)
        .eq("status", "active")
        .order("created_at");
      if (error) throw error;
      return (data ?? []) as unknown as RefundRow[];
    },
  });

  const staff = useQuery({
    queryKey: ["shift-refunds-staff"],
    enabled: open,
    staleTime: 5 * 60_000,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("user_profiles")
        .select("id, display_name, first_name, last_name")
        .eq("is_active", true)
        .order("first_name");
      if (error) throw error;
      return (data ?? []).map((p) => ({
        id: p.id,
        name: p.display_name || [p.first_name, p.last_name].filter(Boolean).join(" ") || p.id.slice(0, 6),
      }));
    },
  });
  const staffName = (id: string | null) => staff.data?.find((s) => s.id === id)?.name ?? "";

  const change = useMutation({
    mutationFn: async (v: { refundId: string; fault: Fault; staffId?: string }) => {
      const { error } = await supabase.rpc(
        "reassign_refund_bearer" as never,
        { _refund_id: v.refundId, _fault: v.fault, _staff_id: v.staffId ?? null, _reason: null } as never,
      );
      if (error) throw error;
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ["shift-refunds-bearers", shiftId] });
      toast.success(ar ? "اتغيّر مين يتحمل المرتجع" : "Bearer changed");
    },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  return (
    <>
      <Button size="sm" variant="ghost" className="gap-1 text-xs" onClick={() => setOpen(true)}>
        <Undo2 className="size-3.5" />
        {ar ? "المرتجعات" : "Refunds"}
      </Button>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="max-h-[85vh] overflow-y-auto">
          <DialogHeader>
            <DialogTitle>{ar ? "مين يتحمل مرتجعات الوردية" : "Who bears this shift's refunds"}</DialogTitle>
          </DialogHeader>
          {refunds.isLoading ? (
            <p className="text-sm text-muted-foreground">{ar ? "بيحمّل…" : "Loading…"}</p>
          ) : refunds.isError ? (
            <p className="text-sm text-destructive">{friendlyError(refunds.error, lang)}</p>
          ) : (refunds.data ?? []).length === 0 ? (
            <p className="text-sm text-muted-foreground">{ar ? "مفيش مرتجعات في الوردية دي." : "No refunds in this shift."}</p>
          ) : (
            <ul className="space-y-2">
              {(refunds.data ?? []).map((r) => {
                const busy = change.isPending && change.variables?.refundId === r.id;
                const label = FAULT_LABEL[r.fault ?? ""];
                const chosen = staffFor[r.id] ?? "";
                const tab = r.method_key === "partner_tab";
                return (
                  <li key={r.id} className="space-y-2 rounded-xl border border-border p-3">
                    <div className="flex flex-wrap items-baseline justify-between gap-2">
                      <span className="font-semibold">
                        {ar ? "فاتورة" : "Invoice"} #{r.orders?.order_number ?? "—"}
                      </span>
                      <span className="font-bold tabular-nums">{formatMoney(Number(r.amount), currency, lang)}</span>
                    </div>
                    {r.reason && <p className="text-xs text-muted-foreground">{r.reason}</p>}
                    <p className="text-xs">
                      {ar ? "دلوقتي: " : "Now: "}
                      <Badge variant="secondary">
                        {label ? label[lang] : ar ? "لسه متحددش" : "Not set"}
                        {r.fault === "staff" && staffName(r.blamed_staff_id) ? ` · ${staffName(r.blamed_staff_id)}` : ""}
                      </Badge>
                    </p>
                    {!tab && (
                      <div className="flex flex-wrap items-center gap-2">
                        <Button size="sm" variant="outline" disabled={busy} onClick={() => change.mutate({ refundId: r.id, fault: "venue" })}>
                          {ar ? "على الكافيه" : "Cafe"}
                        </Button>
                        <Button size="sm" variant="outline" disabled={busy} onClick={() => change.mutate({ refundId: r.id, fault: "all_staff" })}>
                          {ar ? "تيم الوردية" : "Shift team"}
                        </Button>
                        <select
                          aria-label={ar ? "الموظف" : "Employee"}
                          className="h-9 min-w-0 flex-1 rounded-md border border-input bg-background px-2 text-sm"
                          value={chosen}
                          onChange={(e) => setStaffFor((s) => ({ ...s, [r.id]: e.target.value }))}
                        >
                          <option value="">{ar ? "اختار موظف…" : "Choose employee…"}</option>
                          {(staff.data ?? []).map((p) => (
                            <option key={p.id} value={p.id}>{p.name}</option>
                          ))}
                        </select>
                        <Button
                          size="sm"
                          disabled={busy || !chosen}
                          onClick={() => change.mutate({ refundId: r.id, fault: "staff", staffId: chosen })}
                        >
                          {ar ? "على الموظف" : "Employee"}
                        </Button>
                      </div>
                    )}
                  </li>
                );
              })}
            </ul>
          )}
        </DialogContent>
      </Dialog>
    </>
  );
}
