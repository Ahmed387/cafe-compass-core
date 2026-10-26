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

export type TabSettlementRow = {
  mode: string;
  method_key?: string | null;
  settled_on?: string | null;
  status?: string | null;
};

const TAB_METHODS: Record<string, { ar: string; en: string }> = {
  cash: { ar: "كاش", en: "Cash" },
  instapay: { ar: "انستاباي", en: "InstaPay" },
  wallet: { ar: "محفظة", en: "Wallet" },
  card: { ar: "فيزا", en: "Card" },
};

/** How an invoice on a partner's account was paid off, e.g. "اتسدد كاش". Reversed rows are ignored. */
export function tabSettledHow(rows: TabSettlementRow[] | null | undefined, lang: "ar" | "en") {
  const ar = lang === "ar";
  const active = (rows ?? []).filter((r) => (r.status ?? "active") === "active");
  if (active.length === 0) return null;
  const parts = [
    ...new Set(
      active.map((r) => {
        if (r.mode === "deduct") return ar ? "اتخصم من رصيده" : "deducted from balance";
        if (r.mode === "payout") return ar ? "اتخصم من الأرباح" : "deducted from profit";
        const m = TAB_METHODS[r.method_key ?? ""];
        return ar ? `اتسدد ${m?.ar ?? r.method_key ?? ""}`.trim() : `paid ${m?.en ?? r.method_key ?? ""}`.trim();
      }),
    ),
  ];
  const last = active
    .map((r) => r.settled_on ?? "")
    .sort()
    .at(-1);
  return { label: parts.join(" + "), on: last || null };
}
