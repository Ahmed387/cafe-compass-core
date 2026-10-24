import { test } from "node:test";
import assert from "node:assert/strict";

import { isCancellation, splitRefundStats } from "../../src/core/finance/cancellations.ts";
import { settlementPreview } from "../../src/core/finance/partner-tabs.ts";
import {
  monthFirstDay,
  monthLabel,
  profitMonthOf,
  profitMonthOptions,
} from "../../src/core/finance/salary-month.ts";
import { businessTime, shiftCloseLabel } from "../../src/core/finance/business-dates.ts";
import { orderTenderNet } from "../../src/core/finance/formulas.ts";

// --- Cancelled items are not refunds -------------------------------------

test("a cancelled item is counted apart from refunds", () => {
  const stats = splitRefundStats([
    { amount: 85, method_key: "cash", is_cancellation: true },
    { amount: 40, method_key: "cash", is_cancellation: false },
    { amount: "25.5", method_key: "instapay" },
  ]);
  assert.deepEqual(stats, {
    count: 2,
    total: 65.5,
    cash: 40,
    waste: 0,
    cancelCount: 1,
    cancelTotal: 85,
  });
});

test("old rows without the flag stay refunds", () => {
  assert.equal(isCancellation({}), false);
  assert.equal(isCancellation({ is_cancellation: null }), false);
  assert.equal(isCancellation({ is_cancellation: true }), true);
  const stats = splitRefundStats([{ amount: 30 }]);
  assert.equal(stats.count, 1);
  assert.equal(stats.cash, 30, "no method means cash, as before");
});

test("waste is cost whether the item was refunded or cancelled", () => {
  const stats = splitRefundStats([
    {
      amount: 85,
      is_cancellation: true,
      items_payload: [{ disposition: "waste", quantity: 1, unit_cost: 22 }],
    },
    {
      amount: 50,
      items_payload: [
        { disposition: "waste", quantity: 2, unit_cost: "7.25" },
        { disposition: "restock", quantity: 1, unit_cost: 9 },
      ],
    },
  ]);
  assert.equal(stats.waste, 36.5);
  assert.equal(stats.total, 50);
  assert.equal(stats.cancelTotal, 85);
});

test("an empty shift has nothing to show", () => {
  assert.deepEqual(splitRefundStats([]), {
    count: 0,
    total: 0,
    cash: 0,
    waste: 0,
    cancelCount: 0,
    cancelTotal: 0,
  });
});

// --- Settling a partner's tab --------------------------------------------

test("a partial cash payment fills the treasury and leaves the rest for the payout", () => {
  const pv = settlementPreview({ open: 300, balance: 1000, amount: 200, mode: "payment" });
  assert.equal(pv.ok, true);
  assert.equal(pv.openAfter, 100);
  assert.equal(pv.treasuryIn, 200);
  assert.equal(pv.balanceAfter, 1000, "paying cash leaves the balance alone");
  assert.equal(pv.nextPayoutDeducts, 100);
  assert.equal(pv.balanceGoesNegative, false);
});

test("deducting from the balance does not touch the treasury", () => {
  const pv = settlementPreview({ open: 300, balance: 1000, amount: 300, mode: "deduct" });
  assert.equal(pv.treasuryIn, 0);
  assert.equal(pv.balanceAfter, 700);
  assert.equal(pv.openAfter, 0);
  assert.equal(pv.nextPayoutDeducts, 0);
});

test("deducting more than the balance warns that it goes negative", () => {
  const pv = settlementPreview({ open: 300, balance: 50, amount: 120, mode: "deduct" });
  assert.equal(pv.ok, true);
  assert.equal(pv.balanceAfter, -70);
  assert.equal(pv.balanceGoesNegative, true);
});

test("a settlement over what is owed, or of nothing, is refused", () => {
  const over = settlementPreview({ open: 120, balance: 0, amount: 121, mode: "payment" });
  assert.equal(over.ok, false);
  assert.equal(over.error, "over");
  assert.equal(over.openAfter, 120, "nothing changes when refused");
  assert.equal(over.treasuryIn, 0);
  for (const amount of [0, -5, Number.NaN]) {
    assert.equal(
      settlementPreview({ open: 120, balance: 0, amount, mode: "payment" }).error,
      "amount",
    );
  }
});

test("the whole open amount, with cents, settles to exactly zero", () => {
  const pv = settlementPreview({ open: 99.9, balance: 10, amount: 99.9, mode: "payment" });
  assert.equal(pv.openAfter, 0);
  assert.equal(pv.treasuryIn, 99.9);
});

// --- Which month a salary counts in --------------------------------------

test("a salary counts in its own month unless one was picked", () => {
  assert.equal(profitMonthOf("2026-09-01", null), "2026-09");
  assert.equal(profitMonthOf("2026-09-01", undefined), "2026-09");
  assert.equal(profitMonthOf("2026-09-01", "2026-10-01"), "2026-10");
});

test("month choices go two either side and cross the year", () => {
  assert.deepEqual(profitMonthOptions("2026-12-01"), [
    "2026-10",
    "2026-11",
    "2026-12",
    "2027-01",
    "2027-02",
  ]);
  assert.deepEqual(profitMonthOptions("2026-01-15", 1, 0), ["2025-12", "2026-01"]);
});

test("the stored month is its first day", () => {
  assert.equal(monthFirstDay("2026-10"), "2026-10-01");
  assert.equal(monthFirstDay("2026-10-17"), "2026-10-01");
});

test("month labels read as a month name and year", () => {
  assert.equal(monthLabel("2026-10", "en"), "October 2026");
  assert.ok(monthLabel("2026-10", "ar").includes("أكتوبر"));
});

// --- A shift closes on the day it opened ---------------------------------

test("a shift closed after midnight shows its opening day with the real time kept", () => {
  // Opened 23 Oct, closed 24 Oct 09:59 Cairo (06:59 UTC).
  const close = shiftCloseLabel("2026-10-23", "2026-10-24T06:59:00Z", "en");
  assert.ok(close.label.startsWith("Shift day 23 Oct 2026"), close.label);
  assert.ok(close.label.includes(businessTime("2026-10-24T06:59:00Z", "en")));
  assert.equal(close.nextDay, true);
  assert.ok(close.actual.includes("24 Oct 2026"), close.actual);
});

test("a shift closed the same day is not flagged", () => {
  const close = shiftCloseLabel("2026-10-23", "2026-10-23T20:00:00Z", "en");
  assert.equal(close.nextDay, false);
  assert.ok(close.label.includes("23 Oct 2026"));
});

test("an open shift has no close label, and Arabic uses the agreed wording", () => {
  assert.deepEqual(shiftCloseLabel("2026-10-23", null), {
    label: "—",
    actual: "—",
    nextDay: false,
  });
  const ar = shiftCloseLabel("2026-10-23", "2026-10-24T06:59:00Z", "ar");
  assert.ok(ar.label.startsWith("يوم الوردية "));
  assert.ok(ar.label.includes(" · اتقفلت "));
});

test("without a business day the close day is used", () => {
  const close = shiftCloseLabel(null, "2026-10-24T06:59:00Z", "en");
  assert.equal(close.nextDay, false);
  assert.ok(close.label.includes("24 Oct 2026"));
});

// --- Payment-method cards add up to revenue (mirrors SQL _tender_net) -----

test("a paid invoice whose items were all removed leaves nothing on cash", () => {
  // 261024-0001: 115 cash, both lines removed, 85 + 30 handed back.
  const net = orderTenderNet({
    order_payments: [{ method_key: "cash", amount: 115 }],
    order_refunds: [
      { method_key: "cash", amount: 85, status: "active" },
      { method_key: "cash", amount: 30, status: "active" },
    ],
  });
  assert.deepEqual(net, { cash: 0 });
});

test("paid by card and refunded in cash: card keeps it, cash goes down", () => {
  // 20S-260927-0008: 65 by card, 65 back in cash from the drawer.
  const net = orderTenderNet({
    order_payments: [{ method_key: "card", amount: 65 }],
    order_refunds: [{ method_key: "cash", amount: 65, status: "active" }],
  });
  assert.deepEqual(net, { visa: 65, cash: -65 });
  assert.equal(
    Object.values(net).reduce((a, b) => a + b, 0),
    0,
    "the invoice nets to its revenue: 0",
  );
});

test("a partner-tab invoice shows on the partner card; its removed item is not taken off twice", () => {
  const net = orderTenderNet({
    order_payments: [],
    order_refunds: [{ method_key: "partner_tab", amount: 120, status: "active" }],
    partner_tab_orders: [{ total_amount: 0 }],
  });
  assert.deepEqual(net, { partner_tab: 0 });
  assert.deepEqual(orderTenderNet({ partner_tab_orders: { total_amount: 65 } }), {
    partner_tab: 65,
  });
});

test("split payments, reversed refunds and points", () => {
  const net = orderTenderNet({
    order_payments: [
      { method_key: "cash", amount: 50 },
      { method_key: "instapay", amount: 100 },
      { method_key: "points", amount: 10 },
    ],
    order_refunds: [
      { method_key: "instapay", amount: 40, status: "active" },
      { method_key: "cash", amount: 50, status: "reversed" },
    ],
  });
  assert.deepEqual(net, { cash: 50, instapay: 60 });
});
