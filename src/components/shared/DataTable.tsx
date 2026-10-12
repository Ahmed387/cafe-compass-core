import { ArrowDown, ArrowUp, ChevronsUpDown } from "lucide-react";
import { useMemo, useState, type ReactNode } from "react";

import { EmptyState } from "@/components/layout/AppShell";
import { Button } from "@/components/ui/button";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { useI18n } from "@/lib/i18n";

export type DataTableColumn<T> = {
  /** Stable id, also used as the sort key. */
  id: string;
  header: ReactNode;
  align?: "start" | "center" | "end";
  /** Returning a value makes the column sortable. */
  sortValue?: (row: T) => string | number | null | undefined;
  cell: (row: T, index: number) => ReactNode;
  headClassName?: string | undefined;
  cellClassName?: string | undefined;
};

export function DataTable<T>({
  rows,
  columns,
  rowKey,
  onRowClick,
  emptyMessage,
  pageSize = 0,
  initialSort,
  zebra = true,
  footer,
}: {
  rows: T[];
  columns: Array<DataTableColumn<T>>;
  rowKey: (row: T, index: number) => string;
  onRowClick?: ((row: T) => void) | undefined;
  emptyMessage: string;
  /** 0 disables pagination. */
  pageSize?: number;
  initialSort?: { id: string; dir: "asc" | "desc" } | undefined;
  zebra?: boolean;
  footer?: ReactNode;
}) {
  const { t } = useI18n();
  const [sort, setSort] = useState<{ id: string; dir: "asc" | "desc" } | null>(initialSort ?? null);
  const [page, setPage] = useState(0);

  const sorted = useMemo(() => {
    if (!sort) return rows;
    const column = columns.find((col) => col.id === sort.id);
    if (!column?.sortValue) return rows;
    const sortValue = column.sortValue;
    const factor = sort.dir === "asc" ? 1 : -1;
    return [...rows].sort((a, b) => {
      const av = sortValue(a);
      const bv = sortValue(b);
      if (av == null && bv == null) return 0;
      if (av == null) return 1;
      if (bv == null) return -1;
      if (typeof av === "number" && typeof bv === "number") return (av - bv) * factor;
      return String(av).localeCompare(String(bv)) * factor;
    });
  }, [rows, columns, sort]);

  const pageCount = pageSize > 0 ? Math.max(1, Math.ceil(sorted.length / pageSize)) : 1;
  const current = Math.min(page, pageCount - 1);
  const visible =
    pageSize > 0 ? sorted.slice(current * pageSize, current * pageSize + pageSize) : sorted;

  function toggleSort(id: string) {
    setPage(0);
    setSort((prev) =>
      prev?.id === id ? (prev.dir === "asc" ? { id, dir: "desc" } : null) : { id, dir: "asc" },
    );
  }

  const alignClass = (align: DataTableColumn<T>["align"]) =>
    align === "end" ? "text-end" : align === "center" ? "text-center" : "text-start";

  if (rows.length === 0) return <EmptyState message={emptyMessage} />;

  return (
    <div className="space-y-3">
      <div className="overflow-x-auto rounded-xl border border-border/60 bg-card shadow-sm">
        <Table>
          <TableHeader>
            <TableRow className="bg-muted/40">
              {columns.map((column) => {
                const sortable = Boolean(column.sortValue);
                const active = sort?.id === column.id;
                return (
                  <TableHead
                    key={column.id}
                    className={`whitespace-nowrap font-semibold ${alignClass(column.align)} ${column.headClassName ?? ""}`}
                  >
                    {sortable ? (
                      <button
                        type="button"
                        onClick={() => toggleSort(column.id)}
                        className={`inline-flex items-center gap-1 transition-colors hover:text-foreground ${active ? "text-foreground" : ""}`}
                      >
                        {column.header}
                        {active ? (
                          sort?.dir === "asc" ? (
                            <ArrowUp className="size-3.5" />
                          ) : (
                            <ArrowDown className="size-3.5" />
                          )
                        ) : (
                          <ChevronsUpDown className="size-3.5 opacity-40" />
                        )}
                      </button>
                    ) : (
                      column.header
                    )}
                  </TableHead>
                );
              })}
            </TableRow>
          </TableHeader>
          <TableBody>
            {visible.map((row, index) => (
              <TableRow
                key={rowKey(row, index)}
                {...(onRowClick ? { onClick: () => onRowClick(row) } : {})}
                className={`transition-colors ${onRowClick ? "cursor-pointer" : ""} ${zebra && index % 2 ? "bg-muted/25" : ""}`}
              >
                {columns.map((column) => (
                  <TableCell
                    key={column.id}
                    className={`${alignClass(column.align)} ${column.cellClassName ?? ""}`}
                  >
                    {column.cell(row, index)}
                  </TableCell>
                ))}
              </TableRow>
            ))}
          </TableBody>
        </Table>
        {footer}
      </div>

      {pageSize > 0 && pageCount > 1 && (
        <div className="flex flex-wrap items-center justify-between gap-2 text-sm text-muted-foreground">
          <span className="tabular-nums">
            {t("table.showing")} {current * pageSize + 1}–
            {Math.min(sorted.length, current * pageSize + pageSize)} / {sorted.length}
          </span>
          <div className="flex items-center gap-2">
            <Button
              size="sm"
              variant="outline"
              disabled={current === 0}
              onClick={() => setPage(current - 1)}
            >
              {t("table.prev")}
            </Button>
            <span className="tabular-nums">
              {current + 1} / {pageCount}
            </span>
            <Button
              size="sm"
              variant="outline"
              disabled={current >= pageCount - 1}
              onClick={() => setPage(current + 1)}
            >
              {t("table.next")}
            </Button>
          </div>
        </div>
      )}
    </div>
  );
}
