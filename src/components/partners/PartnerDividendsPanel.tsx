import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { toast } from "sonner";

import { InfoTip } from "@/components/shared/InfoTip";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { rangeLabel } from "@/core/finance/business-dates";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { formatDate, formatMoney, friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";

type Row = {
  id: string;
  range_from: string | null;
  range_to: string | null;
  distributed_at: string | null;
  share: number;
  tabDeducted: number;
  payout: { id: string; amount: number; created_at: string } | null;
};

/** One partner's dividends, payout by payout: share, partner-tab deduction, cash paid out. */
export function PartnerDividendsPanel({ partnerId }: { partnerId: string }) {
  const { lang } = useI18n();
  const ar = lang === "ar";
  const { me } = useAuth();
  const currency = me?.company?.currency ?? "EGP";
  const qc = useQueryClient();
  const money = (v: number) => formatMoney(v, currency, lang);
  const isAdmin = Boolean(me?.isRoot || me?.roleNames.includes("Super Admin"));
  const [method, setMethod] = useState<"cash" | "bank">("cash");

  const data = useQuery({
    queryKey: ["partner-dividends", partnerId],
    queryFn: async () => {
      const [lines, payouts, deductions] = await Promise.all([
        supabase
          .from("profit_distribution_lines")
          .select("amount, distribution_id, profit_distributions!inner(id, status, distributed_at, range_from, range_to)")
          .eq("partner_id", partnerId)
          .eq("profit_distributions.status", "active")
          .order("created_at", { ascending: false })
          .limit(24),
        supabase.from("partner_dividend_payouts").select("id, distribution_id, amount, created_at").eq("partner_id", partnerId).eq("status", "active"),
        supabase.from("partner_ledger_transactions").select("reference_id, amount").eq("partner_id", partnerId).eq("reference_type", "partner_tab").eq("status", "active"),
      ]);
      if (lines.error) throw lines.error;
      return ((lines.data ?? []) as unknown as Array<{
        amount: number;
        distribution_id: string;
        profit_distributions: { distributed_at: string | null; range_from: string | null; range_to: string | null };
      }>).map<Row>((l) => {
        const p = (payouts.data ?? []).find((x) => x.distribution_id === l.distribution_id);
        return {
          id: l.distribution_id,
          range_from: l.profit_distributions.range_from,
          range_to: l.profit_distributions.range_to,
          distributed_at: l.profit_distributions.distributed_at,
          share: Number(l.amount),
          tabDeducted: -(deductions.data ?? []).filter((d) => d.reference_id === l.distribution_id).reduce((s, d) => s + Number(d.amount), 0),
          payout: p ? { id: p.id, amount: Number(p.amount), created_at: p.created_at } : null,
        };
      });
    },
  });

  const refresh = () => {
    qc.invalidateQueries({ queryKey: ["partner-dividends", partnerId] });
    qc.invalidateQueries({ queryKey: ["partner-statement"] });
    qc.invalidateQueries({ queryKey: ["partners"] });
    qc.invalidateQueries({ queryKey: ["payout-history"] });
  };

  const payout = useMutation({
    mutationFn: async (distributionId: string) => {
      const { error } = await supabase.rpc("payout_partner_dividend", { _distribution_id: distributionId, _partner_id: partnerId, _method: method });
      if (error) throw error;
    },
    onSuccess: () => { toast.success(ar ? "اتصرف الربح للشريك" : "Dividend paid out"); refresh(); },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  const undo = useMutation({
    mutationFn: async (payoutId: string) => {
      const reason = window.prompt(ar ? "سبب عكس الصرف (إلزامي):" : "Reason for reversing this cash payout:");
      if (!reason || reason.trim().length < 5) throw new Error(ar ? "لازم سبب واضح" : "A clear reason is required");
      const { error } = await supabase.rpc("reverse_partner_dividend_payout", { _payout_id: payoutId, _reason: reason.trim() });
      if (error) throw error;
    },
    onSuccess: () => { toast.success(ar ? "اتعكس الصرف ورجعت الفلوس للخزنة" : "Payout reversed and returned to treasury"); refresh(); },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  const rows = data.data ?? [];

  return (
    <div className="grid gap-2 rounded-lg border border-border bg-card p-3">
      <div className="flex items-center gap-1.5">
        <p className="text-sm font-semibold">{ar ? "الأرباح وصرفها" : "Dividends & payout"}</p>
        <InfoTip>
          {ar
            ? "كل سطر هنا توزيع أرباح اتعمل لفترة معينة. بنخصم منه الأول اللي على الشريك من فواتير «على الحساب»، والباقي هو اللي بيتصرف له كاش أو تحويل."
            : "Each row is one profit payout. Partner-tab bills are deducted first; the rest is paid in cash or by transfer."}
        </InfoTip>
      </div>
      {rows.length === 0 && <p className="text-sm text-muted-foreground">{ar ? "لسه مفيش توزيعات للشريك ده" : "No payouts for this partner yet"}</p>}
      {rows.map((r) => {
        const net = Math.max(r.share - r.tabDeducted, 0);
        return (
          <div key={r.id} className="flex flex-wrap items-center justify-between gap-2 border-t border-border pt-2 text-sm first:border-t-0 first:pt-0">
            <div className="min-w-40">
              <p className="font-medium">
                {r.range_from && r.range_to ? rangeLabel(r.range_from, r.range_to, lang) : formatDate(r.distributed_at, lang)}
              </p>
              <p className="text-xs tabular-nums text-muted-foreground">
                {ar ? "الحصة" : "Share"} {money(r.share)} − {ar ? "آجل" : "Tabs"} {money(r.tabDeducted)} = <b className="text-foreground">{money(net)}</b>
              </p>
            </div>
            <div className="flex flex-wrap items-center gap-2">
              {r.payout ? (
                <>
                  <Badge className="bg-primary/15 text-primary">{ar ? "اتصرف" : "Paid"} · {money(r.payout.amount)}</Badge>
                  {isAdmin && (
                    <Button size="sm" variant="ghost" disabled={undo.isPending} onClick={() => undo.mutate(r.payout!.id)}>
                      {ar ? "عكس الصرف" : "Reverse"}
                    </Button>
                  )}
                </>
              ) : (
                isAdmin && (
                  <div className="flex items-center gap-2">
                    <Select value={method} onValueChange={(v) => setMethod(v as "cash" | "bank")}>
                      <SelectTrigger className="h-8 w-44"><SelectValue /></SelectTrigger>
                      <SelectContent>
                        <SelectItem value="cash">{ar ? "كاش من الخزنة" : "Cash from treasury"}</SelectItem>
                        <SelectItem value="bank">{ar ? "تحويل بنكي / إنستاباي" : "Bank / InstaPay"}</SelectItem>
                      </SelectContent>
                    </Select>
                    <Button size="sm" disabled={payout.isPending} onClick={() => payout.mutate(r.id)}>
                      {ar ? "صرف الربح" : "Pay out"}
                    </Button>
                  </div>
                )
              )}
            </div>
          </div>
        );
      })}
    </div>
  );
}
