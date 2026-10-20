import { useQuery } from "@tanstack/react-query";

import { supabase } from "@/integrations/supabase/client";
import { isMissingFunction } from "@/lib/supabase-errors";

export type PosCustomer = {
  id: string;
  code: string;
  name: string;
  phone: string | null;
  wallet_balance: number;
  cashback_progress: number;
  points_balance?: number | null;
};

/** Typing in the phone box searches after 3 digits; the search box after 2 characters. */
export const MIN_PHONE_DIGITS = 3;
export const MIN_QUERY_CHARS = 2;

/**
 * The text the till searches with: the explicit search box wins, otherwise the
 * phone field once it holds enough digits. Characters that break a PostgREST
 * `or()` filter are dropped.
 */
export function customerLookupTerm(query: string, phone: string): string {
  const q = query.trim().replace(/[%,()\\]/g, "");
  if (q.length >= MIN_QUERY_CHARS) return q;
  const digits = phone.replace(/\D/g, "");
  return digits.length >= MIN_PHONE_DIGITS ? digits : "";
}

/**
 * Saved customers matching what the cashier typed. Uses pos_customer_lookup,
 * which any seller may call and which returns only till fields; falls back to
 * the customers table for staff with loyalty access when the function is missing.
 */
export function usePosCustomerLookup(term: string, opts: { enabled: boolean; canBrowseCustomers: boolean }) {
  return useQuery({
    queryKey: ["pos-customer-lookup", term],
    enabled: opts.enabled && term.length > 0,
    staleTime: 15_000,
    queryFn: async (): Promise<PosCustomer[]> => {
      const { data, error } = await supabase.rpc("pos_customer_lookup" as never, { _term: term } as never);
      if (!error) return ((data ?? []) as unknown as PosCustomer[]).map(normalize);
      if (!isMissingFunction(error) || !opts.canBrowseCustomers) throw error;
      const { data: rows, error: tableError } = await supabase
        .from("customers")
        .select("id, code, name, phone, wallet_balance, cashback_progress, points_balance")
        .eq("is_active", true)
        .or(`phone.ilike.%${term}%,code.ilike.%${term}%,barcode.ilike.%${term}%,name.ilike.%${term}%`)
        .order("last_visit_at", { ascending: false, nullsFirst: false })
        .limit(8);
      if (tableError) throw tableError;
      return (rows ?? []).map(normalize);
    },
  });
}

function normalize(row: PosCustomer): PosCustomer {
  return {
    ...row,
    wallet_balance: Number(row.wallet_balance ?? 0),
    cashback_progress: Number(row.cashback_progress ?? 0),
  };
}
