import QRCode from "qrcode";

import { formatMoney } from "./format";

export type LabelItem = {
  title: string;
  subtitle?: string | null;
  price?: number | string | null;
  code?: string | null;
  qrValue: string;
};

function escape(value: string) {
  return value.replace(/[&<>"]/g, (c) =>
    c === "&" ? "&amp;" : c === "<" ? "&lt;" : c === ">" ? "&gt;" : "&quot;",
  );
}

function openPrintWindow(html: string, width = 720, height = 900) {
  const win = window.open("", "_blank", `width=${width},height=${height}`);
  if (!win) return false;
  win.document.write(html);
  win.document.close();
  return true;
}

/** Prints a sheet of 40x30mm product labels, each with a scannable QR code. */
export async function printLabelSheet(opts: {
  items: LabelItem[];
  copies?: number;
  currency: string;
  lang: "en" | "ar";
  heading: string;
}) {
  const copies = Math.max(1, opts.copies ?? 1);
  const cells: string[] = [];
  for (const item of opts.items) {
    const qr = await QRCode.toDataURL(item.qrValue, { margin: 0, width: 220 });
    for (let i = 0; i < copies; i += 1) {
      cells.push(`<div class="label">
        <img src="${qr}" alt="" />
        <div class="text">
          <div class="title">${escape(item.title)}</div>
          ${item.subtitle ? `<div class="sub">${escape(item.subtitle)}</div>` : ""}
          ${item.price != null ? `<div class="price">${escape(formatMoney(item.price, opts.currency, opts.lang))}</div>` : ""}
          ${item.code ? `<div class="code">${escape(item.code)}</div>` : ""}
        </div>
      </div>`);
    }
  }

  return openPrintWindow(`<!doctype html><html lang="${opts.lang}" dir="${opts.lang === "ar" ? "rtl" : "ltr"}"><head>
<meta charset="utf-8" /><title>${escape(opts.heading)}</title>
<style>
  @page { size: A4; margin: 6mm; }
  body { font-family: system-ui, sans-serif; color: #000; margin: 0; }
  .sheet { display: grid; grid-template-columns: repeat(4, 46mm); gap: 3mm; }
  .label { display: flex; gap: 2mm; align-items: center; width: 46mm; height: 26mm;
           border: 1px dashed #999; padding: 1.5mm; box-sizing: border-box; overflow: hidden; }
  .label img { width: 20mm; height: 20mm; }
  .text { min-width: 0; }
  .title { font-size: 8pt; font-weight: 700; line-height: 1.15; }
  .sub, .code { font-size: 6pt; opacity: .75; }
  .price { font-size: 8pt; font-weight: 700; }
</style></head><body>
<div class="sheet">${cells.join("")}</div>
<script>window.onload = function () { window.print(); };</script>
</body></html>`);
}

/** Prints a table-tent poster with the QR code that opens the public menu. */
export async function printMenuPoster(opts: {
  url: string;
  companyName: string;
  branchName: string;
  headline: string;
  hint: string;
  lang: "en" | "ar";
}) {
  const qr = await QRCode.toDataURL(opts.url, { margin: 1, width: 900 });
  return openPrintWindow(`<!doctype html><html lang="${opts.lang}" dir="${opts.lang === "ar" ? "rtl" : "ltr"}"><head>
<meta charset="utf-8" /><title>${escape(opts.companyName)}</title>
<style>
  @page { size: A4; margin: 12mm; }
  body { font-family: system-ui, sans-serif; text-align: center; color: #111; }
  h1 { font-size: 34pt; margin: 8mm 0 0; }
  h2 { font-size: 16pt; font-weight: 500; margin: 2mm 0 8mm; opacity: .7; }
  img { width: 110mm; height: 110mm; }
  .headline { font-size: 20pt; font-weight: 700; margin-top: 8mm; }
  .hint { font-size: 12pt; opacity: .7; margin-top: 3mm; }
  .url { font-size: 9pt; opacity: .55; margin-top: 6mm; word-break: break-all; }
</style></head><body>
<h1>${escape(opts.companyName)}</h1>
<h2>${escape(opts.branchName)}</h2>
<img src="${qr}" alt="" />
<div class="headline">${escape(opts.headline)}</div>
<div class="hint">${escape(opts.hint)}</div>
<div class="url">${escape(opts.url)}</div>
<script>window.onload = function () { window.print(); };</script>
</body></html>`);
}

/** Returns a QR code data URL for on-screen preview. */
export function qrDataUrl(value: string, width = 320) {
  return QRCode.toDataURL(value, { margin: 1, width });
}
