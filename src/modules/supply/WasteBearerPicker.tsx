import { Building2, UserRound, Users, type LucideIcon } from "lucide-react";

import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { useAuth } from "@/lib/auth";
import { formatMoney } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { cn } from "@/lib/utils";
import { useStaffCandidates } from "@/modules/operations/shift-workflow";

export type WasteBearer = "business" | "staff" | "all_staff";

export const WASTE_BEARERS: Record<
  WasteBearer,
  { icon: LucideIcon; ar: string; en: string; arHint: string; enHint: string }
> = {
  business: {
    icon: Building2,
    ar: "المكان",
    en: "The business",
    arHint: "تتسجل خسارة تشغيل في قائمة الدخل",
    enHint: "Recorded as an operating loss in the P&L",
  },
  staff: {
    icon: UserRound,
    ar: "موظف معيّن",
    en: "One employee",
    arHint: "تتخصم من مرتبه أو مكافأته",
    enHint: "Deducted from their salary or bonus",
  },
  all_staff: {
    icon: Users,
    ar: "كل الفريق",
    en: "Entire staff",
    arHint: "تتقسم بالتساوي كخصم جماعي",
    enHint: "Split evenly as a collective deduction",
  },
};

/** The bearer and employee are both chosen (employee only when one employee bears it). */
export const bearerReady = (bearer: WasteBearer | null, staffId: string) =>
  bearer !== null && (bearer !== "staff" || Boolean(staffId));

/**
 * The one "Who bears the cost?" control, used for manual waste, returns and
 * cancelled / removed items that were already made.
 */
export function WasteBearerPicker({
  value,
  onChange,
  staffId,
  onStaffIdChange,
  amount,
  allowStaff = true,
  idPrefix = "bearer",
}: {
  value: WasteBearer | null;
  onChange: (value: WasteBearer) => void;
  staffId: string;
  onStaffIdChange: (id: string) => void;
  /** The cost being attributed, shown in the hints. */
  amount?: number | undefined;
  /** False hides the staff options (e.g. no permission to charge staff). */
  allowStaff?: boolean;
  idPrefix?: string;
}) {
  const { lang } = useI18n();
  const ar = lang === "ar";
  const { me } = useAuth();
  const currency = me?.company?.currency ?? "EGP";
  const staff = useStaffCandidates(allowStaff);
  const people = staff.data?.length ?? 0;
  const money = (n: number) => formatMoney(n, currency, lang);
  const options = (Object.keys(WASTE_BEARERS) as WasteBearer[]).filter(
    (key) => key === "business" || allowStaff,
  );

  return (
    <fieldset className="space-y-2">
      <legend className="mb-2 text-sm font-semibold">
        {ar ? "مين يتحمل التكلفة؟" : "Who bears the cost?"}{" "}
        <span className="text-destructive">*</span>
      </legend>
      <div role="radiogroup" className="grid gap-2 sm:grid-cols-3">
        {options.map((key) => {
          const b = WASTE_BEARERS[key];
          const Icon = b.icon;
          const active = value === key;
          return (
            <button
              key={key}
              type="button"
              role="radio"
              aria-checked={active}
              onClick={() => onChange(key)}
              className={cn(
                "flex flex-col items-start gap-1.5 rounded-xl border bg-card p-3 text-start transition-all active:scale-[0.98]",
                active
                  ? "border-primary shadow-sm ring-2 ring-primary/30"
                  : "border-border hover:border-primary/40 hover:bg-tint",
              )}
            >
              <span
                className={cn(
                  "flex size-8 items-center justify-center rounded-lg",
                  active
                    ? "bg-gradient-module text-primary-foreground"
                    : "bg-muted text-muted-foreground",
                )}
              >
                <Icon className="size-4" aria-hidden />
              </span>
              <span className="text-sm font-semibold">{ar ? b.ar : b.en}</span>
              <span className="text-[11px] leading-snug text-muted-foreground">
                {ar ? b.arHint : b.enHint}
              </span>
            </button>
          );
        })}
      </div>
      {!allowStaff && (
        <p className="text-[11px] text-muted-foreground">
          {ar
            ? "تحميل التكلفة على الموظفين للمدير بس."
            : "Only a manager can charge this to staff."}
        </p>
      )}

      {value === "staff" && (
        <div className="flex flex-col gap-1.5 pt-1 animate-pop-in">
          <Label htmlFor={`${idPrefix}-staff`} className="text-xs text-muted-foreground">
            {ar ? "الموظف المسؤول" : "Responsible employee"}
          </Label>
          <Select value={staffId} onValueChange={onStaffIdChange}>
            <SelectTrigger id={`${idPrefix}-staff`}>
              <SelectValue placeholder={ar ? "اختار الموظف" : "Select employee"} />
            </SelectTrigger>
            <SelectContent>
              {(staff.data ?? []).map((p) => (
                <SelectItem key={p.id} value={p.id}>
                  {p.name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
          {amount !== undefined && (
            <p className="text-[11px] text-muted-foreground">
              {ar
                ? `هيتسجل عليه خصم ${money(amount)} في أقرب مرتب.`
                : `A ${money(amount)} deduction goes on their next payroll.`}
            </p>
          )}
        </div>
      )}
      {value === "all_staff" && (
        <p className="rounded-lg bg-muted p-3 text-[11px] text-muted-foreground animate-pop-in">
          {people === 0
            ? ar
              ? "مفيش موظفين نشطين."
              : "No active staff."
            : amount !== undefined
              ? ar
                ? `هيتقسم على ${people} موظف ≈ ${money(amount / people)} لكل واحد.`
                : `Split over ${people} staff ≈ ${money(amount / people)} each.`
              : ar
                ? `هيتقسم بالتساوي على ${people} موظف.`
                : `Split evenly over ${people} staff.`}
        </p>
      )}
      {value === "business" && (
        <p className="rounded-lg bg-muted p-3 text-[11px] text-muted-foreground animate-pop-in">
          {ar
            ? "هتظهر في قائمة الدخل كخسارة تشغيل على المكان."
            : "Shows in the P&L as an operating loss for the business."}
        </p>
      )}
    </fieldset>
  );
}
