import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { AlertTriangle, Scale } from "lucide-react";
import { useMemo, useState } from "react";
import { toast } from "sonner";

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
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { supabase } from "@/integrations/supabase/client";
import { formatMoney, formatPercent, friendlyError } from "@/lib/format";

export type LiquidationPartner = {
  id: string;
  name: string;
  status: string;
  profit_share_percentage: number | null;
};

export function PartnerLiquidationDialog({
  partner,
  partners,
  balance,
  currency,
  lang,
  onClose,
}: {
  partner: LiquidationPartner | null;
  partners: LiquidationPartner[];
  balance: number;
  currency: string;
  lang: "ar" | "en";
  onClose: () => void;
}) {
  const ar = lang === "ar";
  const queryClient = useQueryClient();
  const [method, setMethod] = useState<"treasury" | "bank" | "ledger">("ledger");
  const [accountId, setAccountId] = useState("");
  const [notes, setNotes] = useState("");
  const [confirmed, setConfirmed] = useState(false);

  const accounts = useQuery({
    queryKey: ["liquidation-cash-accounts"],
    enabled: Boolean(partner) && method === "treasury",
    queryFn: async () => {
      const { data, error } = await supabase
        .from("cash_accounts")
        .select("id,name,name_ar")
        .eq("is_active", true)
        .order("is_default", { ascending: false });
      if (error) throw error;
      return data ?? [];
    },
  });

  const redistribution = useMemo(() => {
    if (!partner) return [];
    const remaining = partners.filter((row) => row.status === "active" && row.id !== partner.id);
    const total = remaining.reduce((sum, row) => sum + Number(row.profit_share_percentage ?? 0), 0);
    let running = 0;
    return remaining.map((row, index) => {
      const share =
        index === remaining.length - 1
          ? Math.round((100 - running) * 10_000) / 10_000
          : Math.round(((Number(row.profit_share_percentage ?? 0) / total) * 100) * 10_000) / 10_000;
      running += share;
      return { id: row.id, name: row.name, share };
    });
  }, [partner, partners]);

  const liquidate = useMutation({
    mutationFn: async () => {
      if (!partner) return;
      const { error } = await supabase.rpc("liquidate_partner", {
        _partner_id: partner.id,
        _settlement_method: method,
        ...(method === "treasury" ? { _cash_account_id: accountId } : {}),
        ...(notes.trim() ? { _notes: notes.trim() } : {}),
      });
      if (error) throw error;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["partners"] });
      queryClient.invalidateQueries({ queryKey: ["treasury-overview"] });
      queryClient.invalidateQueries({ queryKey: ["withdrawal-requests"] });
      toast.success(ar ? "تمت تصفية الشراكة وإعادة توزيع الحصص." : "Partnership liquidated and equity redistributed.");
      setMethod("ledger");
      setAccountId("");
      setNotes("");
      setConfirmed(false);
      onClose();
    },
    onError: (error) => toast.error(friendlyError(error, lang)),
  });

  return (
    <Dialog
      open={Boolean(partner)}
      onOpenChange={(open) => {
        if (!open && !liquidate.isPending) onClose();
      }}
    >
      <DialogContent className="max-h-[88vh] max-w-xl overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{ar ? "تصفية الشراكة" : "Partnership liquidation"}</DialogTitle>
        </DialogHeader>

        <div className="space-y-4">
          <div className="rounded-lg border border-destructive/40 bg-destructive/10 p-3">
            <p className="flex items-center gap-2 font-semibold text-destructive">
              <AlertTriangle className="size-4" /> {partner?.name}
            </p>
            <p className="mt-1 text-sm text-muted-foreground">
              {ar
                ? "سيصبح الشريك غير نشط مع الاحتفاظ بكل السجلات السابقة. لا يمكن التنفيذ مع طلب سحب أو حساب شريك غير مسوّى."
                : "The partner becomes inactive while all history remains. Pending withdrawals or unsettled partner tabs block completion."}
            </p>
          </div>

          <div className="grid gap-3 sm:grid-cols-2">
            <div className="rounded-lg border border-border bg-muted p-3">
              <p className="text-xs text-muted-foreground">{ar ? "الرصيد النهائي" : "Final balance"}</p>
              <p className="mt-1 text-xl font-bold tabular-nums">{formatMoney(balance, currency, lang)}</p>
            </div>
            <div className="rounded-lg border border-border bg-muted p-3">
              <p className="text-xs text-muted-foreground">{ar ? "الحصة الحالية" : "Current equity"}</p>
              <p className="mt-1 text-xl font-bold tabular-nums">
                {formatPercent(partner?.profit_share_percentage ?? 0, lang)}
              </p>
            </div>
          </div>

          <div className="space-y-2">
            <Label>{ar ? "طريقة تسوية الرصيد النهائي" : "Final settlement method"}</Label>
            <Select value={method} onValueChange={(value) => setMethod(value as typeof method)}>
              <SelectTrigger className="h-11"><SelectValue /></SelectTrigger>
              <SelectContent>
                <SelectItem value="treasury">{ar ? "كاش من الخزينة" : "Treasury cash"}</SelectItem>
                <SelectItem value="bank">{ar ? "تحويل بنكي" : "Bank transfer"}</SelectItem>
                <SelectItem value="ledger">{ar ? "قيد دفتري فقط" : "Ledger only"}</SelectItem>
              </SelectContent>
            </Select>
          </div>

          {method === "treasury" && (
            <div className="space-y-2">
              <Label>{ar ? "الخزينة الدافعة" : "Paying treasury"}</Label>
              <Select value={accountId} onValueChange={setAccountId}>
                <SelectTrigger className="h-11">
                  <SelectValue placeholder={ar ? "اختر الخزينة" : "Select treasury"} />
                </SelectTrigger>
                <SelectContent>
                  {(accounts.data ?? []).map((account) => (
                    <SelectItem key={account.id} value={account.id}>
                      {ar ? account.name_ar || account.name : account.name}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          )}

          <div className="space-y-2 rounded-lg border border-border p-3">
            <p className="flex items-center gap-2 text-sm font-semibold">
              <Scale className="size-4 text-primary" /> {ar ? "معاينة إعادة توزيع الحصص" : "Equity redistribution preview"}
            </p>
            {redistribution.map((row) => (
              <div key={row.id} className="flex items-center justify-between text-sm">
                <span>{row.name}</span>
                <span className="font-semibold tabular-nums">{formatPercent(row.share, lang)}</span>
              </div>
            ))}
            {redistribution.length === 0 && (
              <p className="text-sm text-destructive">
                {ar ? "يلزم وجود شريك نشط آخر بحصة موجبة." : "Another active partner with positive equity is required."}
              </p>
            )}
          </div>

          <div className="space-y-2">
            <Label>{ar ? "ملاحظات التسوية" : "Settlement notes"}</Label>
            <Input value={notes} onChange={(event) => setNotes(event.target.value)} />
          </div>

          <label className="flex cursor-pointer items-start gap-3 rounded-lg border border-border p-3 text-sm">
            <input
              type="checkbox"
              className="mt-1 size-4 accent-primary"
              checked={confirmed}
              onChange={(event) => setConfirmed(event.target.checked)}
            />
            <span>
              {ar
                ? "أؤكد الرصيد النهائي وطريقة التسوية وإعادة توزيع الحصص الموضحة أعلاه."
                : "I confirm the final balance, settlement method, and equity redistribution above."}
            </span>
          </label>
        </div>

        <DialogFooter className="gap-2">
          <Button variant="outline" onClick={onClose} disabled={liquidate.isPending}>
            {ar ? "إلغاء" : "Cancel"}
          </Button>
          <Button
            variant="destructive"
            disabled={
              liquidate.isPending ||
              !confirmed ||
              redistribution.length === 0 ||
              (method === "treasury" && !accountId)
            }
            onClick={() => liquidate.mutate()}
          >
            {liquidate.isPending ? (ar ? "جارٍ التنفيذ…" : "Processing…") : (ar ? "تنفيذ التصفية" : "Complete liquidation")}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}