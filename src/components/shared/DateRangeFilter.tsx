import { CalendarRange } from "lucide-react";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { addDays, businessMonth, businessToday, monthBounds, previousMonth } from "@/core/finance/business-dates";
import { useI18n } from "@/lib/i18n";

export type DateRange = { from: string; to: string };

/** Quick range presets shared by every screen that filters by date (café business days, Cairo time). */
export const RANGE_PRESETS: Record<
  "today" | "yesterday" | "thisMonth" | "lastMonth",
  () => DateRange
> = {
  today: () => {
    const day = businessToday();
    return { from: day, to: day };
  },
  yesterday: () => {
    const day = addDays(businessToday(), -1);
    return { from: day, to: day };
  },
  thisMonth: () => {
    const { start, end } = monthBounds(businessMonth());
    return { from: start, to: end };
  },
  lastMonth: () => {
    const { start, end } = previousMonth();
    return { from: start, to: end };
  },
};

export function currentMonthRange(): DateRange {
  return RANGE_PRESETS.thisMonth();
}

export function DateRangeFilter({
  value,
  onChange,
  className,
}: {
  value: DateRange;
  onChange: (next: DateRange) => void;
  className?: string | undefined;
}) {
  const { t } = useI18n();

  const presets: Array<{ key: keyof typeof RANGE_PRESETS; labelKey: string }> = [
    { key: "today", labelKey: "range.today" },
    { key: "yesterday", labelKey: "range.yesterday" },
    { key: "thisMonth", labelKey: "range.thisMonth" },
    { key: "lastMonth", labelKey: "range.lastMonth" },
  ];

  const activeKey = presets.find((preset) => {
    const range = RANGE_PRESETS[preset.key]();
    return range.from === value.from && range.to === value.to;
  })?.key;

  return (
    <div
      className={`flex flex-wrap items-end gap-3 rounded-xl border border-border/60 bg-card p-3 ${className ?? ""}`}
    >
      <div className="space-y-1">
        <Label className="text-xs text-muted-foreground">{t("range.from")}</Label>
        <Input
          type="date"
          value={value.from}
          className="h-9 w-[150px]"
          onChange={(event) => onChange({ ...value, from: event.target.value })}
        />
      </div>
      <div className="space-y-1">
        <Label className="text-xs text-muted-foreground">{t("range.to")}</Label>
        <Input
          type="date"
          value={value.to}
          className="h-9 w-[150px]"
          onChange={(event) => onChange({ ...value, to: event.target.value })}
        />
      </div>
      <div className="flex flex-wrap items-center gap-1.5">
        <CalendarRange className="size-4 text-muted-foreground" aria-hidden />
        {presets.map((preset) => (
          <Button
            key={preset.key}
            type="button"
            size="sm"
            variant={activeKey === preset.key ? "default" : "outline"}
            className="h-8"
            onClick={() => onChange(RANGE_PRESETS[preset.key]())}
          >
            {t(preset.labelKey)}
          </Button>
        ))}
      </div>
    </div>
  );
}
