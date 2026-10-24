import { useQuery } from "@tanstack/react-query";

import { addDays, businessToday, monthToDate } from "@/core/finance/business-dates";
import { supabase } from "@/integrations/supabase/client";

/** Shape returned by the `range_pnl` database function (the single P&L source of truth). */
export type RangePnl = {
  from: string;
  to: string;
  days: number;
  orders_count: number;
  gross_sales: number;
  promo_discount: number;
  manual_discounts: number;
  points_redeemed: number;
  refunds_total: number;
  revenue: number;
  tax_collected: number;
  cogs: number;
  cogs_returned: number;
  refund_waste_info: number;
  waste_cost: number;
  /** Waste the business absorbs (operating loss). */
  waste_business?: number;
  /** Waste charged to staff; their penalties lower payroll cost when deducted. */
  waste_charged_staff?: number;
  stocktake_shortage: number;
  gross_profit: number;
  expenses_total: number;
  expenses_pending: number;
  expenses_pending_count: number;
  payroll_total: number;
  management_salary_recorded: number;
  cash_shortage: number;
  cash_over: number;
  operating_total: number;
  net_profit: number;
  partner_tab_open: number;
  departments: Array<{ key: "sales" | "warehouse" | "operations"; income: number; cost: number; result: number }>;
};

export type PayoutLine = {
  partner_id: string;
  name: string;
  pct: number;
  paused: boolean;
  amount: number;
  tab_open: number;
  tab_deduct: number;
  cash_due: number;
  tab_carried: number;
  advance_open: number;
  advance_deduct: number;
  advance_carried: number;
};

export type Sustainability = {
  reached: boolean;
  required_consecutive_months: number;
  consecutive_profitable_months: number;
  complete_months: number;
  months_remaining: number;
  average_net_profit: number | null;
  average_operating_cost: number | null;
  treasury_balance: number;
  runway_months: number | null;
  history: Array<{ month: string; from: string; to: string; complete: boolean; revenue: number; costs: number; net_profit: number }>;
};

export type PayoutPreview = {
  from: string;
  to: string;
  pnl: RangePnl;
  net_profit: number;
  management_salary_total: number;
  management_salary_recorded: number;
  management_salary_due: number;
  net_after_management: number;
  reserve_type: "percent" | "amount";
  reserve_value: number;
  reserve_amount: number;
  /** Profit left after reserve, before partner loans are repaid. */
  available_before_loans: number;
  loan_repayment: number;
  loans: Array<{ contribution_id: string; partner_id: string; name: string; date: string; open: number; repay: number; carried: number }>;
  available_before_fund: number;
  development_fund: number;
  partner_pool: number;
  retained_paused: number;
  lines: PayoutLine[];
  /** Share periods inside the range; more than one when shares changed. */
  segments: Array<{ from: string; to: string; net_profit: number; shares: Record<string, number> }>;
  sustainability: Sustainability;
  checks: Record<
    | "range_valid" | "no_overlap" | "no_open_shifts" | "no_open_orders" | "net_positive"
    | "fund_within_limit" | "partner_pool_positive" | "shares_total_100" | "payroll_recorded",
    boolean
  >;
  /** Employees with a salary and no salary line for a month in the range (blocks the payout). */
  payroll_missing?: {
    lines: Array<{ user_id: string; name: string; month: string; estimate: number }>;
    total: number;
    count: number;
  };
  overlaps: Array<{ id: string; from: string; to: string }>;
  open_shifts: number;
  open_orders: number;
  share_total: number;
};

export type PayoutRecord = {
  id: string;
  status: "active" | "reversed";
  from: string | null;
  to: string | null;
  distributed_at: string | null;
  partner_pool: number;
  development_fund: number;
  management_salary: number;
  reserve_amount: number;
  tab_deducted: number;
  notes: string | null;
  reverse_reason: string | null;
  lines: Array<{ partner_id: string; name: string | null; pct: number; amount: number; paid: boolean }>;
  net_profit_at_payout: number | null;
  net_profit_now: number | null;
  drift: number | null;
};

export function useRangePnl(from: string, to: string, enabled = true) {
  return useQuery({
    queryKey: ["range-pnl", from, to],
    enabled: enabled && Boolean(from && to) && from <= to,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("range_pnl", { _from: from, _to: to });
      if (error) throw error;
      return data as unknown as RangePnl;
    },
  });
}

export function useSustainability(enabled = true) {
  return useQuery({
    queryKey: ["financial-self-sustainability"],
    enabled,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("financial_self_sustainability");
      if (error) throw error;
      return data as unknown as Sustainability;
    },
  });
}

export function usePayoutHistory(enabled = true) {
  return useQuery({
    queryKey: ["payout-history"],
    enabled,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("payout_history", { _limit: 24 });
      if (error) throw error;
      return data as unknown as { payouts: PayoutRecord[]; development_fund_balance: number; first_business_day?: string | null };
    },
  });
}

/** Day after the last active payout, or the first business day when nothing was paid yet. */
export function nextUnpaidDay(history: PayoutRecord[] | undefined, firstBusinessDay?: string | null): string {
  const lastTo = (history ?? [])
    .filter((p) => p.status === "active" && p.to)
    .map((p) => p.to as string)
    .sort()
    .at(-1);
  return lastTo ? addDays(lastTo, 1) : firstBusinessDay ?? monthToDate().start;
}

/** Net profit earned since the last payout (what is waiting to be distributed). */
export function useUnpaidProfit(enabled = true) {
  const history = usePayoutHistory(enabled);
  const from = nextUnpaidDay(history.data?.payouts, history.data?.first_business_day);
  const to = businessToday();
  const pnl = useRangePnl(from, to, enabled && history.isSuccess && from <= to);
  return { from, to, pnl, sinceLastPayout: Boolean(history.data?.payouts.some((p) => p.status === "active")) };
}
