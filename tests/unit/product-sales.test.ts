import { test } from "node:test";
import assert from "node:assert/strict";

import { groupProductSales } from "../../src/core/finance/product-sales.ts";

test("each product shows how many were sold at each price, per size, with totals", () => {
  const groups = groupProductSales([
    { product: "Lemon Juice", size: "", price: 20, qty: 4, revenue: 80, cost: 20, profit: 60 },
    { product: "Lemon Juice", size: "", price: 30, qty: 2, revenue: 60, cost: 10, profit: 50 },
    { product: "Latte", size: "Large", price: 75, qty: 3, revenue: 225, cost: 60, profit: 165 },
    { product: "Latte", size: "Small", price: 65, qty: 1, revenue: 65, cost: 15, profit: 50 },
  ]);
  assert.deepEqual(
    groups.map((g) => [g.product, g.qty, g.revenue, g.cost, g.profit]),
    [
      ["Latte", 4, 290, 75, 215],
      ["Lemon Juice", 6, 140, 30, 110],
    ],
  );
  assert.deepEqual(
    groups[1]!.lines.map((l) => [l.price, l.qty]),
    [
      [30, 2],
      [20, 4],
    ],
  );
  assert.deepEqual(
    groups[0]!.lines.map((l) => l.size),
    ["Large", "Small"],
  );
});

test("cost and profit stay hidden when the user may not see them", () => {
  const [g] = groupProductSales([
    { product: "Tea", size: "", price: 25, qty: 2, revenue: 50, cost: null, profit: null },
  ]);
  assert.equal(g!.cost, null);
  assert.equal(g!.profit, null);
});
