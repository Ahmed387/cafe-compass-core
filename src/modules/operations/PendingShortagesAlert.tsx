import { useQuery } from "@tanstack/react-query";
import { AlertTriangle } from "lucide-react";

import { supabase } from "@/integrations/supabase/client";
import { formatDate, formatMoney } from "@/lib/format";
import { ShortageBearerCell } from "@/modules/operations/ShortageBearerCell";

type PendingShortage = {
  shift_id: string;
  business_date: string;
  opened_at: string;
  closed_at: string | null;
  cashier: string | null;
  shortage: number;
};

/** Super admin only: closed shifts whose drawer shortage still needs a bearer. */
export function PendingShortagesAlert({ lang, currency }: { lang: "ar" | "en"; currency: string }) {
  const ar = lang === "ar";
  const q = useQuery({
    queryKey: ["pending-shortages"],
    refetchInterval: 60_000,
    queryFn: async (): Promise<PendingShortage[]> => {
      const { data, error } = await supabase.rpc("pending_shift_shortages");
      if (error) throw error;
      return (data ?? []) as PendingShortage[];
    },
  });
  const rows = q.data ?? [];
  if (rows.length === 0) return null;

  return (
    <div dir={ar ? "rtl" : "ltr"} className="rounded-2xl border border-destructive/40 bg-destructive/10 p-4 text-sm">
      <p className="flex items-center gap-2 font-semibold text-destructive">
        <AlertTriangle className="size-4" aria-hidden />
        {ar ? `عجز في ${rows.length} وردية مستني قرارك` : `${rows.length} shift shortage(s) waiting for your decision`}
      </p>
      <p className="mt-1 text-xs text-muted-foreground">
        {ar
          ? "اختار مين يتحمل كل عجز: المكان، أو حد من التيم، أو التيم كله."
          : "Choose who carries each shortage: the venue, one team member or the whole team."}
      </p>
      <ul className="mt-3 grid gap-2">
        {rows.map((r) => (
          <li
            key={r.shift_id}
            className="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-3 rounded-xl border border-border bg-background px-3 py-2"
          >
            <div className="min-w-0">
              <p className="truncate font-medium">
                {ar ? "وردية" : "Shift"} {r.cashier ?? "—"} · {ar ? "اتفتحت" : "opened"} {formatDate(r.business_date, lang)}
              </p>
              <p className="font-display font-bold tabular-nums text-destructive">
                {ar ? "عجز" : "Short"} {formatMoney(Number(r.shortage), currency, lang)}
              </p>
            </div>
            <ShortageBearerCell shiftId={r.shift_id} shortage={Number(r.shortage)} mode="pending" editable lang={lang} />
          </li>
        ))}
      </ul>
    </div>
  );
}
