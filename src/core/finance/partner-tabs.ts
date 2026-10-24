// Settling what a partner owes for invoices on their account. Mirrors
// public.settle_partner_tab: oldest invoices first, any amount up to what is open.

export type TabSettleMode = "payment" | "deduct";

const round2 = (value: number) => Math.round(value * 100) / 100;

/** The effect of a settlement before it is saved: what changes where. */
export function settlementPreview(input: {
  open: number;
  balance: number;
  amount: number;
  mode: TabSettleMode;
}) {
  const amount = round2(Number(input.amount) || 0);
  const open = round2(Number(input.open) || 0);
  const balance = round2(Number(input.balance) || 0);
  let error: "amount" | "over" | null = null;
  if (!(amount > 0)) error = "amount";
  else if (amount > open) error = "over";
  const ok = error === null;
  return {
    ok,
    error,
    amount,
    openAfter: ok ? round2(open - amount) : open,
    treasuryIn: ok && input.mode === "payment" ? amount : 0,
    balanceAfter: ok && input.mode === "deduct" ? round2(balance - amount) : balance,
    /** What the next profit payout will still deduct from this partner. */
    nextPayoutDeducts: ok ? round2(open - amount) : open,
    balanceGoesNegative: ok && input.mode === "deduct" && round2(balance - amount) < 0,
  };
}
