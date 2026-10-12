import { useQuery } from "@tanstack/react-query";

import { supabase } from "@/integrations/supabase/client";
import { emptyTenders, sum, TENDER_KEYS, type TenderTotals } from "@/core/finance/formulas";

export type ShiftFinancials = {
  shiftId: string;
  status: string;
  openedAt: string;
  closedAt: string | null;
  openingCash: number;
  closingCash: number | null;
  retainedFloat: number | null;
  cashDrop: number | null;
  gross: number;
  offers: number;
  discounts: number;
  /** Customer loyalty points used as payment (not cash, reduces revenue). */
  points: number;
  /** Refunds excluding VAT. */
  refunds: number;
  staffRefunds: number;
  venueRefunds: number;
  netSales: number;
  rawCogs: number;
  cogs: number;
  waste: number;
  /** Stocktake shortages recorded during the shift (EGP). */
  shrinkage: number;
  grossMargin: number;
  tenders: TenderTotals;
  /** Number of payments recorded per tender. */
  tenderCounts: TenderTotals;
  cashRefunds: number;
  shiftExpenses: number;
  expectedCash: number;
  variance: number | null;
  shortageResolution: string | null;
};

export type FinancialTotals = Omit<
  ShiftFinancials,
  | "shiftId" | "status" | "openedAt" | "closedAt" | "openingCash" | "closingCash"
  | "retainedFloat" | "cashDrop" | "expectedCash" | "variance" | "shortageResolution"
> & { variance: number; shiftCount: number };

type RawShift = Omit<ShiftFinancials, "tenders" | "tenderCounts"> & {
  tenders: Partial<TenderTotals>;
  tenderCounts: Partial<TenderTotals>;
};

const num = (value: unknown) => {
  const n = Number(value ?? 0);
  return Number.isFinite(n) ? n : 0;
};

function toTenders(raw: Partial<TenderTotals> | null | undefined): TenderTotals {
  const out = emptyTenders();
  for (const key of TENDER_KEYS) out[key] = num(raw?.[key]);
  return out;
}

/**
 * Shared shift money figures. The database function `shift_financials` uses the
 * same formulas as the company P&L (`range_pnl`), so every screen agrees.
 */
export function useFinancialEngine(params: {
  branchId: string | null | undefined;
  shiftIds: string[];
  enabled?: boolean;
}) {
  const { branchId, shiftIds, enabled = true } = params;
  return useQuery({
    queryKey: ["financial-engine", branchId, shiftIds],
    enabled: enabled && Boolean(branchId) && shiftIds.length > 0,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("shift_financials", { _shift_ids: shiftIds });
      if (error) throw error;

      const byShift = new Map<string, ShiftFinancials>();
      for (const raw of (data ?? []) as unknown as RawShift[]) {
        byShift.set(raw.shiftId, {
          ...raw,
          tenders: toTenders(raw.tenders),
          tenderCounts: toTenders(raw.tenderCounts),
          variance: raw.variance === null ? null : num(raw.variance),
        });
      }

      const list = [...byShift.values()];
      const pick = (fn: (s: ShiftFinancials) => number) => sum(list.map(fn));
      const tenders = emptyTenders();
      const tenderCounts = emptyTenders();
      for (const key of TENDER_KEYS) {
        tenders[key] = pick((s) => s.tenders[key]);
        tenderCounts[key] = list.reduce((a, s) => a + s.tenderCounts[key], 0);
      }
      const totals: FinancialTotals = {
        shiftCount: list.length,
        gross: pick((s) => s.gross),
        offers: pick((s) => s.offers),
        discounts: pick((s) => s.discounts),
        points: pick((s) => s.points),
        refunds: pick((s) => s.refunds),
        staffRefunds: pick((s) => s.staffRefunds),
        venueRefunds: pick((s) => s.venueRefunds),
        netSales: pick((s) => s.netSales),
        rawCogs: pick((s) => s.rawCogs),
        cogs: pick((s) => s.cogs),
        waste: pick((s) => s.waste),
        shrinkage: pick((s) => s.shrinkage),
        grossMargin: pick((s) => s.grossMargin),
        cashRefunds: pick((s) => s.cashRefunds),
        shiftExpenses: pick((s) => s.shiftExpenses),
        variance: pick((s) => s.variance ?? 0),
        tenders,
        tenderCounts,
      };
      return { byShift, totals };
    },
  });
}
