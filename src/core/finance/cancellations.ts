// A cancelled item (or order) is not a refund: its money went back to the
// customer, but it is as if it was never sold. Rows of order_refunds carry
// is_cancellation; old auto-refunds stay refunds unless switched by hand.

type RefundRowLike = {
  amount: number | string;
  method_key?: string | null;
  is_cancellation?: boolean | null;
  items_payload?: Array<{
    disposition?: string;
    quantity?: number | string;
    unit_cost?: number | string;
  }> | null;
};

const n = (value: unknown) => {
  const num = Number(value ?? 0);
  return Number.isFinite(num) ? num : 0;
};
const round2 = (value: number) => Math.round(value * 100) / 100;

export function isCancellation(row: { is_cancellation?: boolean | null }) {
  return row.is_cancellation === true;
}

/** Totals for the refunds log: real refunds and cancellations counted apart; waste covers both. */
export function splitRefundStats(rows: RefundRowLike[]) {
  const out = { count: 0, total: 0, cash: 0, waste: 0, cancelCount: 0, cancelTotal: 0 };
  for (const row of rows) {
    // Waste is real cost either way: a prepared item that was cancelled still went in the bin.
    for (const entry of row.items_payload ?? []) {
      if (entry.disposition === "waste") out.waste += n(entry.unit_cost) * n(entry.quantity);
    }
    if (isCancellation(row)) {
      out.cancelCount += 1;
      out.cancelTotal += n(row.amount);
      continue;
    }
    out.count += 1;
    out.total += n(row.amount);
    if ((row.method_key ?? "cash") === "cash") out.cash += n(row.amount);
  }
  out.total = round2(out.total);
  out.cash = round2(out.cash);
  out.waste = round2(out.waste);
  out.cancelTotal = round2(out.cancelTotal);
  return out;
}
