import { ChevronLeft, ChevronRight } from "lucide-react";

import { Button } from "@/components/ui/button";
import { useI18n } from "@/lib/i18n";

/**
 * Server-side pagination control.
 * `page` is zero-based; `total` is the exact row count reported by the server,
 * so page-size changes never affect the KPI totals shown above a table.
 */
export function Pagination({
  page,
  pageSize,
  total,
  onPage,
  loading = false,
}: {
  page: number;
  pageSize: number;
  total: number;
  onPage: (page: number) => void;
  loading?: boolean;
}) {
  const { t, lang } = useI18n();
  const pages = Math.max(1, Math.ceil(total / pageSize));
  if (total === 0) return null;
  const first = page * pageSize + 1;
  const last = Math.min(total, (page + 1) * pageSize);
  const rtl = lang === "ar";

  const numbers: number[] = [];
  const start = Math.max(0, Math.min(page - 2, pages - 5));
  for (let i = start; i < Math.min(pages, start + 5); i += 1) numbers.push(i);

  return (
    <div className="flex flex-wrap items-center justify-between gap-3 border-t border-border px-3 py-2 text-xs text-muted-foreground">
      <span className="tabular-nums">
        {t("table.showing")} {first}–{last} {t("table.of")} {total}
      </span>
      <div className="flex items-center gap-1">
        <Button
          type="button"
          size="sm"
          variant="outline"
          className="gap-1"
          disabled={page === 0 || loading}
          onClick={() => onPage(page - 1)}
        >
          {rtl ? <ChevronRight className="h-4 w-4" /> : <ChevronLeft className="h-4 w-4" />}
          {t("table.prev")}
        </Button>
        {numbers.map((n) => (
          <Button
            key={n}
            type="button"
            size="sm"
            variant={n === page ? "default" : "ghost"}
            className="min-w-8 px-2 tabular-nums"
            disabled={loading}
            onClick={() => onPage(n)}
          >
            {n + 1}
          </Button>
        ))}
        <Button
          type="button"
          size="sm"
          variant="outline"
          className="gap-1"
          disabled={page >= pages - 1 || loading}
          onClick={() => onPage(page + 1)}
        >
          {t("table.next")}
          {rtl ? <ChevronLeft className="h-4 w-4" /> : <ChevronRight className="h-4 w-4" />}
        </Button>
      </div>
    </div>
  );
}
