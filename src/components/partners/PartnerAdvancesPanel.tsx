import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { toast } from "sonner";

import { InfoTip } from "@/components/shared/InfoTip";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { businessToday } from "@/core/finance/business-dates";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { formatDate, formatMoney, friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { SectionTitle } from "@/components/shared/SectionTitle";

/** Partner advances (سلف): money taken ahead of profit, recovered automatically from the next payouts. */
export function PartnerAdvancesPanel({ partnerId }: { partnerId: string }) {
  const { lang } = useI18n();
  const ar = lang === "ar";
  const { me } = useAuth();
  const currency = me?.company?.currency ?? "EGP";
  const money = (v: number) => formatMoney(v, currency, lang);
  const isAdmin = Boolean(me?.isRoot || me?.roleNames.includes("Super Admin"));
  const qc = useQueryClient();
  const [amount, setAmount] = useState("");
  const [method, setMethod] = useState<"cash" | "bank">("cash");
  const [reason, setReason] = useState("");
  const [date, setDate] = useState(businessToday());

  const list = useQuery({
    queryKey: ["partner-advances", partnerId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("partner_advances")
        .select("id, amount, deducted_amount, advance_date, method, reason, status")
        .eq("partner_id", partnerId)
        .order("advance_date", { ascending: false })
        .limit(50);
      if (error) throw error;
      return data ?? [];
    },
  });

  const refresh = () => {
    for (const key of ["partner-advances", "partners", "partner-statement", "payout-preview"]) qc.invalidateQueries({ queryKey: [key] });
  };

  const give = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc("record_partner_advance", {
        _partner_id: partnerId, _amount: Number(amount), _method: method, _advance_date: date,
        ...(reason.trim() ? { _reason: reason.trim() } : {}),
      });
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success(ar ? "اتسجلت السلفة وخرجت من الخزنة" : "Advance recorded");
      setAmount(""); setReason("");
      refresh();
    },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  const cancel = useMutation({
    mutationFn: async (id: string) => {
      const why = window.prompt(ar ? "سبب إلغاء السلفة:" : "Reason for cancelling:");
      if (!why || why.trim().length < 3) throw new Error(ar ? "لازم سبب" : "A reason is required");
      const { error } = await supabase.rpc("cancel_partner_advance", { _advance_id: id, _reason: why.trim() });
      if (error) throw error;
    },
    onSuccess: () => { toast.success(ar ? "اتلغت السلفة ورجعت الفلوس للخزنة" : "Advance cancelled"); refresh(); },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  const rows = (list.data ?? []).filter((a) => a.status === "active");
  const open = rows.reduce((s, a) => s + Number(a.amount) - Number(a.deducted_amount), 0);

  return (
    <div className="grid gap-3 rounded-lg border border-border bg-card p-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex items-center gap-1.5">
          <SectionTitle as="p" className="text-sm">{ar ? "سلف الشريك" : "Partner advances"}</SectionTitle>
          <InfoTip title={ar ? "ليه السلف هنا؟" : "Why advances?"}>
            {ar
              ? "لو الشريك أخد فلوس قبل التوزيع، بتتسجل هنا وتخرج من الخزنة. مع أول توزيع أرباح بتتخصم من نصيبه تلقائياً (بعد فواتيره على الحساب)، ولو نصيبه مكفاش الباقي بيترحّل للتوزيع اللي بعده."
              : "Money a partner takes before a payout. It's recovered automatically from their next payouts (after their tab); anything left carries forward."}
          </InfoTip>
        </div>
        <Badge variant={open > 0 ? "outline" : "secondary"} className={open > 0 ? "border-amber-400 text-amber-700 dark:text-amber-300" : ""}>
          {ar ? "باقي عليه" : "Outstanding"}: {money(open)}
        </Badge>
      </div>

      {isAdmin && (
        <div className="grid gap-2 sm:grid-cols-[120px_130px_140px_1fr_auto] sm:items-end">
          <div className="space-y-1">
            <Label htmlFor={`adv-amt-${partnerId}`} className="text-xs">{ar ? "المبلغ" : "Amount"}</Label>
            <Input id={`adv-amt-${partnerId}`} inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} />
          </div>
          <div className="space-y-1">
            <Label className="text-xs">{ar ? "اتصرفت منين" : "Paid from"}</Label>
            <Select value={method} onValueChange={(v) => setMethod(v as "cash" | "bank")}>
              <SelectTrigger><SelectValue /></SelectTrigger>
              <SelectContent>
                <SelectItem value="cash">{ar ? "كاش من الخزنة" : "Cash"}</SelectItem>
                <SelectItem value="bank">{ar ? "تحويل بنكي" : "Bank"}</SelectItem>
              </SelectContent>
            </Select>
          </div>
          <div className="space-y-1">
            <Label htmlFor={`adv-date-${partnerId}`} className="text-xs">{ar ? "التاريخ" : "Date"}</Label>
            <Input id={`adv-date-${partnerId}`} type="date" value={date} max={businessToday()} onChange={(e) => setDate(e.target.value)} />
          </div>
          <div className="space-y-1">
            <Label htmlFor={`adv-why-${partnerId}`} className="text-xs">{ar ? "ملاحظة" : "Note"}</Label>
            <Input id={`adv-why-${partnerId}`} value={reason} onChange={(e) => setReason(e.target.value)} />
          </div>
          <Button disabled={!(Number(amount) > 0) || give.isPending} onClick={() => give.mutate()}>
            {ar ? "سجّل سلفة" : "Record advance"}
          </Button>
        </div>
      )}

      {rows.length === 0 ? (
        <p className="text-sm text-muted-foreground">{ar ? "مفيش سلف مفتوحة" : "No advances"}</p>
      ) : (
        <ul className="divide-y text-sm">
          {rows.map((a) => {
            const left = Number(a.amount) - Number(a.deducted_amount);
            return (
              <li key={a.id} className="flex flex-wrap items-center justify-between gap-2 py-2">
                <span>
                  {formatDate(a.advance_date, lang)} · <b className="tabular-nums">{money(Number(a.amount))}</b>
                  {a.reason && <span className="ms-1 text-xs text-muted-foreground">({a.reason})</span>}
                </span>
                <span className="flex items-center gap-2">
                  <span className="text-xs tabular-nums text-muted-foreground">
                    {ar ? "اتخصم" : "Recovered"} {money(Number(a.deducted_amount))} · {ar ? "باقي" : "Left"} {money(left)}
                  </span>
                  {isAdmin && Number(a.deducted_amount) === 0 && (
                    <Button size="sm" variant="ghost" disabled={cancel.isPending} onClick={() => cancel.mutate(a.id)}>
                      {ar ? "إلغاء" : "Cancel"}
                    </Button>
                  )}
                </span>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
