import { useI18n } from "@/lib/i18n";

type Tone = "success" | "warning" | "danger" | "info" | "neutral";

const TONES: Record<Tone, string> = {
  success: "border-emerald-500/30 bg-emerald-500/12 text-emerald-700 dark:text-emerald-300",
  warning: "border-amber-500/30 bg-amber-500/12 text-amber-700 dark:text-amber-300",
  danger: "border-destructive/30 bg-destructive/12 text-destructive",
  info: "border-primary/30 bg-primary/12 text-primary",
  neutral: "border-border bg-muted text-muted-foreground",
};

type StatusDef = { tone: Tone; en: string; ar: string };

/** Single source of truth for entity/transaction status presentation. */
export const STATUS_MAP: Record<string, StatusDef> = {
  active: { tone: "success", en: "Active", ar: "نشط" },
  inactive: { tone: "neutral", en: "Inactive", ar: "غير نشط" },
  open: { tone: "info", en: "Open", ar: "مفتوحة" },
  closed: { tone: "neutral", en: "Closed", ar: "مغلقة" },
  draft: { tone: "warning", en: "Draft", ar: "مسودة" },
  pending: { tone: "warning", en: "Pending", ar: "في الانتظار" },
  submitted: { tone: "warning", en: "Submitted", ar: "مُقدَّم" },
  approved: { tone: "success", en: "Approved", ar: "معتمد" },
  received: { tone: "success", en: "Received", ar: "مستلمة" },
  completed: { tone: "success", en: "Completed", ar: "مكتملة" },
  rejected: { tone: "danger", en: "Rejected", ar: "مرفوض" },
  cancelled: { tone: "danger", en: "Cancelled", ar: "ملغي" },
  voided: { tone: "danger", en: "Voided", ar: "ملغى" },
  reversed: { tone: "danger", en: "Reversed", ar: "معكوس" },
  refunded: { tone: "danger", en: "Refunded", ar: "مرتجع" },
  paid: { tone: "success", en: "Paid", ar: "مدفوع" },
  unpaid: { tone: "warning", en: "Unpaid", ar: "غير مدفوع" },
  partial: { tone: "warning", en: "Partially paid", ar: "مدفوع جزئياً" },
  settled: { tone: "success", en: "Settled", ar: "مسدد" },
  outstanding: { tone: "warning", en: "Outstanding", ar: "مستحق" },
  due: { tone: "danger", en: "Due", ar: "متأخر" },
  exited: { tone: "neutral", en: "Exited", ar: "منسحب" },
  queued: { tone: "warning", en: "Queued", ar: "في الطابور" },
  preparing: { tone: "info", en: "Preparing", ar: "قيد التحضير" },
  ready: { tone: "success", en: "Ready", ar: "جاهز" },
  served: { tone: "neutral", en: "Delivered", ar: "تم التسليم" },
};

export function StatusBadge({
  status,
  label,
  className,
}: {
  status: string | boolean | null | undefined;
  /** Overrides the mapped bilingual label when provided. */
  label?: string | undefined;
  className?: string | undefined;
}) {
  const { lang } = useI18n();
  const key =
    typeof status === "boolean" ? (status ? "active" : "inactive") : (status ?? "").toLowerCase();
  const def = STATUS_MAP[key];
  const tone = def?.tone ?? "neutral";
  const text = label ?? (def ? def[lang] : key || "—");

  return (
    <span
      className={`inline-flex items-center gap-1.5 rounded-full border px-2.5 py-0.5 text-xs font-semibold ${TONES[tone]} ${className ?? ""}`}
    >
      <span className="size-1.5 rounded-full bg-current opacity-70" />
      {text}
    </span>
  );
}
