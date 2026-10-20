// Offer suggestions from sales and stock. The database supplies the numbers
// (offer_advisor_data); this file decides what to suggest and why, so the
// rules are the same on every screen and covered by unit tests.

export type AdvisorRow = {
  product_id: string;
  name: string;
  name_ar: string | null;
  category: string | null;
  base_price: number;
  unit_cost: number;
  qty: number;
  revenue: number;
  orders_count: number;
  last_sold_at: string | null;
  stock_item: string | null;
  stock_days: number | null;
};

export type SuggestionKind = "slow_mover" | "overstock" | "best_seller";

export type Suggestion = {
  product_id: string;
  name: string;
  kind: SuggestionKind;
  reason: { ar: string; en: string };
  base_price: number;
  unit_cost: number;
  normal_margin: number;
  suggested_price: number;
  suggested_margin: number;
  /** Lowest price that still keeps `suggested_margin`. */
  floor_price: number;
  score: number;
};

/** The 25% safety floor every offer already respects (price ≥ cost × 1.25). */
export const SAFETY_MARKUP = 1.25;
/** Stock that lasts longer than this many days at the current pace is "too much". */
export const OVERSTOCK_DAYS = 30;

const half = (n: number) => Math.round(n * 2) / 2;
const round2 = (n: number) => Math.round(n * 100) / 100;

/** Profit margin % of a price over its cost (0 when there is no price). */
export function marginPct(price: number, cost: number): number {
  if (!(price > 0)) return 0;
  return round2(((price - cost) / price) * 100);
}

/** Profit in money on one unit. */
export function profitPerUnit(price: number, cost: number): number {
  return round2(price - cost);
}

/** Lowest price that keeps `margin` % profit and the 25% safety floor. */
export function minPriceForMargin(cost: number, margin: number): number {
  if (!(cost > 0)) return 0;
  const m = Math.min(Math.max(margin, 0), 99);
  return round2(Math.max(cost / (1 - m / 100), cost * SAFETY_MARKUP));
}

/**
 * Margin to suggest for an offer: give up part of the normal margin to move
 * stock, but never suggest less than 30% (or the normal margin, if lower).
 */
export function suggestedMargin(normalMargin: number, kind: SuggestionKind): number {
  const giveUp = kind === "best_seller" ? 8 : kind === "overstock" ? 20 : 15;
  const floor = Math.min(30, normalMargin);
  return Math.max(Math.round(normalMargin - giveUp), Math.round(floor));
}

/** Rank products and suggest offers. Products with no price or no cost are skipped. */
export function buildSuggestions(rows: AdvisorRow[], periodDays: number, lang: "ar" | "en" = "ar"): Suggestion[] {
  const priced = rows.filter((r) => r.base_price > 0 && r.unit_cost > 0 && r.unit_cost < r.base_price);
  if (priced.length === 0) return [];
  const sold = priced.filter((r) => r.qty > 0).map((r) => r.qty).sort((a, b) => a - b);
  const pick = (p: number): number => (sold.length ? (sold[Math.min(sold.length - 1, Math.floor(p * sold.length))] ?? 0) : 0);
  const slowLine = pick(0.25);
  const bestLine = pick(0.8);
  const days = Math.max(periodDays, 1);

  const out: Suggestion[] = [];
  for (const r of priced) {
    const display = lang === "ar" ? (r.name_ar || r.name) : r.name;
    const perDay = r.qty / days;
    let kind: SuggestionKind | null = null;
    let reason = { ar: "", en: "" };
    let score = 0;

    if (r.stock_days !== null && r.stock_days >= OVERSTOCK_DAYS && r.stock_item) {
      kind = "overstock";
      reason = {
        ar: `المخزن فيه ${r.stock_item} يكفي حوالي ${Math.round(r.stock_days)} يوم بالسرعة دي. عرض على ${r.name_ar || r.name} يسحب منه قبل ما يقعد.`,
        en: `There is enough ${r.stock_item} for about ${Math.round(r.stock_days)} days at this pace. An offer on ${r.name} uses it up.`,
      };
      score = 2 + Math.min(r.stock_days / OVERSTOCK_DAYS, 4);
    } else if (r.qty <= slowLine) {
      kind = "slow_mover";
      reason = {
        ar: r.qty === 0
          ? `مااتباعش ولا مرة في آخر ${days} يوم. سعر أقل ممكن يعرّف الناس بيه.`
          : `اتباع ${r.qty} بس في ${days} يوم (حوالي ${perDay.toFixed(1)} في اليوم)، من أقل الأصناف.`,
        en: r.qty === 0
          ? `Not sold once in the last ${days} days. A lower price can introduce it.`
          : `Only ${r.qty} sold in ${days} days (about ${perDay.toFixed(1)} a day), among the slowest.`,
      };
      score = 1.5 + (slowLine > 0 ? 1 - r.qty / slowLine : 1);
    } else if (r.qty >= bestLine && bestLine > 0) {
      kind = "best_seller";
      reason = {
        ar: `من الأكتر مبيعاً (${r.qty} في ${days} يوم). خصم صغير عليه بيجيب زباين أكتر من غير ما يضيّع الربح.`,
        en: `A best seller (${r.qty} in ${days} days). A small discount brings more visits without losing the margin.`,
      };
      score = 1 + r.qty / Math.max(bestLine, 1) / 4;
    }
    if (!kind) continue;

    const normal = marginPct(r.base_price, r.unit_cost);
    const margin = suggestedMargin(normal, kind);
    const floor = minPriceForMargin(r.unit_cost, margin);
    const discount = kind === "best_seller" ? 0.1 : kind === "overstock" ? 0.2 : 0.15;
    const target = half(r.base_price * (1 - discount));
    // Never above the normal price, never under the margin floor (rounded up to the half pound).
    const price = Math.min(r.base_price, Math.max(target, Math.ceil(floor * 2) / 2));
    out.push({
      product_id: r.product_id,
      name: display,
      kind,
      reason,
      base_price: r.base_price,
      unit_cost: r.unit_cost,
      normal_margin: normal,
      suggested_price: price,
      suggested_margin: margin,
      floor_price: floor,
      score: round2(score),
    });
  }
  return out.sort((a, b) => b.score - a.score);
}
