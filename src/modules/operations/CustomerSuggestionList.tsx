import { Badge } from "@/components/ui/badge";
import { formatMoney } from "@/lib/format";

import type { PosCustomer } from "./pos-customer-lookup";

/** Saved customers matching the phone / search text; tapping one links it to the invoice. */
export function CustomerSuggestionList({
  rows,
  loading,
  lang,
  currency,
  onPick,
  emptyText,
}: {
  rows: PosCustomer[];
  loading: boolean;
  lang: "ar" | "en";
  currency: string;
  onPick: (row: PosCustomer) => void;
  emptyText?: string;
}) {
  if (loading && rows.length === 0) {
    return <p className="p-2 text-xs text-muted-foreground">{lang === "ar" ? "بيدوّر…" : "Searching…"}</p>;
  }
  if (rows.length === 0) {
    return emptyText ? <p className="p-2 text-xs text-muted-foreground">{emptyText}</p> : null;
  }
  return (
    <div className="max-h-40 overflow-y-auto rounded-md border border-border" role="listbox">
      {rows.map((row) => (
        <button
          key={row.id}
          type="button"
          role="option"
          aria-selected={false}
          onClick={() => onPick(row)}
          className="flex w-full items-center justify-between gap-2 border-b border-border px-2 py-1.5 text-start text-xs transition-colors last:border-0 hover:bg-accent"
        >
          <span className="truncate">
            <span className="font-medium">{row.name}</span>{" "}
            <span className="text-muted-foreground" dir="ltr">{row.phone ?? ""}</span>
          </span>
          <span className="flex shrink-0 items-center gap-2">
            <span className="font-mono text-muted-foreground">{row.code}</span>
            <Badge variant="secondary">{formatMoney(row.wallet_balance, currency, lang)}</Badge>
          </span>
        </button>
      ))}
    </div>
  );
}
