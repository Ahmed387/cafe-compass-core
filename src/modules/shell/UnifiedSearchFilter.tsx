import { Search, X } from "lucide-react";
import type { ReactNode } from "react";

import { Input } from "@/components/ui/input";
import { cn } from "@/lib/utils";

export type FilterOption = { value: string; label: string };
export type FilterDef = { key: string; label: string; value: string; options: FilterOption[]; onChange: (v: string) => void };

/** The single search + filter bar used on every list page. One search input, optional dropdowns and extra fields. */
export function UnifiedSearchFilter({
  search,
  onSearch,
  placeholder,
  filters = [],
  children,
  className,
}: {
  search: string;
  onSearch: (v: string) => void;
  placeholder: string;
  filters?: FilterDef[];
  children?: ReactNode;
  className?: string;
}) {
  return (
    <div className={cn("mb-3 flex flex-wrap items-center gap-2 rounded-xl border border-border bg-card p-2", className)}>
      <div className="relative min-w-0 flex-1 basis-56">
        <Search className="pointer-events-none absolute start-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
        <Input
          type="search"
          value={search}
          onChange={(e) => onSearch(e.target.value)}
          placeholder={placeholder}
          aria-label={placeholder}
          className="h-11 ps-9 pe-9"
        />
        {search && (
          <button
            type="button"
            aria-label="clear"
            onClick={() => onSearch("")}
            className="absolute end-2 top-1/2 grid size-7 -translate-y-1/2 place-items-center rounded-md text-muted-foreground hover:bg-muted"
          >
            <X className="h-4 w-4" />
          </button>
        )}
      </div>
      {filters.map((f) => (
        <select
          key={f.key}
          aria-label={f.label}
          title={f.label}
          value={f.value}
          onChange={(e) => f.onChange(e.target.value)}
          className="h-11 shrink-0 rounded-md border border-input bg-background px-3 text-sm"
        >
          {f.options.map((o) => (
            <option key={o.value} value={o.value}>
              {o.label}
            </option>
          ))}
        </select>
      ))}
      {children}
    </div>
  );
}

export const matches = (q: string, ...fields: Array<string | null | undefined>) => {
  const s = q.trim().toLowerCase();
  return !s || fields.some((f) => (f ?? "").toLowerCase().includes(s));
};
