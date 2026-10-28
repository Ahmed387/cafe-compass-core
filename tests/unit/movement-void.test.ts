import { test } from "node:test";
import assert from "node:assert/strict";

import {
  canEditMovement,
  canVoidMovement,
  movementsForTab,
  stockAfterVoid,
  stockAfterVoidAll,
} from "../../src/core/inventory/movement-void.ts";
import { dbErrorToArabic } from "../../src/lib/db-errors-ar.ts";

const row = (over: Partial<Parameters<typeof canVoidMovement>[0]> = {}) => ({
  movement_type: "purchase",
  reference_type: "manual",
  voided_at: null,
  quantity: 50,
  ...over,
});

test("manual purchases, adjustments, opening stock and waste can be cancelled", () => {
  assert.equal(canVoidMovement(row()), true);
  assert.equal(canVoidMovement(row({ movement_type: "adjustment" })), true);
  assert.equal(
    canVoidMovement(row({ movement_type: "adjustment", reference_type: "opening_balance" })),
    true,
  );
  assert.equal(canVoidMovement(row({ movement_type: "waste", quantity: -3 })), true);
  // Very old rows have no reference type: they were typed by hand.
  assert.equal(canVoidMovement(row({ reference_type: null })), true);
});

test("sales, invoices, stocktakes and transfers are not cancelled from here", () => {
  assert.equal(
    canVoidMovement(row({ movement_type: "sale_consumption", reference_type: "order_item" })),
    false,
  );
  assert.equal(
    canVoidMovement(row({ movement_type: "sale_return", reference_type: "order" })),
    false,
  );
  assert.equal(canVoidMovement(row({ reference_type: "purchase" })), false);
  assert.equal(
    canVoidMovement(row({ movement_type: "stocktake", reference_type: "stocktake" })),
    false,
  );
  assert.equal(canVoidMovement(row({ movement_type: "transfer_out" })), false);
});

test("a stock reset row can be cancelled (puts the item back) but not edited", () => {
  const reset = row({ movement_type: "adjustment", reference_type: "stock_reset", quantity: -95 });
  assert.equal(canVoidMovement(reset), true);
  assert.equal(canEditMovement(reset), false);
  assert.equal(stockAfterVoid(0, reset.quantity), 95);
});

test("a cancelled movement can be neither edited nor cancelled again", () => {
  const voided = row({ voided_at: "2026-10-28T19:00:00Z" });
  assert.equal(canEditMovement(voided), false);
  assert.equal(canVoidMovement(voided), false);
  assert.equal(canEditMovement(row()), true);
});

test("stock after cancelling: an entry comes out, a waste goes back, and it can go below zero", () => {
  // 50 Pepsi entered by mistake, stock now 80 -> back to 30.
  assert.equal(stockAfterVoid(80, 50), 30);
  // Cancelling a waste of 3 puts the 3 back.
  assert.equal(stockAfterVoid(10, -3), 13);
  // 20 of the 50 were already sold: stock goes negative (the dialog warns).
  assert.equal(stockAfterVoid(30, 50), -20);
  // Grams keep three decimals, no float noise.
  assert.equal(stockAfterVoid(848.5, "0.3"), 848.2);
  assert.equal(stockAfterVoid(0.3, 0.1), 0.2);
});

test("the movements tab shows live rows only, the cancelled tab cancelled rows only", () => {
  const rows = [
    { id: "a", voided_at: null },
    { id: "b", voided_at: "2026-10-28T19:00:00Z" },
    { id: "c", voided_at: null },
  ];
  assert.deepEqual(
    movementsForTab(rows, "movements").map((r) => r.id),
    ["a", "c"],
  );
  assert.deepEqual(
    movementsForTab(rows, "voided").map((r) => r.id),
    ["b"],
  );
});

test("every cancel error from the database reads in Arabic", () => {
  for (const msg of [
    "Movement not found",
    "This movement is already cancelled",
    "Only manual stock movements can be cancelled",
    "No stock recorded for this item in this branch",
    "A reason is required",
    "This waste was already deducted in payroll and can no longer change",
    "Choose at least one movement",
    "Cancel at most 200 movements at a time",
    "Only the super admin can reset all stock",
  ]) {
    assert.ok(dbErrorToArabic(msg), msg);
  }
});

test("cancelling several at once: rows of the same item add up before the warning", () => {
  const stock = new Map([
    ["pepsi", 80],
    ["water", 5],
  ]);
  const result = stockAfterVoidAll(stock, [
    { item_id: "pepsi", quantity: 50 },
    { item_id: "water", quantity: 3 },
    { item_id: "pepsi", quantity: "40" },
    { item_id: "water", quantity: -1 },
  ]);
  assert.deepEqual(result, [
    // 50 + 40 came in by mistake, but only 80 are left: the batch goes to -10.
    { item_id: "pepsi", count: 2, quantity: 90, after: -10 },
    // +3 out, a waste of 1 back: 5 - 3 + 1.
    { item_id: "water", count: 2, quantity: 2, after: 3 },
  ]);
  assert.deepEqual(stockAfterVoidAll(stock, []), []);
});

test("batch errors name the item in Arabic", () => {
  assert.equal(
    dbErrorToArabic("The movement of بيبسي is already cancelled"),
    "حركة بيبسي اتلغت قبل كده.",
  );
  assert.equal(
    dbErrorToArabic("The movement of mango is not a manual one and cannot be cancelled here"),
    "حركة mango مش يدوية، ومينفعش تتلغي من هنا.",
  );
  assert.equal(
    dbErrorToArabic("The waste of لبن was already deducted in payroll and can no longer change"),
    "هالك لبن اتخصم في المرتبات خلاص ومينفعش يتغير.",
  );
});
