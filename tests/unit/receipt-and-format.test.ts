import { test } from "node:test";
import assert from "node:assert/strict";

import { buildCsv } from "../../src/lib/csv.ts";
import { friendlyError } from "../../src/lib/format.ts";
import { buildReceiptHtml, invoiceSequence } from "../../src/lib/receipt.ts";

test("invoice number shows the daily sequence", () => {
  assert.equal(invoiceSequence("0007-221026"), "7");
  assert.equal(invoiceSequence("INV-0012"), "12");
  assert.equal(invoiceSequence(""), "1");
});

const receipt = (over: Partial<Parameters<typeof buildReceiptHtml>[0]> = {}) =>
  buildReceiptHtml({
    companyName: "20s",
    orderNumber: "0003-221026",
    createdAt: "2026-10-22T18:00:00Z",
    orderType: "dine_in",
    lines: [{ product_name: "Latte", quantity: 2, line_total: 130 }],
    subtotal: 130,
    discount: 0,
    total: 130,
    payments: [
      { method_key: "cash", amount: 100 },
      { method_key: "instapay", amount: 30 },
    ],
    currency: "EGP",
    lang: "ar",
    labels: {},
    ...over,
  });

test("split payments print one line per method", () => {
  const html = receipt();
  assert.match(html, /Cash/);
  assert.match(html, /InstaPay/);
});

test("customer text on the receipt cannot inject HTML", () => {
  const html = receipt({ customerName: "<script>alert(1)</script>", notes: "<img src=x onerror=1>" });
  assert.equal(html.includes("<script>alert(1)</script>"), false);
  assert.equal(html.includes("<img src=x"), false);
});

test("CSV export quotes commas, quotes and new lines", () => {
  const csv = buildCsv([{ a: 'He said "hi", ok', b: 5 }], [
    { header: "Name", value: (r) => r.a },
    { header: "Qty", value: (r) => r.b },
  ]);
  assert.equal(csv, 'Name,Qty\r\n"He said ""hi"", ok",5');
});

test("database errors become plain Arabic messages", () => {
  assert.equal(friendlyError({ message: "permission denied for table orders" }, "ar"), "ليست لديك صلاحية لتنفيذ هذا الإجراء.");
  assert.equal(friendlyError({ message: "Not enough stock for Milk · 2 L" }, "ar"), "الكمية المتاحة غير كافية من: Milk");
  assert.equal(friendlyError({ message: 'column "x" does not exist' }, "ar"), "حدث خطأ ما. حاول مرة أخرى.");
});
