import { ChefHat, PackageCheck, type LucideIcon } from "lucide-react";
import { useState } from "react";

import { useI18n } from "@/lib/i18n";
import { cn } from "@/lib/utils";
import {
  WasteBearerPicker,
  bearerReady,
  type WasteBearer,
} from "@/modules/supply/WasteBearerPicker";

export type Disposition = {
  /** null until the cashier answers "was it made?" */
  prepared: boolean | null;
  bearer: WasteBearer | null;
  staffId: string;
};

export const emptyDisposition: Disposition = { prepared: null, bearer: null, staffId: "" };

export function useDisposition() {
  const [value, setValue] = useState<Disposition>(emptyDisposition);
  const ready =
    value.prepared === false ||
    (value.prepared === true && bearerReady(value.bearer, value.staffId));
  /** RPC args for cancel_pos_order / void_order_item. */
  const args = value.prepared
    ? {
        _prepared: true,
        ...(value.bearer ? { _bearer: value.bearer } : {}),
        ...(value.bearer === "staff" ? { _staff_id: value.staffId } : {}),
      }
    : { _prepared: false };
  return { value, setValue, ready, args, reset: () => setValue(emptyDisposition) };
}

function Choice({
  active,
  icon: Icon,
  title,
  hint,
  tone,
  onClick,
}: {
  active: boolean;
  icon: LucideIcon;
  title: string;
  hint: string;
  tone: "ok" | "warn";
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      role="radio"
      aria-checked={active}
      onClick={onClick}
      className={cn(
        "flex items-start gap-3 rounded-xl border bg-card p-3 text-start transition-all active:scale-[0.98]",
        active
          ? tone === "ok"
            ? "border-success shadow-sm ring-2 ring-success/30"
            : "border-destructive shadow-sm ring-2 ring-destructive/25"
          : "border-border hover:border-primary/40 hover:bg-tint",
      )}
    >
      <span
        className={cn(
          "flex size-9 shrink-0 items-center justify-center rounded-lg",
          active
            ? tone === "ok"
              ? "bg-success text-success-foreground"
              : "bg-destructive text-destructive-foreground"
            : "bg-muted text-muted-foreground",
        )}
      >
        <Icon className="size-4" aria-hidden />
      </span>
      <span className="min-w-0">
        <span className="block text-sm font-semibold">{title}</span>
        <span className="block text-[11px] leading-snug text-muted-foreground">{hint}</span>
      </span>
    </button>
  );
}

/**
 * "Was it already made?" for cancelling an order or removing a line before delivery.
 * Not made → ingredients go back to stock. Made → no restock; the ingredients are
 * written off as waste and "Who bears the cost?" is required.
 */
export function PreparedDisposition({
  value,
  onChange,
  idPrefix,
}: {
  value: Disposition;
  onChange: (value: Disposition) => void;
  idPrefix: string;
}) {
  const { lang } = useI18n();
  const ar = lang === "ar";
  return (
    <div className="space-y-3">
      <p className="text-sm font-semibold">
        {ar ? "البار كان حضّر الطلب؟" : "Had the bar already made it?"}{" "}
        <span className="text-destructive">*</span>
      </p>
      <div role="radiogroup" className="grid gap-2 sm:grid-cols-2">
        <Choice
          active={value.prepared === false}
          icon={PackageCheck}
          tone="ok"
          title={ar ? "لسه ما اتحضرش" : "Not made yet"}
          hint={
            ar ? "الخامات ترجع المخزن، من غير أي خسارة." : "Ingredients go back to stock — no loss."
          }
          onClick={() => onChange({ prepared: false, bearer: null, staffId: "" })}
        />
        <Choice
          active={value.prepared === true}
          icon={ChefHat}
          tone="warn"
          title={ar ? "اتحضر خلاص" : "Already made"}
          hint={ar ? "مش هترجع المخزن — تتسجل هالك." : "Not restocked — written off as waste."}
          onClick={() => onChange({ ...value, prepared: true })}
        />
      </div>
      {value.prepared === true && (
        <div className="rounded-xl border border-destructive/30 bg-card p-3 animate-pop-in">
          <WasteBearerPicker
            idPrefix={idPrefix}
            value={value.bearer}
            onChange={(bearer) => onChange({ ...value, bearer })}
            staffId={value.staffId}
            onStaffIdChange={(staffId) => onChange({ ...value, staffId })}
          />
        </div>
      )}
    </div>
  );
}
