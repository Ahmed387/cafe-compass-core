import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { CalendarRange, CircleAlert } from "lucide-react";
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
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import {
  monthFirstDay,
  monthLabel,
  profitMonthOf,
  profitMonthOptions,
} from "@/core/finance/salary-month";
import { supabase } from "@/integrations/supabase/client";
import { formatMoney, friendlyError } from "@/lib/format";

export type SalaryLineForMonth = {
  id: string;
  name: string;
  period_start: string;
  pnl_month: string | null;
};

type Preview = {
  cost: number;
  current_from: string;
  current_to: string;
  new_from: string;
  new_to: string;
  changed: boolean;
  current_month_net: number;
  new_month_net: number;
  can_change: boolean;
  blocker: string | null;
};

/**
 * Pick which month one salary line counts in for profit, with its effect on
 * both months' net profit shown first. Locked once either month was paid out.
 */
export function SalaryPnlMonthDialog({
  line,
  currency,
  lang,
  onClose,
}: {
  line: SalaryLineForMonth | null;
  currency: string;
  lang: "ar" | "en";
  onClose: () => void;
}) {
  const ar = lang === "ar";
  const qc = useQueryClient();
  const money = (v: number) => formatMoney(Number(v), currency, lang);
  const current = line ? profitMonthOf(line.period_start, line.pnl_month) : "";
  const [month, setMonth] = useState(current);
  const [note, setNote] = useState("");
  useEffect(() => {
    setMonth(current);
    setNote("");
  }, [line?.id, current]);

  const preview = useQuery({
    queryKey: ["salary-pnl-month-preview", line?.id, month],
    enabled: Boolean(line && month),
    queryFn: async () => {
      const { data, error } = await supabase.rpc(
        "salary_pnl_month_preview" as never,
        { _salary_id: line!.id, _month: monthFirstDay(month) } as never,
      );
      if (error) throw error;
      return data as unknown as Preview;
    },
  });

  const save = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc(
        "set_salary_pnl_month" as never,
        { _salary_id: line!.id, _month: monthFirstDay(month), _note: note.trim() || null } as never,
      );
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success(
        ar
          ? `المرتب بقى محسوب على أرباح ${monthLabel(month, lang)}`
          : `Salary now counts in ${monthLabel(month, lang)}`,
      );
      for (const key of [
        "salary-payments",
        "range-pnl",
        "payout-preview",
        "finance-month-shifts",
        "operating-costs",
      ]) {
        qc.invalidateQueries({ queryKey: [key] });
      }
      onClose();
    },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  const p = preview.data;
  const options = line ? profitMonthOptions(line.period_start) : [];
  const currentLabel = current ? monthLabel(current, lang) : "";
  const newLabel = month ? monthLabel(month, lang) : "";

  return (
    <Dialog open={Boolean(line)} onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-w-lg">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <CalendarRange className="h-4 w-4" />
            {ar
              ? `المرتب يتحسب على أرباح أنهي شهر؟`
              : "Which month's profit does this salary count in?"}
          </DialogTitle>
          <DialogDescription>
            {ar
              ? `${line?.name ?? ""} · محسوب دلوقتي على ${currentLabel}`
              : `${line?.name ?? ""} · counts in ${currentLabel} now`}
          </DialogDescription>
        </DialogHeader>

        <div className="grid gap-3 text-sm">
          <div className="grid gap-1">
            <Label htmlFor="pnl-month">{ar ? "شهر الأرباح" : "Profit month"}</Label>
            <select
              id="pnl-month"
              className="h-9 w-full rounded-md border border-input bg-background px-2 text-sm"
              value={month}
              onChange={(e) => setMonth(e.target.value)}
            >
              {options.map((m) => (
                <option key={m} value={m}>
                  {monthLabel(m, lang)}
                </option>
              ))}
            </select>
          </div>

          {preview.isError && (
            <p className="text-destructive">{friendlyError(preview.error, lang)}</p>
          )}
          {p && p.changed && (
            <div className="rounded-lg border border-border bg-muted/40 p-3">
              <p className="mb-2 font-semibold">{ar ? "اللي هيتغير:" : "What changes:"}</p>
              <ul className="list-disc space-y-1 ps-5 text-muted-foreground">
                <li>
                  {ar
                    ? `تكلفة المرتب ${money(p.cost)} (الصافي + السلف) تتنقل من ${currentLabel} لـ ${newLabel}`
                    : `Salary cost ${money(p.cost)} (net + advances) moves from ${currentLabel} to ${newLabel}`}
                </li>
                <li>
                  {ar
                    ? `صافي ربح ${currentLabel} دلوقتي ${money(p.current_month_net)} · بيزيد ${money(p.cost)}`
                    : `${currentLabel} net profit now ${money(p.current_month_net)} · rises by ${money(p.cost)}`}
                </li>
                <li>
                  {ar
                    ? `صافي ربح ${newLabel} دلوقتي ${money(p.new_month_net)} · بيقل ${money(p.cost)}`
                    : `${newLabel} net profit now ${money(p.new_month_net)} · drops by ${money(p.cost)}`}
                </li>
                <li>
                  {ar ? "الخزنة وتاريخ الصرف مبيتغيروش" : "Treasury and the pay date don't change"}
                </li>
              </ul>
            </div>
          )}
          {p && !p.can_change && p.blocker && (
            <p className="flex items-start gap-2 rounded-lg border border-destructive/40 bg-destructive/5 p-3 text-destructive">
              <CircleAlert className="mt-0.5 h-4 w-4 shrink-0" />
              {p.blocker}
            </p>
          )}
          {p?.changed && p.can_change && (
            <div className="grid gap-1">
              <Label htmlFor="pnl-note">{ar ? "ملاحظة (بتتسجل)" : "Note (recorded)"}</Label>
              <Textarea id="pnl-note" value={note} onChange={(e) => setNote(e.target.value)} />
            </div>
          )}
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            {ar ? "رجوع" : "Back"}
          </Button>
          <Button
            disabled={!p?.changed || !p.can_change || save.isPending}
            onClick={() => save.mutate()}
          >
            {ar ? "تأكيد" : "Confirm"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
