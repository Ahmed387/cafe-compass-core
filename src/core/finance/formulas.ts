// Client-side money helpers. All P&L and shift formulas live in the database
// (range_pnl / shift_financials) so every screen shows the same numbers.

export type TenderKey = "cash" | "instapay" | "visa" | "wallet" | "partner_tab";
export const TENDER_KEYS: TenderKey[] = ["cash", "instapay", "visa", "wallet", "partner_tab"];
export type TenderTotals = Record<TenderKey, number>;

const n = (value: unknown) => {
  const num = Number(value ?? 0);
  return Number.isFinite(num) ? num : 0;
};
const round2 = (value: number) => Math.round(value * 100) / 100;

export function emptyTenders(): TenderTotals {
  return { cash: 0, instapay: 0, visa: 0, wallet: 0, partner_tab: 0 };
}

/**
 * Maps a stored payment method key to an official tender. Loyalty points are not
 * money, so they map to "points" and never count as cash (mirrors SQL tender_key).
 */
export function normalizeTender(methodKey: string | null | undefined): TenderKey | "points" {
  const value = (methodKey ?? "cash").toLowerCase();
  // Customer credit (cashback wallet, legacy points) is not money in the drawer.
  if (value === "points" || value === "cashback") return "points";
  if (value.includes("partner") || value.includes("tab") || value.includes("account")) return "partner_tab";
  if (value.includes("insta") || value.includes("bank")) return "instapay";
  if (value.includes("wallet") || value.includes("vodafone")) return "wallet";
  if (value.includes("card") || value.includes("visa")) return "visa";
  return "cash";
}

export function sum(values: number[]) {
  return round2(values.reduce((acc, value) => acc + n(value), 0));
}

type RefundLike = { amount: number | string; status?: string | null; origin?: string | null };

/**
 * Refunds that lower an invoice's sale value. A removed line already left
 * orders.total, so its automatic refund (origin "void") only moves cash and is
 * excluded here — mirrors the SQL revenue rule (migration 20261015120000).
 */
export function saleRefundTotal(refunds: RefundLike[] | null | undefined) {
  return sum(
    (refunds ?? [])
      .filter((r) => (r.status ?? "active") === "active" && (r.origin ?? "manual") !== "void")
      .map((r) => n(r.amount)),
  );
}

/** Net value an invoice keeps as a sale: 0 when cancelled, else total − sale refunds. */
export function netInvoiceTotal(
  order: { total: number | string; status?: string | null },
  refunds: RefundLike[] | null | undefined,
) {
  if (order.status === "cancelled") return 0;
  return Math.max(0, round2(n(order.total) - saleRefundTotal(refunds)));
}
