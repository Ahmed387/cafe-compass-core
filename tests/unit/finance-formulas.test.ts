import { test } from "node:test";
import assert from "node:assert/strict";

import {
  addDays,
  businessDay,
  businessDayStartIso,
  daysBetween,
  monthBounds,
  shiftBusinessDay,
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

test("calendar day follows Cairo time, not UTC", () => {
  // 21:30 UTC on Oct 21 is 00:30 on Oct 22 in Cairo (UTC+3 in summer time).
  assert.equal(businessDay(new Date("2026-10-21T21:30:00Z")), "2026-10-22");
  // 20:59 UTC is still 23:59 on Oct 21 in Cairo.
  assert.equal(businessDay(new Date("2026-10-21T20:59:00Z")), "2026-10-21");
});

test("a Cairo day starts at midnight (21:00 UTC in summer time, 22:00 in winter)", () => {
  assert.equal(businessDayStartIso("2026-10-22"), "2026-10-21T21:00:00.000Z");
  assert.equal(businessDayStartIso("2026-12-01"), "2026-11-30T22:00:00.000Z");
});

test("a shift belongs to the day it opened, however late it closes", () => {
  // Opened 22/10 at 18:00 Cairo.
  assert.equal(shiftBusinessDay("2026-10-22T15:00:00Z"), "2026-10-22");
  // Opened 23/10 at 00:30 Cairo (just after midnight): that is the 23rd.
  assert.equal(shiftBusinessDay("2026-10-22T21:30:00Z"), "2026-10-23");
  // Winter time change (29/10): opened 28/10 at 18:00 Cairo (UTC+3) is the 28th.
  assert.equal(shiftBusinessDay(new Date("2026-10-28T15:00:00Z")), "2026-10-28");
  // After the change Cairo is UTC+2: 22:30 UTC on 29/10 is 00:30 on 30/10.
  assert.equal(shiftBusinessDay("2026-10-29T22:30:00Z"), "2026-10-30");
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
