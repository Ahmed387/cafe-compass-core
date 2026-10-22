import { formatMoney } from "./format";

function escape(value: string) {
  return value.replace(/[&<>"]/g, (c) =>
    c === "&" ? "&amp;" : c === "<" ? "&lt;" : c === ">" ? "&gt;" : "&quot;",
  );
}

export type ShiftClosePrintData = {
  lang: "ar" | "en";
  currency: string;
  branchName?: string | null;
  cashierName?: string | null;
  openedAt?: string | null;
  tenders: Array<{ label: string; amount: number; count: number }>;
  refunds?: { total: number; cash: number; waste?: number | undefined } | null;
  cash: {
    opening: number;
    cashIn: number;
    cashRefunds: number;
    drawerExpenses: number;
    salesTotal: number;
    ordersCount: number;
    expected: number;
  };
  closingCash: number;
  retainedFloat: number;
  variance: number;
  shortage?: { modeLabel: string; detail?: string | null } | null;
  notes?: string | null;
};

/** Opens a clean, fully-expanded print document that mirrors the close-shift screen exactly. */
export function printShiftCloseReport(data: ShiftClosePrintData) {
  const ar = data.lang === "ar";
  const money = (v: number) => escape(formatMoney(v, data.currency, data.lang));
  const L = (arV: string, enV: string) => (ar ? arV : enV);

  const row = (label: string, value: string, cls = "") =>
    `<div class="row ${cls}"><span>${escape(label)}</span><span class="val">${value}</span></div>`;

  const tenderRows = data.tenders
    .map((t) => row(t.label, `${money(t.amount)} <small>(${t.count} ${L("عملية", "txns")})</small>`))
    .join("");

  const refundSection = data.refunds
    ? `<section><h2>${L("مرتجعات وهالك الوردية", "Refunds & waste")}</h2>
      ${row(L("إجمالي المرتجعات", "Refunded total"), money(data.refunds.total))}
      ${row(L("مرتجعات نقدية", "Cash refunds"), money(data.refunds.cash))}
      ${data.refunds.waste == null ? "" : row(L("الهالك", "Waste"), money(data.refunds.waste))}
    </section>`
    : "";

  const shortageSection = data.shortage
    ? `<section class="warn"><h2>${L("تحميل العجز", "Shortage attribution")}</h2>
      ${row(L("طريقة التحميل", "Attribution"), escape(data.shortage.modeLabel))}
      ${data.shortage.detail ? row(L("التفاصيل", "Detail"), escape(data.shortage.detail)) : ""}
    </section>`
    : "";

  const html = `<!doctype html><html lang="${data.lang}" dir="${ar ? "rtl" : "ltr"}"><head>
<meta charset="utf-8" /><title>${escape(L("تقرير إغلاق الوردية", "Shift close report"))}</title>
<style>
  @page { size: A4; margin: 12mm; }
  * { box-sizing: border-box; }
  body { font-family: "Cairo", "Segoe UI", system-ui, sans-serif; color: #111; margin: 0; font-size: 11pt; }
  header { text-align: center; border-bottom: 2px solid #111; padding-bottom: 4mm; margin-bottom: 5mm; }
  header h1 { font-size: 16pt; margin: 0 0 1mm; }
  header p { margin: 0; font-size: 9pt; color: #444; }
  section { border: 1px solid #ccc; border-radius: 2mm; padding: 3mm 4mm; margin-bottom: 4mm; page-break-inside: avoid; }
  section.warn { border-color: #b91c1c; }
  h2 { font-size: 11pt; margin: 0 0 2mm; border-bottom: 1px dashed #bbb; padding-bottom: 1.5mm; }
  .row { display: flex; justify-content: space-between; gap: 4mm; padding: 1.2mm 0; }
  .row .val { font-weight: 700; white-space: nowrap; }
  .row small { font-weight: 400; color: #555; }
  .row.total { border-top: 1.5px solid #111; margin-top: 1.5mm; padding-top: 2mm; font-size: 12pt; font-weight: 700; }
  .row.good .val { color: #15803d; }
  .row.bad .val { color: #b91c1c; }
  .notes { white-space: pre-wrap; }
  footer { text-align: center; font-size: 8pt; color: #666; margin-top: 6mm; }
</style></head><body>
<header>
  <h1>${escape(L("تقرير إغلاق الوردية", "Shift Close Report"))}</h1>
  <p>${[data.branchName, data.cashierName, data.openedAt ? new Date(data.openedAt).toLocaleString(ar ? "ar-EG" : "en-GB") : null]
    .filter(Boolean)
    .map((v) => escape(String(v)))
    .join(" · ")}</p>
</header>
<section>
  <h2>${L("توزيع الإيرادات حسب طريقة الدفع", "Revenue by payment method")}</h2>
  ${tenderRows}
</section>
${refundSection}
<section>
  <h2>${L("مطابقة درج النقدية", "Cash drawer reconciliation")}</h2>
  ${row(L("النقدية الافتتاحية", "Opening cash"), money(data.cash.opening))}
  ${row(L("مبيعات نقدية", "Cash sales"), money(data.cash.cashIn))}
  ${row(L("مرتجعات نقدية", "Cash refunds"), `- ${money(data.cash.cashRefunds)}`)}
  ${data.cash.drawerExpenses > 0 ? row(L("مصروفات من الدرج", "Drawer expenses"), `- ${money(data.cash.drawerExpenses)}`) : ""}
  ${row(L("مبيعات الوردية", "Shift sales"), `${money(data.cash.salesTotal)} <small>(${data.cash.ordersCount} ${L("طلب", "orders")})</small>`)}
  ${row(L("المتوقع في الدرج", "Expected in drawer"), money(data.cash.expected), "total")}
</section>
<section>
  <h2>${L("العد الفعلي", "Actual count")}</h2>
  ${row(L("النقدية الختامية", "Closing cash"), money(data.closingCash))}
  ${row(L("الفكة المتبقية للوردية القادمة", "Retained float"), money(data.retainedFloat))}
  ${row(L("المبلغ المورد للخزينة", "Cash drop to safe"), money(Math.max(0, data.closingCash - data.retainedFloat)))}
  ${row(L("الفرق", "Variance"), money(data.variance), `total ${data.variance < 0 ? "bad" : "good"}`)}
</section>
${shortageSection}
${data.notes ? `<section><h2>${L("ملاحظات", "Notes")}</h2><p class="notes">${escape(data.notes)}</p></section>` : ""}
<footer>${escape(L("طُبع من نظام إدارة المقهى", "Printed from the cafe management system"))} · ${new Date().toLocaleString(ar ? "ar-EG" : "en-GB")}</footer>
<script>window.onload = function () { window.print(); };</script>
</body></html>`;

  const win = window.open("", "_blank", "width=800,height=1000");
  if (!win) return false;
  win.document.write(html);
  win.document.close();
  return true;
}
