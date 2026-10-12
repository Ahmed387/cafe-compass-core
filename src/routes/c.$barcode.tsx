import { useQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useState } from "react";

import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Progress } from "@/components/ui/progress";
import { supabase } from "@/integrations/supabase/client";
import { formatMoney } from "@/lib/format";
import { barcodeDataUrl } from "@/lib/loyalty";

export const Route = createFileRoute("/c/$barcode")({
  head: () => ({
    meta: [
      { title: "My cashback card — 20s Coffee" },
      { name: "description", content: "Check your 20s Coffee cashback balance and your next reward." },
      { property: "og:title", content: "My cashback card — 20s Coffee" },
      { property: "og:description", content: "Scan your card to see your cashback wallet at 20s Coffee." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: CustomerCardPage,
});

type CardData = {
  code: string;
  name: string;
  visits: number;
  barcode: string;
  company: string;
  wallet_balance: number;
  cashback_enabled: boolean;
  target_amount: number;
  reward_amount: number;
  to_next_reward: number;
};

function CustomerCardPage() {
  const { barcode } = Route.useParams();
  const [bars, setBars] = useState<string | null>(null);

  const card = useQuery({
    queryKey: ["customer-card", barcode],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("customer_card", { _barcode: barcode });
      if (error) throw error;
      return (data ?? null) as CardData | null;
    },
  });

  useEffect(() => {
    if (card.data) setBars(barcodeDataUrl(card.data.barcode));
  }, [card.data]);

  const d = card.data;
  const target = Number(d?.target_amount ?? 0);
  const done = target > 0 ? Math.min(Math.max(target - Number(d?.to_next_reward ?? 0), 0) / target, 1) : 0;

  return (
    <main dir="rtl" className="mx-auto flex min-h-screen max-w-md flex-col justify-center gap-4 p-6">
      {card.isLoading && <p className="text-center text-muted-foreground">…</p>}
      {!card.isLoading && !d && (
        <p className="text-center text-muted-foreground">مش لاقيين الكارت ده / Card not found</p>
      )}
      {d && (
        <Card>
          <CardHeader>
            <p className="text-xs uppercase tracking-wide text-muted-foreground">{d.company}</p>
            <CardTitle className="text-2xl">{d.name}</CardTitle>
            <p className="font-mono text-sm text-muted-foreground">{d.code}</p>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="rounded-lg border border-border p-4 text-center">
              <p className="text-4xl font-extrabold tabular-nums">{formatMoney(d.wallet_balance, "EGP", "ar")}</p>
              <p className="text-sm text-muted-foreground">رصيد الكاش باك / Cashback balance</p>
            </div>
            {d.cashback_enabled && target > 0 && (
              <div className="space-y-2 rounded-lg bg-muted/60 p-3 text-sm">
                <p>
                  كل ما تصرف {formatMoney(target, "EGP", "ar")} بتاخد {formatMoney(d.reward_amount, "EGP", "ar")} في محفظتك.
                </p>
                <Progress value={done * 100} />
                <p className="text-muted-foreground">فاضل {formatMoney(d.to_next_reward, "EGP", "ar")} للمكافأة الجاية</p>
              </div>
            )}
            {bars && <img src={bars} alt={d.barcode} className="mx-auto w-full max-w-xs" />}
          </CardContent>
        </Card>
      )}
    </main>
  );
}
