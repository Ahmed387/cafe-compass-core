import { dbErrorToArabic } from "@/lib/db-errors-ar";

export function formatMoney(
  amount: number | string | null | undefined,
  currency = "EGP",
  lang: "en" | "ar" = "en",
) {
  const value = typeof amount === "string" ? Number(amount) : (amount ?? 0);
  try {
    return new Intl.NumberFormat(lang === "ar" ? "ar-EG" : "en-EG", {
      style: "currency",
      currency,
      maximumFractionDigits: 2,
    }).format(value);
  } catch {
    return `${value.toFixed(2)} ${currency}`;
  }
}

export function formatPercent(value: number | string | null | undefined, lang: "en" | "ar" = "en") {
  const num = typeof value === "string" ? Number(value) : (value ?? 0);
  return (
    new Intl.NumberFormat(lang === "ar" ? "ar-EG" : "en", {
      maximumFractionDigits: 2,
    }).format(num) + "%"
  );
}

export function formatDate(value: string | null | undefined, lang: "en" | "ar" = "en") {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "—";
  return new Intl.DateTimeFormat(lang === "ar" ? "ar-EG" : "en-GB", {
    dateStyle: "medium",
  }).format(date);
}

export function formatDateTime(value: string | null | undefined, lang: "en" | "ar" = "en") {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "—";
  return new Intl.DateTimeFormat(lang === "ar" ? "ar-EG" : "en-GB", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(date);
}

/** Turns a backend error into a message safe for non-technical users. */
function rawMessage(error: unknown): string {
  if (!error) return "";
  if (typeof error === "string") return error;
  if (error instanceof Error) return error.message;
  // Supabase returns plain objects (PostgrestError), not Error instances.
  if (typeof error === "object") {
    const e = error as { message?: unknown; details?: unknown; hint?: unknown };
    const parts = [e.message, e.details, e.hint].filter((v) => typeof v === "string");
    if (parts.length > 0) return parts.join(" · ");
  }
  return String(error);
}

export function friendlyError(error: unknown, lang: "en" | "ar" = "en"): string {
  const raw = rawMessage(error);
  const map: Array<[RegExp, { en: string; ar: string }]> = [
    [
      /row-level security|permission denied|not authorized|Unauthorized/i,
      {
        en: "You do not have permission to perform this action.",
        ar: "ليست لديك صلاحية لتنفيذ هذا الإجراء.",
      },
    ],
    [
      /products_company_sku_unique_idx/i,
      { en: "SKU already exists.", ar: "كود الصنف (SKU) مستخدم بالفعل." },
    ],
    [
      /products_company_name_unique_idx/i,
      { en: "Product name already exists.", ar: "اسم المنتج مستخدم بالفعل." },
    ],
    [
      /categories_company_name_unique_idx/i,
      { en: "Category name already exists.", ar: "اسم التصنيف مستخدم بالفعل." },
    ],
    [
      /duplicate key|already (exists|registered)|unique/i,
      { en: "This record already exists.", ar: "هذا السجل موجود بالفعل." },
    ],

    [
      /Invalid login credentials/i,
      { en: "Incorrect email or password.", ar: "البريد أو كلمة المرور غير صحيحة." },
    ],
    [
      /append-only|cannot be deleted/i,
      {
        en: "Financial records cannot be deleted, only reversed.",
        ar: "لا يمكن حذف السجلات المالية، يمكن فقط عكسها.",
      },
    ],
    // Profit payout safety locks.
    [/part of this range was already paid out/i, {
      en: "Part of this date range was already paid out. Pick days that weren't paid yet.",
      ar: "جزء من الفترة دي اتوزعت أرباحه قبل كده. اختار أيام لسه متوزعتش.",
    }],
    [/close the open shift/i, {
      en: "Close the open shift in this range first.",
      ar: "اقفل الوردية المفتوحة في الفترة دي الأول.",
    }],
    [/settle the unpaid order/i, {
      en: "Settle the unpaid orders in this range first.",
      ar: "فيه طلبات لسه متدفعتش في الفترة دي، خلّصها الأول.",
    }],
    [/no positive distributable profit/i, {
      en: "There's no positive profit to distribute in this range.",
      ar: "مفيش ربح موجب يتوزع في الفترة دي.",
    }],
    [/development fund (is larger|leaves nothing|cannot exceed)/i, {
      en: "The development fund is too large for this profit.",
      ar: "مبلغ صندوق التطوير أكبر من الربح المتاح.",
    }],
    [/partner shares must total 100/i, {
      en: "Active partner shares must total exactly 100%.",
      ar: "نسب الشركاء النشطين لازم مجموعها يبقى ١٠٠٪ بالظبط.",
    }],
    [/already received cash for this payout/i, {
      en: "A partner already received cash from this payout. Reverse that cash payout first.",
      ar: "فيه شريك استلم فلوس من التوزيع ده. اعكس الصرف ده الأول.",
    }],
    [/development fund money from this payout was already spent/i, {
      en: "The fund money from this payout was already spent, so it can't be reversed.",
      ar: "فلوس صندوق التطوير من التوزيع ده اتصرفت، فمينفعش يتعكس.",
    }],
    // Shift handover.
    [/Shortage must be attributed/i, {
      en: "There's a cash shortage: choose who carries it.",
      ar: "فيه عجز في الدرج: اختار مين هيتحمله.",
    }],
    [/already taken in payroll/i, {
      en: "This shortage was already deducted in payroll and can't be changed.",
      ar: "العجز ده اتخصم في المرتبات خلاص ومينفعش يتغير.",
    }],
  ];
  const stock = raw.match(/Not enough stock(?: available)? for (.+)/i);
  if (stock) {
    const item = stock[1]!.split(" · ")[0]!.trim();
    return lang === "ar" ? `الكمية المتاحة غير كافية من: ${item}` : `Not enough stock of: ${item}`;
  }
  if (/Not enough stock/i.test(raw)) {
    return lang === "ar"
      ? "الكمية المتاحة من أحد المكونات غير كافية."
      : "There is not enough stock of one of the ingredients.";
  }
  if (lang === "ar") {
    const translated = dbErrorToArabic(raw);
    if (translated) return translated;
  }
  for (const [pattern, message] of map) {
    if (pattern.test(raw)) return message[lang];
  }
  if (typeof console !== "undefined") console.error(error);
  const technical = /relation |column |syntax|function |JWT|fetch|constraint|violates/i.test(raw);
  // In Arabic, an English message we have no wording for is never shown as-is.
  const readable = lang === "en" || /[\u0600-\u06FF]/.test(raw);
  if (raw && raw.length <= 140 && !technical && readable) return raw;
  return lang === "ar" ? "حدث خطأ ما. حاول مرة أخرى." : "Something went wrong. Please try again.";
}
