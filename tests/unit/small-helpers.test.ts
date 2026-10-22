import { test } from "node:test";
import assert from "node:assert/strict";

import { normalizeTender } from "../../src/core/finance/formulas.ts";
import { cafeToday, validPayDate } from "../../src/lib/pay-date.ts";
import { customerLookupTerm } from "../../src/modules/operations/customer-lookup-term.ts";

test("customer lookup starts after 3 phone digits or 2 search characters", () => {
  assert.equal(customerLookupTerm("", "01"), "");
  assert.equal(customerLookupTerm("", "010"), "010");
  assert.equal(customerLookupTerm("", "+20 100-123"), "20100123");
  assert.equal(customerLookupTerm("Ah", "010"), "Ah");
  assert.equal(customerLookupTerm("a(b),%", ""), "ab");
});

test("pay date: today and past days only, real calendar days", () => {
  assert.equal(validPayDate("2026-10-20", "2026-10-21"), true);
  assert.equal(validPayDate("2026-10-21", "2026-10-21"), true);
  assert.equal(validPayDate("2026-10-22", "2026-10-21"), false);
  assert.equal(validPayDate("2026-02-30", "2026-10-21"), false);
  assert.equal(validPayDate("", "2026-10-21"), false);
});

test("cafe day follows Cairo and starts at 6 AM, not UTC midnight", () => {
  // 04:00 UTC on the 21st is 07:00 in Cairo (UTC+3): the 21st.
  assert.equal(cafeToday(new Date("2026-10-21T04:00:00Z")), "2026-10-21");
  // 23:30 UTC on the 20th is 02:30 on the 21st in Cairo: still the 20th's night.
  assert.equal(cafeToday(new Date("2026-10-20T23:30:00Z")), "2026-10-20");
  assert.equal(cafeToday(new Date("2026-10-20T20:00:00Z")), "2026-10-20");
});

test("tenders: cashback is customer credit, never cash (same as SQL tender_key)", () => {
  assert.equal(normalizeTender("cashback"), "points");
  assert.equal(normalizeTender("cash"), "cash");
  assert.equal(normalizeTender("instapay"), "instapay");
  assert.equal(normalizeTender("vodafone_cash"), "wallet");
  assert.equal(normalizeTender("partner_tab"), "partner_tab");
  assert.equal(normalizeTender(null), "cash");
});
