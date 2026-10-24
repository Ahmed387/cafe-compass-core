// Which month a salary line counts in for profit. Empty pnl_month = its own
// payroll period; a picked month moves its whole cost there (public._range_pnl).

/** YYYY-MM the salary counts in now. */
export function profitMonthOf(periodStart: string, pnlMonth: string | null | undefined): string {
  return (pnlMonth || periodStart).slice(0, 7);
}

/** Months to offer: from `before` months before the period to `after` months after it. */
export function profitMonthOptions(periodStart: string, before = 2, after = 2): string[] {
  const [y, m] = periodStart.slice(0, 7).split("-").map(Number);
  const out: string[] = [];
  for (let i = -before; i <= after; i += 1) {
    const d = new Date(Date.UTC(y!, m! - 1 + i, 1));
    out.push(d.toISOString().slice(0, 7));
  }
  return out;
}

/** First day of a YYYY-MM month, the value the database stores. */
export function monthFirstDay(month: string): string {
  return `${month.slice(0, 7)}-01`;
}

/** "October 2026" / "أكتوبر ٢٠٢٦" for a YYYY-MM month. */
export function monthLabel(month: string, lang: "ar" | "en" = "ar"): string {
  const [y, m] = month.slice(0, 7).split("-").map(Number);
  return new Intl.DateTimeFormat(lang === "ar" ? "ar-EG" : "en-GB", {
    month: "long",
    year: "numeric",
    timeZone: "UTC",
  }).format(new Date(Date.UTC(y!, m! - 1, 1)));
}
