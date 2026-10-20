/** One tender line on the payment sheet ("cashback" pays from the customer's wallet). */
export type TenderRow = { id: string; methodKey: string; amount: string };

const cents = (n: number) => Math.round(n * 100) / 100;
export const rowAmount = (row: Pick<TenderRow, "amount">) => Number(row.amount) || 0;

/**
 * Totals of a split payment. The sheet only lets the cashier confirm when the
 * lines add up exactly to the bill and cashback doesn't exceed the wallet.
 */
export function summarizePayments(rows: TenderRow[], total: number, walletBalance: number) {
  const paid = cents(rows.reduce((sum, row) => sum + rowAmount(row), 0));
  const cashbackUsed = cents(rows.filter((row) => row.methodKey === "cashback").reduce((sum, row) => sum + rowAmount(row), 0));
  const remaining = cents(total - paid);
  const byMethod = new Map<string, number>();
  for (const row of rows) {
    const amount = rowAmount(row);
    if (amount <= 0) continue;
    byMethod.set(row.methodKey, cents((byMethod.get(row.methodKey) ?? 0) + amount));
  }
  return {
    paid,
    cashbackUsed,
    remaining,
    balanced: Math.abs(remaining) < 0.005,
    cashbackOver: cashbackUsed > walletBalance + 0.001,
    hasNegative: rows.some((row) => rowAmount(row) < 0),
    byMethod,
  };
}

/** One tap: the whole bill on one tender. */
export function singleTender(methodKey: string, total: number, makeId: () => string): TenderRow[] {
  return [{ id: makeId(), methodKey, amount: cents(total).toFixed(2) }];
}

/** Add a second tender that takes whatever is still unpaid (never a negative line). */
export function addTender(rows: TenderRow[], methodKey: string, total: number, makeId: () => string): TenderRow[] {
  const left = Math.max(cents(total - rows.reduce((sum, row) => sum + rowAmount(row), 0)), 0);
  return [...rows, { id: makeId(), methodKey, amount: left > 0 ? left.toFixed(2) : "" }];
}

/**
 * Payment lines exactly as the server receives them: one entry per tender
 * line, zero lines dropped, cashback without a payment method id.
 */
export function toServerPayments(rows: TenderRow[], methodId: (key: string) => string | null) {
  return rows
    .map((row) =>
      row.methodKey === "cashback"
        ? { method_key: "cashback", amount: rowAmount(row) }
        : { payment_method_id: methodId(row.methodKey), method_key: row.methodKey, amount: rowAmount(row) },
    )
    .filter((row) => row.amount > 0);
}
