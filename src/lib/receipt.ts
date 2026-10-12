import { formatDateTime, formatMoney } from "./format";

export type ReceiptLine = {
  product_name: string;
  size_name?: string | null;
  quantity: number;
  unit_price?: number | string;
  line_total: number | string;
  status?: string;
  modifiers?: Array<{ name: string }>;
  notes?: string | null;
};

export type ReceiptData = {
  companyName: string;
  branchName?: string | null;
  orderNumber: string;
  createdAt: string;
  orderType: string;
  cashier?: string | null;
  /** Cashier's note written when the invoice was created; printed under the items. */
  notes?: string | null;
  lines: ReceiptLine[];
  subtotal: number | string;
  discount: number | string;
  total: number | string;
  refunded?: number;
  payments: Array<{ method_key: string; amount: number | string }>;
  customerName?: string | null;
  customerPhone?: string | null;
  /** Cashback paid from the customer's wallet on this bill. */
  cashbackUsed?: number | null;
  /** Cashback this bill added to the wallet. */
  cashbackEarned?: number | null;
  /** Wallet balance after this bill. */
  walletBalance?: number | null;
  /** Super-admin editable message printed at the bottom of both copies. */
  footerMessage?: string | null;
  change?: number | string | null;
  currency: string;
  lang: "en" | "ar";
  labels: Record<string, string>;
};

export type BaristaTicketData = {
  companyName: string;
  branchName?: string | null;
  orderNumber: string;
  createdAt: string;
  orderType: string;
  customerName?: string | null;
  notes?: string | null;
  lines: Array<{
    product_name: string;
    size_name?: string | null;
    quantity: number;
    modifiers?: Array<{ name: string }>;
    notes?: string | null;
    /** Set on bundle/combo lines so the barista sees the combo and its drinks. */
    bundle_title?: string | null;
    bundle_key?: string | null;
  }>;
  lang: "en" | "ar";
  labels: Record<string, string>;
};

function escape(value: string) {
  return value.replace(/[&<>"]/g, (c) =>
    c === "&" ? "&amp;" : c === "<" ? "&lt;" : c === ">" ? "&gt;" : "&quot;",
  );
}

/** Keeps the stored audit-safe number while showing its daily sequence cleanly. */
export function invoiceSequence(orderNumber: string | number) {
  const value = String(orderNumber).trim();
  const beforeDate = value.match(/(?:^|\D)0*(\d+)-\d{6}$/)?.[1];
  const suffix = value.match(/(?:^|-)0*(\d+)$/)?.[1];
  const sequence = beforeDate ?? suffix;
  return sequence ? String(Number(sequence)) : value || "1";
}

function formatReceiptDate(value: string, lang: "en" | "ar") {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  const locale = lang === "ar" ? "ar-EG" : "en-US";
  const parts = new Intl.DateTimeFormat(locale, {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: true,
    timeZone: "Africa/Cairo",
  }).formatToParts(date);
  const part = (type: Intl.DateTimeFormatPartTypes) =>
    parts.find((entry) => entry.type === type)?.value ?? "";
  return `${part("year")}/${part("month")}/${part("day")} - ${part("hour")}:${part("minute")} ${part("dayPeriod")}`;
}

function paymentLabel(key: string, lang: "en" | "ar") {
  const normalized = key.toLowerCase().replace(/[\s_-]+/g, "");
  // Checked before "cash": "cashback" contains "cash".
  if (normalized.includes("cashback") || normalized.includes("points") || normalized.includes("نقاط")) {
    return lang === "ar" ? "كاش باك من المحفظة" : "Cashback wallet";
  }
  if (normalized.includes("cash") || normalized.includes("كاش")) {
    return lang === "ar" ? "كاش (Cash)" : "Cash / كاش";
  }
  if (
    normalized.includes("instapay") ||
    normalized.includes("انستاباي") ||
    normalized.includes("إنستاباي")
  ) {
    return lang === "ar" ? "إنستاباي (InstaPay)" : "InstaPay / إنستاباي";
  }
  if (normalized.includes("wallet") || normalized.includes("محفظ")) {
    return lang === "ar" ? "محفظة إلكترونية (Wallet)" : "Wallet / محفظة إلكترونية";
  }
  if (
    normalized.includes("card") ||
    normalized.includes("visa") ||
    normalized.includes("فيزا") ||
    normalized.includes("بطاق")
  ) {
    return lang === "ar" ? "فيزا / بطاقة (Card)" : "Card / فيزا";
  }
  return escape(key);
}

/** Builds a thermal-printer friendly 80mm receipt document.
 *  The receipt is always printed in English, regardless of the app language. */
export function buildReceiptHtml(data: ReceiptData) {
  // Forced English layout: labels, dates, money and payment names never follow
  // the cashier's app language. (lang stays "en" even when the app is Arabic.)
  const lang: "en" = "en";
  const money = (v: number | string) => formatMoney(v, data.currency, lang);
  const number = invoiceSequence(data.orderNumber);
  const invoiceText = `Invoice <bdi dir="ltr">#${number}</bdi>`;
  const branch = data.branchName ?? "";
  const rows = data.lines
    .map((line) => {
      const voided = line.status === "voided";
      const mods = (line.modifiers ?? []).map((m) => `+${escape(m.name)}`).join(", ");
      // Effective unit price keeps Qty x Price = Line total even when add-ons are priced.
      const qty = Math.max(Number(line.quantity) || 1, 1);
      const unitPrice = Number(line.line_total) / qty;
      return `<tr class="item-row ${voided ? "voided" : ""}">
        <td class="item-name"><strong>${escape(line.product_name)}${line.size_name ? ` (${escape(line.size_name)})` : ""}</strong>${
          mods ? `<div class="item-detail">${mods}</div>` : ""
        }${line.notes ? `<div class="item-detail">${escape(line.notes)}</div>` : ""}${
          voided ? `<div class="item-detail">Voided</div>` : ""
        }</td>
        <td class="qty">${line.quantity}</td>
        <td class="money price">${money(unitPrice)}</td>
        <td class="money line"><strong>${money(line.line_total)}</strong></td>
      </tr>`;
    })
    .join("");

  const payments = data.payments
    .map((p) => {
      return `<div class="row"><strong>${paymentLabel(p.method_key, lang)}</strong><span>${money(p.amount)}</span></div>`;
    })
    .join("");

  const discount = Number(data.discount);
  const change = Number(data.change ?? 0);
  const cashbackEarned = Number(data.cashbackEarned ?? 0);
  const walletBalance = data.walletBalance === null || data.walletBalance === undefined ? null : Number(data.walletBalance);
  const customer = [data.customerName, data.customerPhone]
    .filter(Boolean)
    .map(String)
    .map(escape)
    .join(" · ");
  const foot =
    data.footerMessage?.trim() || "Thank you for visiting 20s Coffee! See you soon.";

  const receiptCopy = (copyLabel: string) => `<main class="receipt-container receipt-copy">
  <div class="copy-label">${copyLabel}</div>
  <header>
    <div class="brand">${escape(data.companyName)}</div>
    <div class="branch">${escape(branch)}</div>
    <div class="double-divider"></div>
    <h1>${invoiceText}</h1>
    <div class="meta-grid">
      <div class="meta-item"><strong>Order type</strong><div class="meta-value">${escape(data.orderType)}</div></div>
      <div class="meta-item"><strong>Date &amp; time</strong><div class="meta-value">${escape(formatReceiptDate(data.createdAt, lang))}</div></div>
      <div class="meta-item"><strong>Cashier</strong><div class="meta-value">${escape(data.cashier || "—")}</div></div>
    </div>
    <div class="double-divider"></div>
  </header>
  <table aria-label="Receipt items">
    <thead><tr>
      <th class="item-name">Item</th>
      <th class="qty">Qty</th>
      <th class="money price">Price</th>
      <th class="money line">Total</th>
    </tr></thead>
    <tbody>${rows}</tbody>
  </table>
  ${data.notes?.trim() ? `<section class="order-note"><strong>Note</strong><div dir="auto">${escape(data.notes.trim())}</div></section>` : ""}
  <section class="summary">
    <div class="row"><span>Subtotal</span><span>${money(data.subtotal)}</span></div>
    ${discount > 0 ? `<div class="row"><span>Discount</span><span>-${money(discount)}</span></div>` : ""}
    <div class="row grand-total"><span>Total Due</span><span>${money(data.total)}</span></div>
    ${data.refunded ? `<div class="row"><span>Refunded</span><span>-${money(data.refunded)}</span></div>` : ""}
  </section>
  <section class="payment-section">
    <div class="section-title">Payment</div>
    ${payments || `<div class="row"><span>—</span><span>${money(data.total)}</span></div>`}
    ${change > 0 ? `<div class="row"><strong>Change Due</strong><span>${money(change)}</span></div>` : ""}
  </section>
  ${
    customer
      ? `<section class="loyalty-box">
          <div class="row"><strong>Customer</strong><span>${customer}</span></div>
          ${cashbackEarned > 0 ? `<div class="row"><span>Cashback earned</span><strong>+${money(cashbackEarned)}</strong></div>` : ""}
          ${walletBalance !== null ? `<div class="row"><span>Wallet balance</span><strong>${money(walletBalance)}</strong></div>` : ""}
        </section>`
      : ""
  }
  <div class="foot">${escape(foot)}</div>
</main>`;

  return `<!doctype html><html lang="en" dir="ltr"><head>
<meta charset="utf-8" /><title>${escape(data.orderNumber)}</title>
<style>
  * { box-sizing: border-box; }
  html, body { background: #fff; color: #000; }
  body { margin: 0; padding: 4mm 2mm 8mm; font-family: "Cairo", "Tajawal", system-ui, sans-serif; }
  .receipt-container { width: 76mm; max-width: 76mm; margin: 0 auto; color: #000; font-size: 12px; line-height: 1.4; }
  .copy-label { margin-bottom: 5px; padding: 3px 4px; border: 1px solid #000; text-align: center; font-size: 11px; font-weight: 800; }
  .brand { text-align: center; font-size: 19px; font-weight: 900; }
  h1 { margin: 2px 0 6px; text-align: center; font-size: 18px; font-weight: 900; }
  .branch { margin: 1px 0 6px; text-align: center; font-size: 11px; font-weight: 600; }
  .double-divider { height: 4px; margin: 7px 0; border-top: 2px dashed #000; border-bottom: 1px dashed #000; }
  .section-title { margin: 7px 0 3px; font-size: 12px; font-weight: 800; }
  .meta-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 4px 8px; margin-bottom: 3px; }
  .meta-item { min-width: 0; }
  .meta-item strong { display: block; font-size: 10px; }
  .meta-value { overflow-wrap: anywhere; }
  table { width: 100%; border-collapse: collapse; table-layout: fixed; }
  th { padding: 4px 1px; border-bottom: 2px solid #000; font-size: 11px; font-weight: 800; }
  td { vertical-align: top; padding: 5px 1px; font-size: 11px; }
  .item-row { border-bottom: 1px dashed #777; break-inside: avoid; page-break-inside: avoid; }
  .item-name { width: auto; text-align: left; overflow-wrap: anywhere; }
  .qty { width: 40px; text-align: center; font-weight: 700; }
  .money { text-align: right; direction: ltr; white-space: nowrap; font-family: ui-monospace, "Courier New", monospace; font-size: 10px; }
  .money.price { width: 64px; }
  .money.line { width: 72px; }
  .order-note { margin: 6px 0; padding: 4px 6px; border: 1px dashed #000; font-size: 11px; white-space: pre-wrap; }
  .item-detail { margin-top: 2px; padding-inline-start: 3mm; font-size: 9px; font-weight: 400; }
  .voided { text-decoration: line-through; opacity: .65; }
  .summary, .payment-section, .loyalty-box { break-inside: avoid; page-break-inside: avoid; }
  .summary { margin-top: 7px; }
  .row { display: flex; justify-content: space-between; align-items: baseline; gap: 8px; padding: 2px 0; }
  .row span:last-child { direction: ltr; white-space: nowrap; font-family: ui-monospace, "Courier New", monospace; }
  .grand-total { margin: 4px 0; padding: 5px 0; border-top: 2px solid #000; border-bottom: 2px solid #000; font-size: 16px; font-weight: 800; }
  .payment-section { margin-top: 8px; border-top: 1px dashed #000; padding-top: 5px; }
  .loyalty-box { margin-top: 9px; padding: 6px; border: 1px dashed #000; }
  .loyalty-box .row { font-size: 11px; }
  .foot { margin-top: 12px; padding-top: 7px; border-top: 2px dashed #000; text-align: center; font-size: 11px; font-weight: 700; }
  .cut-divider { width: 76mm; margin: 9mm auto; border-top: 2px dashed #000; text-align: center; font-size: 10px; font-weight: 700; }
  .cut-divider span { position: relative; top: -8px; padding: 0 5px; background: #fff; }
  @media print {
    @page { size: 80mm auto; margin: 0; }
    html, body { width: 80mm; min-width: 80mm; margin: 0; padding: 0; color: #000; background: #fff; }
    body { padding: 2mm; }
    .no-print { display: none !important; }
    .receipt-container { width: 76mm !important; max-width: 76mm !important; margin: 0 auto !important; font-size: 12px; line-height: 1.35; }
    tr, td, th, .summary, .payment-section, .loyalty-box { break-inside: avoid !important; page-break-inside: avoid !important; }
    .receipt-copy { break-inside: avoid; page-break-inside: avoid; }
    .cut-divider { break-after: page; page-break-after: always; }
  }
</style></head><body>
${receiptCopy("Customer copy")}
<div class="cut-divider"><span>✂ Cut here</span></div>
${receiptCopy("Cafe copy — Order preparation")}
</body></html>`;
}

/** Prints HTML silently through a hidden iframe, without opening any window or tab. */
function printHtmlSilently(html: string) {
  if (typeof document === "undefined") return false;
  const frame = document.createElement("iframe");
  frame.setAttribute("aria-hidden", "true");
  frame.style.position = "fixed";
  frame.style.right = "0";
  frame.style.bottom = "0";
  frame.style.width = "0";
  frame.style.height = "0";
  frame.style.border = "0";
  frame.style.opacity = "0";
  frame.style.pointerEvents = "none";
  document.body.appendChild(frame);

  const cleanup = () => {
    window.setTimeout(() => frame.remove(), 1000);
  };

  frame.onload = () => {
    const win = frame.contentWindow;
    if (!win) {
      cleanup();
      return;
    }
    try {
      win.focus();
      win.print();
    } finally {
      cleanup();
    }
  };

  const doc = frame.contentWindow?.document;
  if (!doc) {
    frame.remove();
    return false;
  }
  doc.open();
  doc.write(html);
  doc.close();
  return true;
}

/** Prints the receipt directly (browser only, no extra window). */
export function printReceipt(data: ReceiptData) {
  return printHtmlSilently(buildReceiptHtml(data));
}

/** Builds a barista-only ticket (no prices, just items, modifiers and notes). */
export function buildBaristaTicketHtml(data: BaristaTicketData) {
  const lineHtml = (line: BaristaTicketData["lines"][number]) => `
      <div class="item">
        <div class="qty-name">
          <span class="qty">${line.quantity}×</span>
          <span class="name">${escape(line.product_name)}${line.size_name ? ` (${escape(line.size_name)})` : ""}</span>
        </div>
        ${(line.modifiers ?? []).length > 0 ? `<div class="mods">+ ${(line.modifiers ?? []).map((m) => escape(m.name)).join(", ")}</div>` : ""}
        ${line.notes ? `<div class="note">${escape(line.notes)}</div>` : ""}
      </div>`;

  // Bundle lines are printed under their combo title so nothing is missed.
  const groups: Array<{ title: string | null; lines: BaristaTicketData["lines"] }> = [];
  for (const line of data.lines) {
    const key = line.bundle_key ?? null;
    const last = groups[groups.length - 1];
    if (key && last && last.title && last.lines[0]?.bundle_key === key) {
      last.lines.push(line);
      continue;
    }
    groups.push({ title: key ? (line.bundle_title ?? null) : null, lines: [line] });
  }

  const rows = groups
    .map((group) =>
      group.title
        ? `<div class="bundle"><div class="bundle-title">★ ${escape(group.title)}</div>${group.lines
            .map(lineHtml)
            .join("")}</div>`
        : group.lines.map(lineHtml).join(""),
    )
    .join("");


  return `<!doctype html><html lang="${data.lang}" dir="${data.lang === "ar" ? "rtl" : "ltr"}"><head>
<meta charset="utf-8" /><title>${escape(data.orderNumber)}</title>
<style>
  @page { size: 80mm auto; margin: 4mm; }
  body { font-family: ui-monospace, "Courier New", monospace; width: 72mm; margin: 0 auto; color: #000; font-size: 14px; }
  h1 { font-size: 18px; text-align: center; margin: 0; }
  .sub { text-align: center; font-size: 12px; margin-bottom: 8px; opacity: .8; }
  .type { text-align: center; font-size: 13px; font-weight: 700; border: 2px solid #000; padding: 4px; margin: 6px 0; }
  .item { border-bottom: 1px dashed #000; padding: 8px 0; }
  .bundle { border: 2px solid #000; padding: 4px 6px; margin: 6px 0; }
  .bundle-title { font-size: 15px; font-weight: 800; text-align: center; padding-bottom: 4px; }
  .qty-name { display: flex; align-items: baseline; gap: 8px; }
  .qty { font-size: 20px; font-weight: 800; }
  .name { font-size: 16px; font-weight: 700; }
  .mods { font-size: 12px; margin-top: 4px; opacity: .8; }
  .note { font-size: 12px; margin-top: 4px; color: #c00; font-weight: 700; }
  .foot { text-align: center; margin-top: 10px; font-size: 11px; }
</style></head><body>
<h1>${escape(data.companyName)}</h1>
<div class="sub">${escape(data.branchName ?? "")}</div>
<div class="type">${escape(data.orderType)} · ${escape(data.labels["order"] ?? "")} ${escape(data.orderNumber)}</div>
<div class="sub">${escape(formatDateTime(data.createdAt, data.lang))}</div>
${data.customerName ? `<div class="sub">${escape(data.labels["customer"] ?? "")}: ${escape(data.customerName)}</div>` : ""}
${data.notes ? `<div class="note">${escape(data.notes)}</div>` : ""}
${rows}
<div class="foot">${escape(data.labels["kitchenHint"] ?? "")}</div>
</body></html>`;
}

/** Prints the barista ticket directly (browser only, no extra window). */
export function printBaristaTicket(data: BaristaTicketData) {
  return printHtmlSilently(buildBaristaTicketHtml(data));
}
