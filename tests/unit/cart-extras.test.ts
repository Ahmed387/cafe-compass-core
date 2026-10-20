import { test } from "node:test";
import assert from "node:assert/strict";

import { toggleExtraOnOneUnit } from "../../src/modules/operations/cart-extras.ts";

const sauce = { option_id: "sauce", name: "Caramel", price_delta: 10 };
const latte = (quantity: number) => ({ key: "latte|M|", product_id: "latte", quantity, modifiers: [] as typeof sauce[] });

test("sauce on a line of 2 lattes goes on one unit only", () => {
  const { cart, key } = toggleExtraOnOneUnit([latte(2)], "latte|M|", sauce, "latte|M|-x1");
  assert.equal(cart.length, 2);
  assert.deepEqual(cart.map((l) => [l.key, l.quantity, l.modifiers.length]), [["latte|M|", 1, 0], ["latte|M|-x1", 1, 1]]);
  assert.equal(key, "latte|M|-x1");
});

test("a single latte with sauce gets a new key so the next tap does not merge into it", () => {
  const { cart } = toggleExtraOnOneUnit([latte(1)], "latte|M|", sauce, "latte|M|-x1");
  assert.equal(cart[0]?.key, "latte|M|-x1");
  // addLine merges by the plain signature "latte|M|": it must not find the sauced line.
  assert.equal(cart.find((l) => l.key === "latte|M|"), undefined);
});

test("tapping the same extra again removes it", () => {
  const first = toggleExtraOnOneUnit([latte(1)], "latte|M|", sauce, "k1");
  const second = toggleExtraOnOneUnit(first.cart, first.key, sauce, "k2");
  assert.equal(second.cart[0]?.modifiers.length, 0);
});

test("other lines are untouched and an unknown key changes nothing", () => {
  const other = { key: "tea||", product_id: "tea", quantity: 3, modifiers: [] as typeof sauce[] };
  const { cart } = toggleExtraOnOneUnit([latte(2), other], "latte|M|", sauce, "x");
  assert.equal(cart.length, 3);
  assert.ok(cart.some((l) => l.key === "tea||" && l.quantity === 3));
  const same = toggleExtraOnOneUnit([other], "missing", sauce, "y");
  assert.deepEqual(same.cart, [other]);
});
