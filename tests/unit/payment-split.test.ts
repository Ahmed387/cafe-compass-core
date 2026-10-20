import { test } from "node:test";
import assert from "node:assert/strict";

import { addTender, singleTender, summarizePayments, toServerPayments } from "../../src/modules/operations/payment-split.ts";

let n = 0;
const id = () => `r${++n}`;

test("one bill paid two ways: each amount stays on its own method", () => {
  const rows = [
    { id: "a", methodKey: "cash", amount: "60" },
    { id: "b", methodKey: "instapay", amount: "40.50" },
  ];
  const s = summarizePayments(rows, 100.5, 0);
  assert.equal(s.paid, 100.5);
  assert.equal(s.balanced, true);
  assert.equal(s.byMethod.get("cash"), 60);
  assert.equal(s.byMethod.get("instapay"), 40.5);
  assert.deepEqual(toServerPayments(rows, (k) => `pm-${k}`), [
    { payment_method_id: "pm-cash", method_key: "cash", amount: 60 },
    { payment_method_id: "pm-instapay", method_key: "instapay", amount: 40.5 },
  ]);
});

test("payments that don't add up to the bill can't be confirmed", () => {
  const s = summarizePayments([{ id: "a", methodKey: "cash", amount: "50" }], 80, 0);
  assert.equal(s.balanced, false);
  assert.equal(s.remaining, 30);
});

test("floating point: 0.1 + 0.2 style totals still balance", () => {
  const s = summarizePayments(
    [
      { id: "a", methodKey: "cash", amount: "33.33" },
      { id: "b", methodKey: "wallet", amount: "33.33" },
      { id: "c", methodKey: "instapay", amount: "33.34" },
    ],
    100,
    0,
  );
  assert.equal(s.balanced, true);
});

test("cashback above the wallet balance is flagged; cashback has no payment method id", () => {
  const rows = [
    { id: "a", methodKey: "cashback", amount: "30" },
    { id: "b", methodKey: "cash", amount: "20" },
  ];
  assert.equal(summarizePayments(rows, 50, 25).cashbackOver, true);
  assert.equal(summarizePayments(rows, 50, 30).cashbackOver, false);
  assert.deepEqual(toServerPayments(rows, () => "x")[0], { method_key: "cashback", amount: 30 });
});

test("a negative line blocks the sheet and empty lines are not sent", () => {
  const rows = [
    { id: "a", methodKey: "cash", amount: "120" },
    { id: "b", methodKey: "instapay", amount: "-20" },
    { id: "c", methodKey: "wallet", amount: "" },
  ];
  assert.equal(summarizePayments(rows, 100, 0).hasNegative, true);
  assert.equal(toServerPayments(rows, () => null).length, 1);
});

test("quick tender puts the whole bill on one method; adding a tender takes what's left", () => {
  const one = singleTender("instapay", 85, id);
  assert.deepEqual(one.map((r) => [r.methodKey, r.amount]), [["instapay", "85.00"]]);
  const partial = [{ id: "a", methodKey: "cash", amount: "50" }];
  const two = addTender(partial, "wallet", 85, id);
  assert.equal(two[1]?.amount, "35.00");
  const full = addTender([{ id: "a", methodKey: "cash", amount: "85" }], "wallet", 85, id);
  assert.equal(full[1]?.amount, "");
});
