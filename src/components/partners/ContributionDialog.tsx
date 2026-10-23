import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { ArrowLeft, ArrowRight, HandCoins, Landmark } from "lucide-react";
import { useEffect, useState } from "react";
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
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { businessToday } from "@/core/finance/business-dates";
import { supabase } from "@/integrations/supabase/client";
import { formatDate, formatMoney, formatPercent, friendlyError } from "@/lib/format";
import { cn } from "@/lib/utils";

type Kind = "capital" | "loan";

type Preview = {
  kind: Kind;
  contribution_date: string;
  effective_from: string;
  old_until: string;
  partners: Array<{ partner_id: string; name: string; old_pct: number; new_pct: number }>;
};

const KINDS: Record<
  Kind,
  { icon: typeof Landmark; ar: string; en: string; arHint: string; enHint: string }
> = {
  capital: {
    icon: Landmark,
    ar: "رأس مال",
    en: "Capital",
    arHint:
      "بيزود نسبته في المكان. النسب الحالية تفضل لآخر الشهر، والجديدة تبدأ من أول الشهر اللي بعده.",
    enHint:
      "Raises the partner's share. Current shares stay to the end of the month; new ones start on the 1st of next month.",
  },
  loan: {
    icon: HandCoins,
    ar: "قرض للمكان",
    en: "Loan to the café",
    arHint: "نسبته مش هتتغير. الفلوس بترجع له من الأرباح قبل ما تتوزع على الشركاء.",
    enHint: "Shares stay the same. The money is paid back from profit before partners are paid.",
  },
};

function useDebounced<T>(value: T, ms = 350): T {
  const [v, setV] = useState(value);
  useEffect(() => {
    const id = setTimeout(() => setV(value), ms);
    return () => clearTimeout(id);
  }, [value, ms]);
  return v;
}

/** Super admin: record a partner contribution as capital (changes shares from next month) or a loan. */
export function ContributionDialog({
  partner,
  onClose,
  currency,
  lang,
}: {
  partner: { id: string; name: string } | null;
  onClose: () => void;
  currency: string;
  lang: "ar" | "en";
}) {
  const ar = lang === "ar";
  const qc = useQueryClient();
  const [kind, setKind] = useState<Kind | null>(null);
  const [amount, setAmount] = useState("");
  const [date, setDate] = useState(businessToday());
  const [reference, setReference] = useState("");

  useEffect(() => {
    if (!partner) return;
    setKind(null);
    setAmount("");
    setDate(businessToday());
    setReference("");
  }, [partner]);

  const value = Number(amount);
  const valid = Boolean(partner && kind && Number.isFinite(value) && value > 0 && date);
  const debounced = useDebounced({ kind, value, date });

  const preview = useQuery({
    queryKey: [
      "contribution-preview",
      partner?.id,
      debounced.kind,
      debounced.value,
      debounced.date,
    ],
    enabled: Boolean(partner && debounced.kind && debounced.value > 0 && debounced.date),
    queryFn: async (): Promise<Preview> => {
      const { data, error } = await supabase.rpc("preview_partner_contribution", {
        _partner_id: partner!.id,
        _amount: debounced.value,
        _kind: debounced.kind!,
        _contribution_date: debounced.date,
      });
      if (error) throw error;
      return data as unknown as Preview;
    },
  });

  const save = useMutation({
    mutationFn: async () => {
      if (!valid) throw new Error("Invalid amount");
      const { error } = await supabase.rpc("record_partner_contribution", {
        _partner_id: partner!.id,
        _amount: value,
        _kind: kind!,
        _contribution_date: date,
        ...(reference.trim() ? { _reference: reference.trim() } : {}),
      });
      if (error) throw error;
    },
    onSuccess: () => {
      ["partners", "notifications", "payout-preview"].forEach((k) =>
        qc.invalidateQueries({ queryKey: [k] }),
      );
      toast.success(
        kind === "loan"
          ? ar
            ? "اتسجل القرض. هيترد من الأرباح قبل التوزيع."
            : "Loan recorded. It is repaid from profit before payouts."
          : ar
            ? "اتسجلت المساهمة. النسب الجديدة هتبدأ من أول الشهر الجاي."
            : "Contribution recorded. New shares start next month.",
      );
      onClose();
    },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  const p = preview.data;
  const fresh = p && p.kind === kind && debounced.value === value && debounced.date === date;
  const Arrow = ar ? ArrowLeft : ArrowRight;
  const me = p?.partners.find((r) => r.partner_id === partner?.id);

  return (
    <Dialog open={Boolean(partner)} onOpenChange={(open) => !open && onClose()}>
      <DialogContent dir={ar ? "rtl" : "ltr"} className="max-h-[90vh] overflow-y-auto sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>
            {ar
              ? `تسجيل مساهمة: ${partner?.name ?? ""}`
              : `Record contribution: ${partner?.name ?? ""}`}
          </DialogTitle>
          <DialogDescription>
            {ar ? "الفلوس دي رأس مال ولا قرض؟" : "Is this money capital or a loan?"}
          </DialogDescription>
        </DialogHeader>

        <div role="radiogroup" className="grid gap-2 sm:grid-cols-2">
          {(Object.keys(KINDS) as Kind[]).map((k) => {
            const K = KINDS[k];
            const on = kind === k;
            return (
              <button
                key={k}
                type="button"
                role="radio"
                aria-checked={on}
                onClick={() => setKind(k)}
                className={cn(
                  "rounded-xl border p-3 text-start transition-colors",
                  on ? "border-primary bg-primary/5 ring-1 ring-primary" : "hover:bg-muted/50",
                )}
              >
                <span className="flex items-center gap-2 font-semibold">
                  <K.icon className="size-4 text-primary" aria-hidden />
                  {ar ? K.ar : K.en}
                </span>
                <span className="mt-1 block text-xs leading-5 text-muted-foreground">
                  {ar ? K.arHint : K.enHint}
                </span>
              </button>
            );
          })}
        </div>

        <div className="grid gap-3 sm:grid-cols-2">
          <div className="space-y-1">
            <Label htmlFor="pc-amount">{ar ? "المبلغ" : "Amount"}</Label>
            <Input
              id="pc-amount"
              type="number"
              min="0.01"
              step="0.01"
              inputMode="decimal"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
            />
          </div>
          <div className="space-y-1">
            <Label htmlFor="pc-date">{ar ? "تاريخ الدفع" : "Date paid"}</Label>
            <Input
              id="pc-date"
              type="date"
              value={date}
              onChange={(e) => setDate(e.target.value)}
            />
          </div>
          <div className="space-y-1 sm:col-span-2">
            <Label htmlFor="pc-ref">
              {ar ? "مرجع أو ملاحظة (اختياري)" : "Reference (optional)"}
            </Label>
            <Input id="pc-ref" value={reference} onChange={(e) => setReference(e.target.value)} />
          </div>
        </div>

        {kind && value > 0 && (
          <div className="space-y-3 rounded-xl border bg-muted/30 p-3 text-sm">
            {!fresh ? (
              <p className="text-muted-foreground">{ar ? "بنحسب النسب…" : "Calculating shares…"}</p>
            ) : kind === "capital" ? (
              <>
                <p className="leading-6">
                  {ar
                    ? `نسبة ${partner?.name} هتفضل ${formatPercent(me?.old_pct ?? 0, lang)} لحد ${formatDate(p.old_until, lang)}، وتبقى ${formatPercent(me?.new_pct ?? 0, lang)} من ${formatDate(p.effective_from, lang)}.`
                    : `${partner?.name} stays at ${formatPercent(me?.old_pct ?? 0, lang)} until ${formatDate(p.old_until, lang)}, then ${formatPercent(me?.new_pct ?? 0, lang)} from ${formatDate(p.effective_from, lang)}.`}
                </p>
                <table className="w-full text-sm">
                  <thead className="text-xs text-muted-foreground">
                    <tr>
                      <th className="py-1 text-start font-medium">{ar ? "الشريك" : "Partner"}</th>
                      <th className="py-1 text-center font-medium">
                        {ar
                          ? `لحد ${formatDate(p.old_until, lang)}`
                          : `Until ${formatDate(p.old_until, lang)}`}
                      </th>
                      <th aria-hidden />
                      <th className="py-1 text-center font-medium">
                        {ar
                          ? `من ${formatDate(p.effective_from, lang)}`
                          : `From ${formatDate(p.effective_from, lang)}`}
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    {p.partners.map((r) => {
                      const changed = Math.abs(Number(r.new_pct) - Number(r.old_pct)) >= 0.005;
                      return (
                        <tr
                          key={r.partner_id}
                          className={cn(
                            "border-t",
                            r.partner_id === partner?.id && "font-semibold",
                          )}
                        >
                          <td className="py-1.5">{r.name}</td>
                          <td className="py-1.5 text-center tabular-nums">
                            {formatPercent(r.old_pct, lang)}
                          </td>
                          <td className="py-1.5 text-center text-muted-foreground">
                            <Arrow className="mx-auto size-3.5" aria-hidden />
                          </td>
                          <td
                            className={cn(
                              "py-1.5 text-center tabular-nums",
                              changed &&
                                (Number(r.new_pct) > Number(r.old_pct)
                                  ? "text-emerald-600"
                                  : "text-amber-600"),
                            )}
                          >
                            {formatPercent(r.new_pct, lang)}
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
                <p className="text-xs leading-5 text-muted-foreground">
                  {ar
                    ? "أرباح أي يوم قبل أول الشهر الجاي بتتوزع بالنسب القديمة، حتى لو التوزيع اتعمل بعدين."
                    : "Profit of any day before the 1st of next month is shared with the old percentages, even if paid out later."}
                </p>
              </>
            ) : (
              <>
                <p className="leading-6">
                  {ar
                    ? `نسبة ${partner?.name} فاضلة ${formatPercent(me?.old_pct ?? 0, lang)} زي ما هي، وكل الشركاء نسبهم مش هتتغير.`
                    : `${partner?.name} stays at ${formatPercent(me?.old_pct ?? 0, lang)}; no partner's share changes.`}
                </p>
                <p className="text-xs leading-5 text-muted-foreground">
                  {ar
                    ? `في أول توزيع أرباح، بنرجّع لـ ${partner?.name} الـ ${formatMoney(value, currency, lang)} (أو اللي يكفيه الربح) قبل نصيب الشركاء، والباقي يترحّل للتوزيع اللي بعده.`
                    : `At the next payout, ${formatMoney(value, currency, lang)} (or what the profit covers) is paid back before the partner pool; the rest carries over.`}
                </p>
              </>
            )}
          </div>
        )}

        <DialogFooter className="gap-2">
          <Button variant="outline" onClick={onClose}>
            {ar ? "إلغاء" : "Cancel"}
          </Button>
          <Button disabled={!valid || !fresh || save.isPending} onClick={() => save.mutate()}>
            {save.isPending
              ? ar
                ? "جاري الحفظ…"
                : "Saving…"
              : kind === "loan"
                ? ar
                  ? "تسجيل القرض"
                  : "Record loan"
                : ar
                  ? "تسجيل المساهمة"
                  : "Record capital"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
