import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { CheckCircle2, Eye, EyeOff, Lightbulb, Pencil, Sparkles } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { EmptyState } from "@/components/layout/AppShell";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { supabase } from "@/integrations/supabase/client";
import { formatMoney, friendlyError } from "@/lib/format";
import {
  buildSuggestions,
  marginPct,
  minPriceForMargin,
  profitPerUnit,
  type AdvisorRow,
  type Suggestion,
} from "@/lib/offer-advisor";
import { isMissingFunction } from "@/lib/supabase-errors";

const PERIOD_DAYS = 30;

function isoDaysAgo(days: number) {
  const d = new Date();
  d.setDate(d.getDate() - days);
  return d.toISOString().slice(0, 10);
}

const num = (v: unknown) => {
  const n = Number(v ?? 0);
  return Number.isFinite(n) ? n : 0;
};

/**
 * "Suggest offers": reads the last 30 days of invoices and the stock, lists
 * offers worth running with the reason, the cost and the profit. The price is
 * editable and the profit updates as you type; approving publishes the offer
 * to the till and the public menu. A suggestion that already has a running
 * offer opens that offer for editing instead; any suggestion can be hidden.
 */
export type AdvisorOffer = { id: string; product_id: string | null; is_active: boolean; ends_at: string | null };

export function OfferAdvisorPanel({ lang, currency, isSuperAdmin, canManage, offers, onEditOffer }: {
  lang: "ar" | "en";
  currency: string;
  isSuperAdmin: boolean;
  canManage: boolean;
  offers: AdvisorOffer[];
  onEditOffer: (offerId: string) => void;
}) {
  const ar = lang === "ar";
  const money = (v: number) => formatMoney(v, currency, lang);
  const [asked, setAsked] = useState(false);
  const from = isoDaysAgo(PERIOD_DAYS - 1);
  const to = new Date().toISOString().slice(0, 10);

  const data = useQuery({
    queryKey: ["offer-advisor", from, to],
    enabled: asked,
    queryFn: async (): Promise<AdvisorRow[]> => {
      const { data: rows, error } = await supabase.rpc("offer_advisor_data" as never, { _from: from, _to: to } as never);
      if (!error) return ((rows ?? []) as unknown as Record<string, unknown>[]).map(toRow);
      if (!isMissingFunction(error)) throw error;
      // Before the advisor migration: sales only, no stock signal.
      const fallback = await supabase.rpc("offer_candidates", { _from: from, _to: to });
      if (fallback.error) throw fallback.error;
      return ((fallback.data ?? []) as unknown as Record<string, unknown>[]).map(toRow);
    },
  });

  const qc = useQueryClient();
  const [showHidden, setShowHidden] = useState(false);
  const hidden = useQuery({
    queryKey: ["offer-hidden-suggestions"],
    enabled: asked,
    queryFn: async () => {
      const { data: list, error } = await supabase.rpc("offer_hidden_suggestions" as never);
      if (error) {
        if (isMissingFunction(error)) return new Set<string>();
        throw error;
      }
      return new Set(((list ?? []) as unknown as string[]).map(String));
    },
  });
  const setHidden = useMutation({
    mutationFn: async ({ productId, hide }: { productId: string; hide: boolean }) => {
      const { error } = await supabase.rpc("set_offer_suggestion_hidden" as never, { _product_id: productId, _hidden: hide } as never);
      if (error) throw error;
      return hide;
    },
    onSuccess: async (hide) => {
      await qc.invalidateQueries({ queryKey: ["offer-hidden-suggestions"] });
      toast.success(hide ? (ar ? "الاقتراح اتخفى" : "Suggestion hidden") : (ar ? "الاقتراح رجع" : "Suggestion shown"));
    },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  const today = new Date().toISOString().slice(0, 10);
  const runningOffer = (productId: string) =>
    offers.find((o) => o.product_id === productId && o.is_active && (!o.ends_at || o.ends_at >= today)) ?? null;
  const all = data.data ? buildSuggestions(data.data, PERIOD_DAYS, lang).slice(0, 12) : [];
  const hiddenSet = hidden.data ?? new Set<string>();
  const hiddenCount = all.filter((s) => hiddenSet.has(s.product_id)).length;
  const suggestions = all.filter((s) => showHidden === hiddenSet.has(s.product_id));

  return (
    <Card>
      <CardHeader className="flex flex-row flex-wrap items-center justify-between gap-3">
        <div>
          <CardTitle className="flex items-center gap-2">
            <Lightbulb className="size-5" />
            {ar ? "اقتراحات العروض" : "Offer suggestions"}
          </CardTitle>
          <p className="mt-1 text-sm text-muted-foreground">
            {ar
              ? `من فواتير آخر ${PERIOD_DAYS} يوم والمخزن: الأصناف الراكدة، والخامات اللي كتير في المخزن، والأكتر مبيعاً.`
              : `From the last ${PERIOD_DAYS} days of invoices and the stock: slow sellers, ingredients piling up, best sellers.`}
          </p>
        </div>
        <Button onClick={() => (asked ? data.refetch() : setAsked(true))} disabled={data.isFetching}>
          <Sparkles className="me-1 size-4" />
          {data.isFetching ? (ar ? "بيحسب…" : "Working…") : ar ? "اقترح عروض" : "Suggest offers"}
        </Button>
      </CardHeader>
      {asked && (
        <CardContent className="space-y-3">
          {data.isError ? (
            <p className="text-sm text-destructive">{friendlyError(data.error, lang)}</p>
          ) : (
            <>
              {(hiddenCount > 0 || showHidden) && (
                <div className="flex justify-end">
                  <Button size="sm" variant="ghost" onClick={() => setShowHidden((v) => !v)}>
                    {showHidden ? <Eye className="me-1 size-4" /> : <EyeOff className="me-1 size-4" />}
                    {showHidden
                      ? ar ? "ارجع للاقتراحات" : "Back to suggestions"
                      : ar ? `الاقتراحات المخفية (${hiddenCount})` : `Hidden suggestions (${hiddenCount})`}
                  </Button>
                </div>
              )}
              {!data.isFetching && suggestions.length === 0 ? (
                <EmptyState
                  message={
                    showHidden
                      ? ar ? "مفيش اقتراحات مخفية." : "No hidden suggestions."
                      : ar ? "مفيش اقتراحات دلوقتي: محتاج أصناف ليها سعر وتكلفة ومبيعات." : "No suggestions yet: products need a price, a cost and sales."
                  }
                />
              ) : (
                <div className="grid gap-3 lg:grid-cols-2">
                  {suggestions.map((s) => (
                    <SuggestionCard
                      key={s.product_id}
                      s={s}
                      lang={lang}
                      money={money}
                      isSuperAdmin={isSuperAdmin}
                      canManage={canManage}
                      running={runningOffer(s.product_id)}
                      onEditOffer={onEditOffer}
                      isHidden={hiddenSet.has(s.product_id)}
                      onHide={(hide) => setHidden.mutate({ productId: s.product_id, hide })}
                      hiding={setHidden.isPending}
                    />
                  ))}
                </div>
              )}
            </>
          )}
        </CardContent>
      )}
    </Card>
  );
}

function toRow(r: Record<string, unknown>): AdvisorRow {
  return {
    product_id: String(r["product_id"]),
    name: String(r["name"] ?? ""),
    name_ar: (r["name_ar"] as string | null) ?? null,
    category: (r["category"] as string | null) ?? null,
    base_price: num(r["base_price"]),
    unit_cost: num(r["unit_cost"]),
    qty: num(r["qty"]),
    revenue: num(r["revenue"]),
    orders_count: num(r["orders_count"]),
    last_sold_at: (r["last_sold_at"] as string | null) ?? null,
    stock_item: (r["stock_item"] as string | null) ?? null,
    stock_days: r["stock_days"] === null || r["stock_days"] === undefined ? null : num(r["stock_days"]),
  };
}

const KIND_LABEL = {
  slow_mover: { ar: "راكد", en: "Slow seller" },
  overstock: { ar: "مخزن كتير", en: "Too much stock" },
  best_seller: { ar: "الأكتر مبيعاً", en: "Best seller" },
} as const;

function SuggestionCard({ s, lang, money, isSuperAdmin, canManage, running, onEditOffer, isHidden, onHide, hiding }: {
  s: Suggestion;
  lang: "ar" | "en";
  money: (v: number) => string;
  isSuperAdmin: boolean;
  canManage: boolean;
  running: AdvisorOffer | null;
  onEditOffer: (offerId: string) => void;
  isHidden: boolean;
  onHide: (hide: boolean) => void;
  hiding: boolean;
}) {
  const ar = lang === "ar";
  const qc = useQueryClient();
  const [price, setPrice] = useState(s.suggested_price.toFixed(2));
  const [target, setTarget] = useState(String(s.suggested_margin));

  const p = Number(price) || 0;
  const t = Number(target) || 0;
  const margin = marginPct(p, s.unit_cost);
  const profit = profitPerUnit(p, s.unit_cost);
  const floor = minPriceForMargin(s.unit_cost, isSuperAdmin ? t : 0);
  const underTarget = p > 0 && p < floor;
  const aboveNormal = p > s.base_price;

  const approve = useMutation({
    mutationFn: async () => {
      const today = new Date().toISOString().slice(0, 10);
      const { error } = await supabase.rpc("save_product_offer", {
        _payload: {
          offer_type: "single",
          product_id: s.product_id,
          items: [],
          title: ar ? `عرض ${s.name}` : `${s.name} offer`,
          offer_price: p,
          double_points: false,
          starts_at: today,
          ends_at: null,
          notes: s.reason[lang],
          image_path: null,
          ...(isSuperAdmin ? { target_margin: t } : {}),
        },
      });
      if (error) throw error;
    },
    onSuccess: async () => {
      await qc.invalidateQueries({ queryKey: ["product-offers"] });
      await qc.invalidateQueries({ queryKey: ["pos-active-offers"] });
      toast.success(ar ? "العرض اتنشر للكاشير وفي المنيو" : "Offer is live at the till and on the menu");
    },
    onError: (e) => toast.error(friendlyError(e, lang)),
  });

  return (
    <div className="space-y-3 rounded-xl border border-border bg-card p-4 shadow-sm">
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="font-semibold">{s.name}</p>
          <p className="text-xs text-muted-foreground">
            {ar ? "السعر العادي" : "Normal price"} {money(s.base_price)} · {ar ? "التكلفة" : "Cost"} {money(s.unit_cost)} ·{" "}
            {ar ? "ربحه العادي" : "Normal margin"} {s.normal_margin.toFixed(0)}%
          </p>
        </div>
        <div className="flex shrink-0 flex-col items-end gap-1">
          <Badge variant="secondary">{KIND_LABEL[s.kind][lang]}</Badge>
          {running && <Badge>{ar ? "عليه عرض شغال" : "Offer running"}</Badge>}
        </div>
      </div>
      <p className="rounded-md bg-muted p-2 text-sm">
        <span className="font-medium">{ar ? "ليه؟ " : "Why? "}</span>
        {s.reason[lang]}
      </p>
      <div className="grid grid-cols-2 gap-2">
        <div className="grid gap-1">
          <Label className="text-xs" htmlFor={`price-${s.product_id}`}>{ar ? "سعر العرض" : "Offer price"}</Label>
          <Input id={`price-${s.product_id}`} inputMode="decimal" value={price} onChange={(e) => setPrice(e.target.value)} />
        </div>
        <div className="grid gap-1">
          <Label className="text-xs" htmlFor={`target-${s.product_id}`}>
            {ar ? "أقل نسبة ربح للعرض %" : "Minimum margin %"}
          </Label>
          <Input
            id={`target-${s.product_id}`}
            inputMode="decimal"
            value={target}
            disabled={!isSuperAdmin}
            onChange={(e) => setTarget(e.target.value)}
          />
          <span className="text-[11px] text-muted-foreground">
            {ar ? `مقترح: ${s.suggested_margin}%` : `Suggested: ${s.suggested_margin}%`}
            {!isSuperAdmin && (ar ? " · السوبر أدمن بس يغيّرها" : " · super admin only")}
          </span>
        </div>
      </div>
      <div className="grid grid-cols-2 gap-2 text-sm">
        <div className="rounded-md border border-border p-2">
          <p className="text-xs text-muted-foreground">{ar ? "ربحك في العرض" : "Offer margin"}</p>
          <p className={`text-lg font-bold tabular-nums ${underTarget ? "text-destructive" : ""}`}>{margin.toFixed(1)}%</p>
        </div>
        <div className="rounded-md border border-border p-2">
          <p className="text-xs text-muted-foreground">{ar ? "ربحك في القطعة" : "Profit per item"}</p>
          <p className={`text-lg font-bold tabular-nums ${profit <= 0 ? "text-destructive" : ""}`}>{money(profit)}</p>
        </div>
      </div>
      {underTarget && (
        <p className="text-xs font-medium text-destructive">
          {ar ? `السعر ده تحت النسبة. أقل سعر: ${money(floor)}` : `Below the minimum margin. Lowest price: ${money(floor)}`}
        </p>
      )}
      {aboveNormal && (
        <p className="text-xs font-medium text-destructive">
          {ar ? "سعر العرض أعلى من السعر العادي." : "The offer price is above the normal price."}
        </p>
      )}
      <div className="flex gap-2">
        {running ? (
          <Button className="flex-1" variant="secondary" disabled={!canManage} onClick={() => onEditOffer(running.id)}>
            <Pencil className="me-1 size-4" />
            {ar ? "عدّل العرض أو وقّفه" : "Edit or stop the offer"}
          </Button>
        ) : (
          <Button
            className="flex-1"
            disabled={!canManage || approve.isPending || p <= 0 || underTarget || aboveNormal}
            onClick={() => approve.mutate()}
          >
            <CheckCircle2 className="me-1 size-4" />
            {ar ? "اعتمد العرض" : "Approve offer"}
          </Button>
        )}
        {canManage && (
          <Button variant="outline" disabled={hiding} onClick={() => onHide(!isHidden)}>
            {isHidden ? <Eye className="me-1 size-4" /> : <EyeOff className="me-1 size-4" />}
            {isHidden ? (ar ? "إظهار" : "Show") : ar ? "إخفاء" : "Hide"}
          </Button>
        )}
      </div>
    </div>
  );
}
