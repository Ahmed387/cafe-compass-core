import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Switch } from "@/components/ui/switch";
import { supabase } from "@/integrations/supabase/client";
import { friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";

type Method = {
  id: string;
  key: string;
  name: string;
  is_active: boolean;
  receiver_account: string | null;
};

const LABELS: Record<string, { ar: string; en: string; hintAr: string; hintEn: string }> = {
  cash: { ar: "كاش", en: "Cash", hintAr: "", hintEn: "" },
  instapay: {
    ar: "إنستاباي",
    en: "InstaPay",
    hintAr: "عنوان الدفع (مثلاً name@instapay)",
    hintEn: "Payment address (e.g. name@instapay)",
  },
  wallet: {
    ar: "محفظة إلكترونية",
    en: "E-wallet",
    hintAr: "رقم المحفظة اللي العميل يحوّل عليه",
    hintEn: "Wallet number customers send to",
  },
  card: {
    ar: "فيزا / ماكينة",
    en: "Card machine",
    hintAr: "اسم الماكينة (مثلاً فوري) — اقفلها لحد ما توصل",
    hintEn: "Machine name (e.g. Fawry) — keep off until it arrives",
  },
};

/** Settings: switch payment methods on/off and set the receiving handle shown on the POS. */
export function PaymentMethodsCard({ readOnly }: { readOnly: boolean }) {
  const { lang } = useI18n();
  const ar = lang === "ar";
  const qc = useQueryClient();
  const methods = useQuery({
    queryKey: ["payment-methods-settings"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("payment_methods")
        .select("id, key, name, is_active, receiver_account" as "id, key, name, is_active")
        .order("name");
      if (error) throw error;
      return (data ?? []) as unknown as Method[];
    },
  });
  const [draft, setDraft] = useState<Record<string, { active: boolean; receiver: string }>>({});
  useEffect(() => {
    const next: Record<string, { active: boolean; receiver: string }> = {};
    for (const m of methods.data ?? [])
      next[m.id] = { active: m.is_active, receiver: m.receiver_account ?? "" };
    setDraft(next);
  }, [methods.data]);

  const save = useMutation({
    mutationFn: async () => {
      for (const m of methods.data ?? []) {
        const d = draft[m.id];
        if (!d || (d.active === m.is_active && d.receiver === (m.receiver_account ?? ""))) continue;
        const { error } = await supabase.rpc(
          "set_payment_method" as never,
          {
            _method_id: m.id,
            _is_active: d.active,
            _receiver_account: d.receiver,
          } as never,
        );
        if (error) throw error;
      }
    },
    onSuccess: () => {
      toast.success(ar ? "اتحفظت طرق الدفع" : "Payment methods saved");
      qc.invalidateQueries({ queryKey: ["payment-methods-settings"] });
      qc.invalidateQueries({ queryKey: ["payment-methods"] });
    },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  return (
    <Card className="mb-4">
      <CardHeader>
        <CardTitle className="text-base">{ar ? "طرق الدفع" : "Payment methods"}</CardTitle>
        <p className="text-sm text-muted-foreground">
          {ar
            ? "اللي مقفول مش هيظهر للكاشير. العنوان/الرقم بيظهر للكاشير وقت الدفع عشان يقوله للعميل. فلوس كل طريقة بتنزل في حسابها في الخزينة، ومنها تقدر تحوّلها للخزنة الرئيسية (تسوية)."
            : "Disabled methods are hidden from the cashier. The address/number is shown at checkout. Each method's money lands in its own treasury account, from where you transfer it to the main safe (settlement)."}
        </p>
      </CardHeader>
      <CardContent className="space-y-3">
        {(methods.data ?? []).map((m) => {
          const l = LABELS[m.key];
          const d = draft[m.id];
          if (!d) return null;
          return (
            <div
              key={m.id}
              className="flex flex-wrap items-center gap-3 rounded-xl border border-border p-3"
            >
              <Switch
                checked={d.active}
                disabled={readOnly || m.key === "cash"}
                onCheckedChange={(v) => setDraft((p) => ({ ...p, [m.id]: { ...d, active: v } }))}
              />
              <span className="w-32 font-medium">{l ? (ar ? l.ar : l.en) : m.name}</span>
              {m.key !== "cash" && (
                <Input
                  dir="ltr"
                  className="min-w-48 flex-1"
                  placeholder={l ? (ar ? l.hintAr : l.hintEn) : ""}
                  value={d.receiver}
                  disabled={readOnly}
                  onChange={(e) =>
                    setDraft((p) => ({ ...p, [m.id]: { ...d, receiver: e.target.value } }))
                  }
                />
              )}
            </div>
          );
        })}
        {!readOnly && (
          <Button onClick={() => save.mutate()} disabled={save.isPending}>
            {ar ? "حفظ طرق الدفع" : "Save payment methods"}
          </Button>
        )}
      </CardContent>
    </Card>
  );
}
