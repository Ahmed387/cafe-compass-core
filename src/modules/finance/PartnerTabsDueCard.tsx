import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { CircleAlert, HandCoins, Undo2 } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { CollapsibleSection } from "@/components/shared/KpiCard";
import { Badge } from "@/components/ui/badge";
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
import { Textarea } from "@/components/ui/textarea";
import { businessToday } from "@/core/finance/business-dates";
import { settlementPreview, type TabSettleMode } from "@/core/finance/partner-tabs";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { formatDate, formatMoney, friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";

type DuePartner = {
  partner_id: string;
  name: string;
  open: number;
  count: number;
  oldest: string | null;
  balance: number;
};
type RecentSettlement = {
  batch_id: string;
  partner_id: string;
  name: string;
  mode: "payout" | "payment" | "deduct";
  method: string | null;
  amount: number;
  settled_on: string | null;
  status: string;
  notes: string | null;
  created_at: string;
  by: string | null;
};
type Due = { partners: DuePartner[]; recent: RecentSettlement[] };

const METHODS = [
  { key: "cash", ar: "كاش", en: "Cash" },
  { key: "instapay", ar: "انستاباي", en: "InstaPay" },
  { key: "wallet", ar: "محفظة", en: "Wallet" },
  { key: "card", ar: "فيزا", en: "Card" },
];

/**
 * What partners owe for invoices on their account, and settling it: paid now
 * (cash, InstaPay…, into the treasury) or deducted from their balance now.
 * Anything left open is still deducted from their next profit payout.
 */
export function PartnerTabsDueCard() {
  const { lang } = useI18n();
  const ar = lang === "ar";
  const { me, can } = useAuth();
  const currency = me?.company?.currency ?? "EGP";
  const money = (v: number) => formatMoney(Number(v), currency, lang);
  const isSuper = Boolean(me?.roleNames?.includes("Super Admin"));
  const canSee = isSuper || can("treasury.view") || can("reports.profit");
  const canSettle = isSuper || can("treasury.manage");
  const [settling, setSettling] = useState<DuePartner | null>(null);
  const [reversing, setReversing] = useState<RecentSettlement | null>(null);

  const due = useQuery({
    queryKey: ["partner-tabs-due"],
    enabled: canSee,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("partner_tabs_due" as never);
      if (error) throw error;
      return data as unknown as Due;
    },
  });

  if (!canSee || !due.data) return null;
  const partners = due.data.partners ?? [];
  const recent = (due.data.recent ?? []).filter((r) => r.mode !== "payout");
  if (partners.length === 0 && recent.length === 0) return null;
  const totalOpen = partners.reduce((s, p) => s + Number(p.open), 0);

  const modeLabel = (r: RecentSettlement) => {
    if (r.mode === "deduct") return ar ? "اتخصم من رصيده" : "Deducted from balance";
    const m = METHODS.find((x) => x.key === r.method);
    return ar ? `دفع ${m?.ar ?? r.method ?? ""}` : `Paid ${m?.en ?? r.method ?? ""}`;
  };

  return (
    <CollapsibleSection
      title={ar ? "حسابات الشركاء المفتوحة" : "Open partner tabs"}
      description={
        ar
          ? `فواتير على حساب الشركاء لسه ما اتسوتش: ${money(totalOpen)} · اللي مش هيتسوّى بيتخصم من أرباحهم في التوزيع الجاي`
          : `Partner invoices not settled yet: ${money(totalOpen)} · anything left is deducted at the next payout`
      }
      icon={<HandCoins className="h-4 w-4" />}
      className="mb-4"
    >
      <div className="card-surface space-y-2 rounded-xl border border-border bg-card p-4 shadow-sm">
        {partners.length === 0 && (
          <p className="text-sm text-muted-foreground">
            {ar ? "مفيش حساب مفتوح على أي شريك." : "No partner owes anything."}
          </p>
        )}
        {partners.map((p) => (
          <div
            key={p.partner_id}
            className="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-border p-3 text-sm"
          >
            <div className="min-w-0">
              <div className="font-semibold">{p.name}</div>
              <div className="text-xs text-muted-foreground">
                {ar
                  ? `${p.count} فاتورة · من ${p.oldest ? formatDate(p.oldest, lang) : "—"} · رصيده ${money(p.balance)}`
                  : `${p.count} invoices · since ${p.oldest ? formatDate(p.oldest, lang) : "—"} · balance ${money(p.balance)}`}
              </div>
            </div>
            <div className="flex items-center gap-3">
              <span className="font-display text-lg tabular-nums text-destructive">
                {money(p.open)}
              </span>
              {canSettle && (
                <Button size="sm" onClick={() => setSettling(p)}>
                  {ar ? "تسوية" : "Settle"}
                </Button>
              )}
            </div>
          </div>
        ))}

        {recent.length > 0 && (
          <div className="pt-2">
            <p className="mb-2 text-xs font-semibold text-muted-foreground">
              {ar ? "آخر التسويات" : "Recent settlements"}
            </p>
            <div className="space-y-2">
              {recent.slice(0, 8).map((r) => (
                <div
                  key={r.batch_id}
                  className="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-dashed border-border p-2 text-xs"
                >
                  <span className="min-w-0">
                    {r.name} · {modeLabel(r)} ·{" "}
                    {r.settled_on ? formatDate(r.settled_on, lang) : "—"}
                    {r.by ? ` · ${r.by}` : ""}
                    {r.notes ? ` · ${r.notes}` : ""}
                  </span>
                  <span className="flex items-center gap-2">
                    {r.status !== "active" && (
                      <Badge variant="outline">{ar ? "اتلغت" : "Reversed"}</Badge>
                    )}
                    <span
                      className={`tabular-nums font-semibold ${r.status !== "active" ? "line-through text-muted-foreground" : ""}`}
                    >
                      {money(r.amount)}
                    </span>
                    {canSettle && r.status === "active" && (
                      <Button
                        size="sm"
                        variant="ghost"
                        className="h-7 px-2"
                        onClick={() => setReversing(r)}
                      >
                        <Undo2 className="h-3.5 w-3.5" />
                        {ar ? "إلغاء" : "Reverse"}
                      </Button>
                    )}
                  </span>
                </div>
              ))}
            </div>
          </div>
        )}
      </div>

      <SettleDialog
        partner={settling}
        currency={currency}
        lang={lang}
        onClose={() => setSettling(null)}
      />
      <ReverseDialog
        row={reversing}
        currency={currency}
        lang={lang}
        onClose={() => setReversing(null)}
      />
    </CollapsibleSection>
  );
}

function invalidateAll(qc: ReturnType<typeof useQueryClient>) {
  for (const key of [
    "partner-tabs-due",
    "partner-tab-orders",
    "treasury-overview",
    "treasury-movements",
    "treasury-flow",
    "payout-preview",
    "my-partner-dashboard",
  ]) {
    qc.invalidateQueries({ queryKey: [key] });
  }
}

function SettleDialog({
  partner,
  currency,
  lang,
  onClose,
}: {
  partner: DuePartner | null;
  currency: string;
  lang: "ar" | "en";
  onClose: () => void;
}) {
  const ar = lang === "ar";
  const qc = useQueryClient();
  const money = (v: number) => formatMoney(Number(v), currency, lang);
  const [mode, setMode] = useState<TabSettleMode>("payment");
  const [method, setMethod] = useState("cash");
  const [amount, setAmount] = useState("");
  const [day, setDay] = useState(businessToday());
  const [notes, setNotes] = useState("");

  const open = Number(partner?.open ?? 0);
  const balance = Number(partner?.balance ?? 0);
  const pv = settlementPreview({ open, balance, amount: Number(amount), mode });

  const reset = () => {
    setMode("payment");
    setMethod("cash");
    setAmount("");
    setDay(businessToday());
    setNotes("");
  };

  const save = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc(
        "settle_partner_tab" as never,
        {
          _partner_id: partner!.partner_id,
          _amount: pv.amount,
          _mode: mode,
          _method: method,
          _settled_on: day,
          _notes: notes.trim() || null,
        } as never,
      );
      if (error) throw error;
      return data as unknown as { open_after: number };
    },
    onSuccess: (res) => {
      toast.success(
        ar
          ? `اتسجلت التسوية · المتبقي على الشريك ${money(res.open_after)}`
          : `Settlement saved · still open ${money(res.open_after)}`,
      );
      invalidateAll(qc);
      reset();
      onClose();
    },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  return (
    <Dialog open={Boolean(partner)} onOpenChange={(o) => !o && (reset(), onClose())}>
      <DialogContent className="max-w-lg">
        <DialogHeader>
          <DialogTitle>
            {ar ? `تسوية حساب ${partner?.name ?? ""}` : `Settle ${partner?.name ?? ""}'s tab`}
          </DialogTitle>
          <DialogDescription>
            {ar
              ? `عليه ${money(open)} · ممكن تسوّي جزء منه بس، والأقدم بيتقفل الأول`
              : `Owes ${money(open)} · a part is fine, oldest invoices close first`}
          </DialogDescription>
        </DialogHeader>

        <div className="grid gap-3 text-sm">
          <div className="grid grid-cols-2 gap-2">
            <Button
              type="button"
              variant={mode === "payment" ? "default" : "outline"}
              onClick={() => setMode("payment")}
            >
              {ar ? "دفع دلوقتي" : "Pays now"}
            </Button>
            <Button
              type="button"
              variant={mode === "deduct" ? "default" : "outline"}
              onClick={() => setMode("deduct")}
            >
              {ar ? "خصم من رصيده" : "Deduct from balance"}
            </Button>
          </div>

          <div className="grid gap-3 sm:grid-cols-2">
            <div className="grid gap-1">
              <Label htmlFor="tab-amount">{ar ? "المبلغ" : "Amount"}</Label>
              <div className="flex gap-2">
                <Input
                  id="tab-amount"
                  inputMode="decimal"
                  value={amount}
                  onChange={(e) => setAmount(e.target.value)}
                />
                <Button type="button" variant="outline" onClick={() => setAmount(String(open))}>
                  {ar ? "الكل" : "All"}
                </Button>
              </div>
            </div>
            <div className="grid gap-1">
              <Label htmlFor="tab-day">{ar ? "تاريخ التسوية" : "Date"}</Label>
              <Input
                id="tab-day"
                type="date"
                value={day}
                max={businessToday()}
                onChange={(e) => setDay(e.target.value)}
              />
            </div>
          </div>

          {mode === "payment" && (
            <div className="grid gap-1">
              <Label>{ar ? "طريقة الدفع" : "Method"}</Label>
              <Select value={method} onValueChange={setMethod}>
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {METHODS.map((m) => (
                    <SelectItem key={m.key} value={m.key}>
                      {ar ? m.ar : m.en}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          )}

          <div className="grid gap-1">
            <Label htmlFor="tab-notes">{ar ? "ملاحظة (اختياري)" : "Note (optional)"}</Label>
            <Textarea id="tab-notes" value={notes} onChange={(e) => setNotes(e.target.value)} />
          </div>

          <div className="rounded-lg border border-border bg-muted/40 p-3">
            <p className="mb-2 font-semibold">{ar ? "اللي هيحصل:" : "What happens:"}</p>
            {pv.error === "amount" && (
              <p className="text-muted-foreground">{ar ? "اكتب المبلغ." : "Enter an amount."}</p>
            )}
            {pv.error === "over" && (
              <p className="text-destructive">
                {ar ? `المبلغ أكبر من المستحق (${money(open)})` : `More than owed (${money(open)})`}
              </p>
            )}
            {pv.ok && (
              <ul className="list-disc space-y-1 ps-5 text-muted-foreground">
                <li>
                  {ar
                    ? `المتبقي على الشريك: ${money(pv.openAfter)}`
                    : `Still open: ${money(pv.openAfter)}`}
                </li>
                {mode === "payment" ? (
                  <li>
                    {ar
                      ? `الخزنة بتزيد ${money(pv.treasuryIn)} (سداد حساب شريك)`
                      : `Treasury gets ${money(pv.treasuryIn)} (partner tab payment)`}
                  </li>
                ) : (
                  <li>
                    {ar
                      ? `رصيده بيقل من ${money(balance)} لـ ${money(pv.balanceAfter)} · الخزنة مبتتغيرش`
                      : `Balance goes from ${money(balance)} to ${money(pv.balanceAfter)} · treasury unchanged`}
                  </li>
                )}
                <li>
                  {ar
                    ? `التوزيع الجاي هيخصم منه ${money(pv.nextPayoutDeducts)} بس`
                    : `Next payout deducts only ${money(pv.nextPayoutDeducts)}`}
                </li>
                <li>
                  {ar
                    ? "المبيعات وصافي الربح مبيتغيروش (اتحسبوا يوم البيع)"
                    : "Sales and net profit don't change (counted on the sale day)"}
                </li>
              </ul>
            )}
            {pv.balanceGoesNegative && (
              <p className="mt-2 flex items-start gap-2 text-destructive">
                <CircleAlert className="mt-0.5 h-4 w-4 shrink-0" />
                {ar
                  ? "رصيد الشريك هيبقى بالسالب، يعني هو مديون للمكان."
                  : "The partner's balance goes negative: they will owe the business."}
              </p>
            )}
          </div>
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => (reset(), onClose())}>
            {ar ? "رجوع" : "Back"}
          </Button>
          <Button disabled={!pv.ok || !day || save.isPending} onClick={() => save.mutate()}>
            {ar ? "تأكيد التسوية" : "Confirm"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function ReverseDialog({
  row,
  currency,
  lang,
  onClose,
}: {
  row: RecentSettlement | null;
  currency: string;
  lang: "ar" | "en";
  onClose: () => void;
}) {
  const ar = lang === "ar";
  const qc = useQueryClient();
  const [reason, setReason] = useState("");
  const save = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc(
        "reverse_partner_tab_settlement" as never,
        { _batch_id: row!.batch_id, _reason: reason } as never,
      );
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success(
        ar ? "التسوية اتلغت والفواتير رجعت مفتوحة" : "Settlement reversed, invoices are open again",
      );
      invalidateAll(qc);
      setReason("");
      onClose();
    },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  return (
    <Dialog open={Boolean(row)} onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>{ar ? "إلغاء التسوية" : "Reverse settlement"}</DialogTitle>
          <DialogDescription>
            {row &&
              (ar
                ? `${row.name} · ${formatMoney(row.amount, currency, lang)} · بيتسجل قيد عكسي ومفيش حاجة بتتمسح`
                : `${row.name} · ${formatMoney(row.amount, currency, lang)} · an opposite entry is recorded, nothing is deleted`)}
          </DialogDescription>
        </DialogHeader>
        <div className="grid gap-1 text-sm">
          <Label htmlFor="tab-reverse">{ar ? "السبب (بيتسجل)" : "Reason (recorded)"}</Label>
          <Textarea id="tab-reverse" value={reason} onChange={(e) => setReason(e.target.value)} />
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            {ar ? "رجوع" : "Back"}
          </Button>
          <Button
            variant="destructive"
            disabled={reason.trim().length < 3 || save.isPending}
            onClick={() => save.mutate()}
          >
            {ar ? "تأكيد الإلغاء" : "Reverse"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
