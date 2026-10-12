import { formatMoney } from "./format";

export type PlanRow = {
  name: string;
  name_ar: string | null;
  qty: number;
  revenue: number;
  cost: number;
  margin: number;
  base_price: number | string | null;
  unit_cost: number | string | null;
};

export type PlanTier = "star" | "steady" | "slow" | "dead" | "thin";

export type ProductPlan = {
  tier: PlanTier;
  headline: string;
  steps: string[];
  guard: string;
};

const round = (n: number) => Math.round(n * 2) / 2; // nearest 0.5

function num(v: number | string | null | undefined) {
  const n = typeof v === "string" ? Number(v) : (v ?? 0);
  return Number.isFinite(n) ? n : 0;
}

export const tierLabel: Record<PlanTier, { en: string; ar: string }> = {
  star: { en: "Best seller", ar: "الأكثر طلباً" },
  steady: { en: "Steady", ar: "مستقر" },
  thin: { en: "Thin margin", ar: "ربح ضعيف" },
  slow: { en: "Slow mover", ar: "بطيء الحركة" },
  dead: { en: "Not selling", ar: "لا يُباع" },
};

/**
 * Builds a concrete activation plan (with real numbers) for a product,
 * always keeping a minimum profit per unit so a promo never loses money.
 */
export function buildProductPlan(
  row: PlanRow,
  ctx: {
    maxQty: number;
    star: PlanRow | null;
    currency: string;
    lang: "en" | "ar";
    /** Minimum profit kept on any promo price, as a share of cost. */
    minMarginOnCost?: number;
  },
): ProductPlan {
  const { currency, lang, star, maxQty } = ctx;
  const ar = lang === "ar";
  const keep = ctx.minMarginOnCost ?? 0.25;
  const m = (v: number) => formatMoney(v, currency, lang);

  const price = num(row.base_price);
  const cost = num(row.unit_cost);
  const profit = price - cost;
  const marginPct = price > 0 ? (profit / price) * 100 : 0;
  const share = maxQty > 0 ? row.qty / maxQty : 0;

  // Lowest price that still keeps the minimum profit.
  const floor = round(cost * (1 + keep));
  const maxOff = Math.max(0, round(price - floor));
  const offPct = price > 0 ? Math.round((maxOff / price) * 100) : 0;

  const starName = star ? (ar ? star.name_ar || star.name : star.name) : null;
  const starPrice = star ? num(star.base_price) : 0;
  const starCost = star ? num(star.unit_cost) : 0;

  // Combo: this product + the best seller, priced above combined cost + margin.
  const comboList = price + starPrice;
  const comboFloor = round((cost + starCost) * (1 + keep));
  const comboPrice = Math.max(round(comboList * 0.88), comboFloor);
  const comboProfit = comboPrice - (cost + starCost);
  const comboSave = Math.max(0, round(comboList - comboPrice));

  // Upsize / add-on ladder: bigger price, small extra cost.
  const upPrice = round(price * 1.5);
  const upCost = round(cost * 1.2);
  const upProfit = upPrice - upCost;

  const tier: PlanTier =
    row.qty === 0
      ? "dead"
      : share >= 0.6
        ? "star"
        : marginPct < 20
          ? "thin"
          : share <= 0.2
            ? "slow"
            : "steady";

  const guard = ar
    ? `أقل سعر آمن ${m(floor)} — تحته بتخسر. أقصى خصم ${m(maxOff)} (${offPct}%).`
    : `Safe floor ${m(floor)} — below it you lose. Max discount ${m(maxOff)} (${offPct}%).`;

  const steps: string[] = [];
  let headline = "";

  if (tier === "star") {
    headline = ar
      ? `اشتغل على متوسط الفاتورة: ${m(price)} → ${m(upPrice)}`
      : `Grow the ticket: ${m(price)} → ${m(upPrice)}`;
    steps.push(
      ar
        ? `اعمل نسخة "لارج / دوبل" بسعر ${m(upPrice)} — التكلفة بتزيد ${m(upCost - cost)} بس والربح يبقى ${m(upProfit)} للوحدة.`
        : `Add a large/double version at ${m(upPrice)} — cost rises only ${m(upCost - cost)} and profit becomes ${m(upProfit)} per unit.`,
      ar
        ? `الكاشير يسأل دايماً: "تحبه لارج بـ ${m(upPrice - price)} زيادة؟" — قبول 3 من كل 10 يزود ربح اليوم بدون مصاريف تسويق.`
        : `Cashier prompt: "Make it large for ${m(upPrice - price)} more?" — a 30% take rate lifts daily profit with zero ad spend.`,
      ar
        ? `استخدمه كقاطرة: كومبو مع منتج بطيء (بند تحت) بسعر ${m(comboPrice)} بدل ${m(comboList)}.`
        : `Use it as the anchor in a combo with a slow item at ${m(comboPrice)} instead of ${m(comboList)}.`,
      ar
        ? `متعملش خصم عليه — الطلب موجود، خلي الخصم للمنتجات البطيئة.`
        : `Never discount it — demand exists; save discounts for slow items.`,
    );
  } else if (tier === "thin") {
    const needed = round(cost / (1 - 0.35)); // reach 35% margin
    headline = ar
      ? `السعر لازم يتحرك: ${m(price)} → ${m(needed)}`
      : `Reprice: ${m(price)} → ${m(needed)}`;
    steps.push(
      ar
        ? `الربح الحالي ${m(profit)} للوحدة (${marginPct.toFixed(0)}%) — سعر ${m(needed)} يوصلك 35%.`
        : `Current profit ${m(profit)}/unit (${marginPct.toFixed(0)}%) — ${m(needed)} gets you to 35%.`,
      ar
        ? `لو خايف من رفع السعر: ثبّت السعر وقلّل التكلفة (مراجعة الوصفة/جرام أقل/مورد أرخص) لحد ${m(round(price * 0.65))}.`
        : `If raising price is risky: hold it and cut recipe cost down to ${m(round(price * 0.65))} (portion or supplier).`,
      ar
        ? `أو حوّله لكومبو مع ${starName ?? "الأكثر طلباً"} بسعر ${m(comboPrice)} وربح ${m(comboProfit)} للطلب.`
        : `Or move it into a combo with ${starName ?? "your best seller"} at ${m(comboPrice)}, profit ${m(comboProfit)} per ticket.`,
    );
  } else if (tier === "slow" || tier === "dead") {
    headline = ar
      ? `خطة تشغيل: كومبو ${m(comboPrice)} بدل ${m(comboList)} (توفير ${m(comboSave)})`
      : `Activation: combo at ${m(comboPrice)} instead of ${m(comboList)} (save ${m(comboSave)})`;
    steps.push(
      ar
        ? `1) كومبو مع ${starName ?? "الأكثر طلباً"}: ${m(comboPrice)} — الربح باقي ${m(comboProfit)} للطلب، يعني مكسب مش خسارة.`
        : `1) Combo with ${starName ?? "your best seller"} at ${m(comboPrice)} — still ${m(comboProfit)} profit per ticket.`,
      ar
        ? `2) ساعة سعيدة محدودة (٢–٥ م) بسعر ${m(floor)} فقط — أقل سعر بيسيبلك ربح ${m(floor - cost)}.`
        : `2) Happy hour (2–5pm) at ${m(floor)} — the lowest price that still nets ${m(floor - cost)}.`,
      ar
        ? `3) ترقية مجانية بدل الخصم: يشتريه بسعره ${m(price)} وياخد سايز أكبر — بتكلفك ${m(upCost - cost)} بس وشكلها هدية كبيرة.`
        : `3) Free upsize instead of a discount: keep ${m(price)}, give the bigger size — costs you only ${m(upCost - cost)}.`,
      ar
        ? `4) خلي الكاشير يقترحه مع كل ${starName ?? "منتج أكثر طلباً"} + بادج "جديد/جرّبه" في منيو QR وعلى الشاشة.`
        : `4) Cashier suggests it with every ${starName ?? "best seller"}, plus a "try me" badge on the QR menu.`,
      ar
        ? `5) نقاط مضاعفة: نقاط ×2 على المنتج ده الأسبوع الجاي — تكلفتك أقل من أي خصم مباشر.`
        : `5) Double points on it for a week — cheaper than any direct discount.`,
      ar
        ? `6) لو بعد أسبوعين مبيعاته لسه ${row.qty === 0 ? "صفر" : "أقل من 5 وحدات"} — شيله من المنيو ووفّر المكان والخام.`
        : `6) If two weeks later sales are still ${row.qty === 0 ? "zero" : "under 5 units"}, retire it from the menu.`,
    );
  } else {
    headline = ar
      ? `ثبّت الطلب وارفع الفاتورة: إضافة بـ ${m(round(price * 0.35))}`
      : `Hold demand, lift the ticket: add-on at ${m(round(price * 0.35))}`;
    steps.push(
      ar
        ? `الربح الحالي ${m(profit)} للوحدة (${marginPct.toFixed(0)}%) — كفاية، مفيش داعي لخصم.`
        : `Profit is ${m(profit)}/unit (${marginPct.toFixed(0)}%) — healthy, no discount needed.`,
      ar
        ? `اربطه بإضافة مدفوعة (شوت إضافي/كريمة/صوص) بـ ${m(round(price * 0.35))} تكلفتها أقل من ${m(round(cost * 0.2))}.`
        : `Attach a paid add-on (extra shot/cream) at ${m(round(price * 0.35))} costing under ${m(round(cost * 0.2))}.`,
      ar
        ? `كومبو مع ${starName ?? "الأكثر طلباً"} بـ ${m(comboPrice)} لزيادة عدد الوحدات.`
        : `Combo with ${starName ?? "your best seller"} at ${m(comboPrice)} to move more units.`,
    );
  }

  return { tier, headline, steps, guard };
}
