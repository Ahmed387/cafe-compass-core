import JsBarcode from "jsbarcode";
import QRCode from "qrcode";

import { formatMoney } from "./format";

function escape(value: string) {
  return value.replace(/[&<>"]/g, (c) =>
    c === "&" ? "&amp;" : c === "<" ? "&lt;" : c === ">" ? "&gt;" : "&quot;",
  );
}

/** Renders a scannable CODE128 barcode as a PNG data URL (browser only). */
export function barcodeDataUrl(value: string) {
  const canvas = document.createElement("canvas");
  JsBarcode(canvas, value, {
    format: "CODE128",
    width: 2,
    height: 70,
    displayValue: true,
    fontSize: 15,
    margin: 6,
  });
  return canvas.toDataURL("image/png");
}

export type CustomerCard = {
  companyName: string;
  name: string;
  code: string;
  barcode: string;
  /** Cashback wallet balance (money). */
  wallet: number;
  currency: string;
  lang: "en" | "ar";
  url: string;
  labels: { title: string; hint: string; wallet: string; id: string };
};

/** Prints a wallet-size customer card with the ID, cashback balance, barcode and QR link. */
export async function printCustomerCard(card: CustomerCard) {
  const bars = barcodeDataUrl(card.barcode);
  const qr = await QRCode.toDataURL(card.url, { margin: 1, width: 320 });
  const win = window.open("", "_blank", "width=520,height=680");
  if (!win) return false;
  win.document
    .write(`<!doctype html><html lang="${card.lang}" dir="${card.lang === "ar" ? "rtl" : "ltr"}"><head>
<meta charset="utf-8" /><title>${escape(card.code)}</title>
<style>
  @page { size: 90mm 55mm; margin: 3mm; }
  body { font-family: system-ui, sans-serif; color: #111; margin: 0; }
  .card { width: 84mm; box-sizing: border-box; border: 1px solid #111; border-radius: 3mm;
          padding: 3mm; display: grid; gap: 1.5mm; }
  .brand { font-size: 12pt; font-weight: 800; }
  .title { font-size: 8pt; opacity: .7; }
  .name { font-size: 11pt; font-weight: 700; }
  .row { display: flex; justify-content: space-between; font-size: 8pt; }
  .bars { text-align: center; }
  .bars img { width: 60mm; }
  .qr { position: absolute; }
  .foot { font-size: 7pt; opacity: .65; text-align: center; }
  .grid { display: flex; align-items: center; gap: 2mm; justify-content: space-between; }
  .grid img.q { width: 18mm; height: 18mm; }
</style></head><body>
<div class="card">
  <div class="brand">${escape(card.companyName)}</div>
  <div class="title">${escape(card.labels.title)}</div>
  <div class="grid">
    <div>
      <div class="name">${escape(card.name)}</div>
      <div class="row"><span>${escape(card.labels.id)}: ${escape(card.code)}</span></div>
      <div class="row"><span>${escape(card.labels.wallet)}: ${escape(
        formatMoney(card.wallet, card.currency, card.lang),
      )}</span></div>
    </div>
    <img class="q" src="${qr}" alt="" />
  </div>
  <div class="bars"><img src="${bars}" alt="" /></div>
  <div class="foot">${escape(card.labels.hint)}</div>
</div>
<script>window.onload = function () { window.print(); };</script>
</body></html>`);
  win.document.close();
  return true;
}

/** Marketing suggestion key for a product based on demand and margin. */
export function demandSuggestion(
  row: {
    qty: number;
    revenue: number;
    margin: number;
  },
  maxQty: number,
) {
  const marginPct = row.revenue > 0 ? (row.margin / row.revenue) * 100 : 0;
  if (row.qty === 0) return "ana.sugPromote";
  if (maxQty > 0 && row.qty / maxQty >= 0.6) return "ana.sugStar";
  if (marginPct < 20 && row.qty > 0) return "ana.sugPrice";
  if (maxQty > 0 && row.qty / maxQty <= 0.15)
    return marginPct < 25 ? "ana.sugRetire" : "ana.sugBundle";
  return "ana.sugBundle";
}
