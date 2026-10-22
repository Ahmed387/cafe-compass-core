import { test } from "node:test";
import assert from "node:assert/strict";

import {
  addDays,
  businessDay,
  businessDayStartIso,
  daysBetween,
  monthBounds,
} from "../../src/core/finance/business-dates.ts";
import { netInvoiceTotal, normalizeTender, saleRefundTotal, sum } from "../../src/core/finance/formulas.ts";

test("every payment method lands in the right drawer bucket", () => {
  assert.equal(normalizeTender("cash"), "cash");
  assert.equal(normalizeTender(null), "cash");
  assert.equal(normalizeTender("instapay"), "instapay");
  assert.equal(normalizeTender("bank_transfer"), "instapay");
  assert.equal(normalizeTender("vodafone_cash"), "wallet");
  assert.equal(normalizeTender("visa"), "visa");
  assert.equal(normalizeTender("card"), "visa");
  assert.equal(normalizeTender("partner_tab"), "partner_tab");
  // Customer cashback is not money in the drawer.
  assert.equal(normalizeTender("cashback"), "points");
  assert.equal(normalizeTender("points"), "points");
});

test("invoice net value: cancelled is 0, manual refunds come off, removed-line refunds don't", () => {
  assert.equal(netInvoiceTotal({ total: 200, status: "cancelled" }, []), 0);
  assert.equal(netInvoiceTotal({ total: 200, status: "paid" }, [{ amount: 50 }]), 150);
  assert.equal(netInvoiceTotal({ total: 200 }, [{ amount: 50, origin: "void" }]), 200);
  assert.equal(netInvoiceTotal({ total: 200 }, [{ amount: 50, status: "reversed" }]), 200);
  // A refund bigger than the bill never makes it negative.
  assert.equal(netInvoiceTotal({ total: 100 }, [{ amount: 150 }]), 0);
  assert.equal(saleRefundTotal(null), 0);
});

test("money sums round to piasters and ignore junk", () => {
  assert.equal(sum([0.1, 0.2]), 0.3);
  assert.equal(sum([10, Number.NaN, 5]), 15);
});

test("business day follows Cairo time and starts at 6 AM", () => {
  // 03:30 UTC on Oct 22 is 06:30 in Cairo (UTC+3 in summer time): a new day.
  assert.equal(businessDay(new Date("2026-10-22T03:30:00Z")), "2026-10-22");
  // 23:30 UTC on Oct 21 is 02:30 on Oct 22 in Cairo: still the night of Oct 21.
  assert.equal(businessDay(new Date("2026-10-21T23:30:00Z")), "2026-10-21");
  // 05:59 Cairo still belongs to the day before.
  assert.equal(businessDay(new Date("2026-10-22T02:59:00Z")), "2026-10-21");
  assert.equal(businessDay(new Date("2026-10-21T20:00:00Z")), "2026-10-21");
});

test("business day starts at 06:00 Cairo (03:00 UTC in summer time, 04:00 in winter)", () => {
  assert.equal(businessDayStartIso("2026-10-22"), "2026-10-22T03:00:00.000Z");
  assert.equal(businessDayStartIso("2026-12-01"), "2026-12-01T04:00:00.000Z");
});

test("date helpers", () => {
  assert.deepEqual(monthBounds("2026-02"), { start: "2026-02-01", end: "2026-02-28" });
  assert.equal(addDays("2026-10-31", 1), "2026-11-01");
  // Both ends count: Oct 1 → Oct 21 is 21 days.
  assert.equal(daysBetween("2026-10-01", "2026-10-21"), 21);
});

test("a refund given back to the cashback wallet still lowers the invoice", () => {
  // 100 bill: 25 from the wallet + 75 cash, refunded in full.
  assert.equal(saleRefundTotal([{ amount: 75, wallet_amount: 25 }]), 100);
  assert.equal(netInvoiceTotal({ total: 100, status: "refunded" }, [{ amount: 75, wallet_amount: 25 }]), 0);
  // 600 bill whose 25 reward was already spent: 575 back, the café keeps 25.
  assert.equal(netInvoiceTotal({ total: 600, status: "refunded" }, [{ amount: 575, wallet_amount: 0 }]), 25);
});
