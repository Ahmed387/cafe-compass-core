import { ChevronDown, Info, ListTree } from "lucide-react";
import { useState, type ReactNode } from "react";

import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@/components/ui/tooltip";
import { topicIcon } from "@/lib/ui-icons";
import { cn } from "@/lib/utils";

/** Presentational KPI card shared by every page's top strip. Data lives in the page. */
export function KpiCard({
  label,
  value,
  hint,
  tone,
  icon,
  formula,
  source,
  detailTitle,
  details,
  size = "default",
}: {
  label: string;
  value: ReactNode;
  hint?: ReactNode | undefined;
  tone?: "good" | "bad" | "warn" | "brand" | undefined;
  icon?: ReactNode | undefined;
  formula?: ReactNode | undefined;
  source?: string | undefined;
  detailTitle?: string | undefined;
  details?: ReactNode | undefined;
  size?: "default" | "master" | undefined;
}) {
  const [detailsOpen, setDetailsOpen] = useState(false);
  const AutoIcon = icon ? null : topicIcon(label);
  const explanation = formula ?? "القيمة من السجلات الحالية والفلاتر النشطة · Current records and active filters.";
  const color =
    tone === "bad"
      ? "text-destructive"
      : tone === "good"
        ? "text-success"
        : tone === "warn"
          ? "text-accent"
          : tone === "brand"
            ? "text-primary"
            : "text-foreground";
  const body = (
    <div className={cn("kpi-glass group relative min-w-0 animate-card-in overflow-hidden rounded-2xl border border-border p-4 text-start shadow-sm before:absolute before:inset-y-3 before:start-0 before:w-1 before:rounded-e-full before:bg-gradient-module before:opacity-70", details && "transition hover:border-primary/40 hover:shadow-md", size === "master" && "bg-gradient-card p-5 sm:p-6")}>
      <div className="grid grid-cols-[minmax(0,1fr)_auto] items-start gap-2">
        <p className={cn("min-w-0 text-xs font-medium text-muted-foreground", size === "master" && "text-sm")}>{label}</p>
        <span className="flex shrink-0 items-center gap-1.5">
          {(
            <TooltipProvider>
              <Tooltip>
                <TooltipTrigger asChild>
                  <span aria-label="Calculation details" className="inline-flex size-6 items-center justify-center rounded-full text-muted-foreground group-hover:bg-muted group-hover:text-foreground">
                    <Info className="size-3.5" />
                  </span>
                </TooltipTrigger>
                <TooltipContent className="max-w-72 space-y-1 text-start" side="top">
                  <div>{explanation}</div>
                  {source && <div className="opacity-80">{source}</div>}
                </TooltipContent>
              </Tooltip>
            </TooltipProvider>
          )}
          {details && <ListTree className="size-4 text-muted-foreground transition-colors group-hover:text-foreground" />}
          {(icon || AutoIcon) && (
            <span className="icon-chip-soft size-8 transition-transform duration-300 group-hover:scale-110 group-hover:-rotate-6 [&_svg]:size-4">
              {icon ?? (AutoIcon && <AutoIcon aria-hidden />)}
            </span>
          )}
        </span>
      </div>
      <p className={cn("mt-1.5 break-words font-display text-lg leading-tight font-bold tabular-nums sm:text-2xl", size === "master" && "text-2xl sm:text-3xl", color)}>{value}</p>
      {hint && <p className="mt-1 text-xs text-muted-foreground">{hint}</p>}
    </div>
  );
  return (
    <>
      <Button
        type="button"
        variant="ghost"
        className="h-auto min-w-0 justify-stretch whitespace-normal rounded-xl p-0 text-start focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2"
        onClick={() => setDetailsOpen(true)}
        aria-label={`${label} — details`}
      >
        <span className="block min-w-0 flex-1">{body}</span>
      </Button>
      <Dialog open={detailsOpen} onOpenChange={setDetailsOpen}>
          <DialogContent className="max-w-2xl">
            <DialogHeader className="pe-8 text-start">
              <DialogTitle>{detailTitle ?? label}</DialogTitle>
              <DialogDescription className="space-y-1">
                  <span className="block">{explanation}</span>
                  {source && <span className="block">{source}</span>}
              </DialogDescription>
            </DialogHeader>
            <div className="min-w-0">
              {details ?? (
                <div className="rounded-xl border border-border bg-muted/40 p-4">
                  <p className="text-xs text-muted-foreground">{label}</p>
                  <p className={cn("mt-1 break-words font-display text-2xl font-bold tabular-nums", color)}>{value}</p>
                  {hint && <p className="mt-1 text-xs text-muted-foreground">{hint}</p>}
                </div>
              )}
            </div>
          </DialogContent>
      </Dialog>
    </>
  );
}

export function KpiDetailRows({
  rows,
  empty,
}: {
  rows: Array<{ label: ReactNode; value: ReactNode; hint?: ReactNode }>;
  empty?: string;
}) {
  if (rows.length === 0) return <p className="py-8 text-center text-sm text-muted-foreground">{empty ?? "No records"}</p>;
  return (
    <div className="max-h-[58vh] divide-y divide-border overflow-y-auto rounded-xl border border-border bg-card">
      {rows.map((row, index) => (
        <div key={index} className="grid grid-cols-[minmax(0,1fr)_auto] gap-3 p-3 text-sm">
          <div className="min-w-0">
            <div className="truncate font-medium">{row.label}</div>
            {row.hint && <div className="mt-0.5 truncate text-xs text-muted-foreground">{row.hint}</div>}
          </div>
          <div className="shrink-0 font-semibold tabular-nums">{row.value}</div>
        </div>
      ))}
    </div>
  );
}

export function KpiGrid({ children, cols = 4, title }: { children: ReactNode; cols?: 3 | 4 | 5 | 6; title?: string }) {
  const [open, setOpen] = useState(true);
  const grid =
    cols === 3
      ? "sm:grid-cols-3"
      : cols === 5
        ? "sm:grid-cols-3 lg:grid-cols-5"
        : cols === 6
          ? "sm:grid-cols-2 lg:grid-cols-3"
          : "sm:grid-cols-2 lg:grid-cols-4";
  return (
    <section className="mb-4">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        aria-expanded={open}
        className="mb-2 flex min-h-9 items-center gap-1.5 rounded-md px-1 text-xs font-semibold text-muted-foreground hover:text-foreground"
      >
        <ChevronDown className={cn("size-4 transition-transform duration-200", !open && "-rotate-90 rtl:rotate-90")} />
        {title ?? "المؤشرات · KPIs"}
      </button>
      {open && <div className={cn("grid grid-cols-2 gap-3 animate-fade-in", grid)}>{children}</div>}
    </section>
  );
}

/** Independently collapsible card group with a header toggle arrow. */
export function CollapsibleSection({
  title,
  description,
  icon,
  actions,
  children,
  defaultOpen = true,
  className,
}: {
  title: ReactNode;
  description?: ReactNode;
  icon?: ReactNode;
  actions?: ReactNode;
  children: ReactNode;
  defaultOpen?: boolean;
  className?: string;
}) {
  const [open, setOpen] = useState(defaultOpen);
  return (
    <section className={cn("rounded-2xl border border-border bg-card/60 p-3 shadow-sm sm:p-4", className)}>
      <div className="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-2">
        <button
          type="button"
          onClick={() => setOpen((v) => !v)}
          aria-expanded={open}
          className="flex min-h-9 min-w-0 items-center gap-2 rounded-md text-start"
        >
          <ChevronDown className={cn("size-4 shrink-0 text-muted-foreground transition-transform duration-200", !open && "-rotate-90 rtl:rotate-90")} />
          {icon && <span className="shrink-0 text-primary">{icon}</span>}
          <span className="min-w-0">
            <span className="block truncate text-sm font-semibold">{title}</span>
            {description && <span className="block truncate text-xs text-muted-foreground">{description}</span>}
          </span>
        </button>
        {actions && <div className="flex shrink-0 items-center gap-2">{actions}</div>}
      </div>
      {open && <div className="mt-3 animate-fade-in">{children}</div>}
    </section>
  );
}
