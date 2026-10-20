import { test } from "node:test";
import assert from "node:assert/strict";

import { buildSuggestions, marginPct, minPriceForMargin, profitPerUnit, suggestedMargin, type AdvisorRow } from "../../src/lib/offer-advisor.ts";

const row = (over: Partial<AdvisorRow>): AdvisorRow => ({
  product_id: "p",
  name: "Latte",
  name_ar: "لاتيه",
  category: null,
  base_price: 80,
  unit_cost: 24,
  qty: 50,
  revenue: 4000,
  orders_count: 40,
  last_sold_at: null,
  stock_item: null,
  stock_days: null,
  ...over,
});

test("margin and profit follow the edited price", () => {
  assert.equal(marginPct(80, 24), 70);
  assert.equal(marginPct(60, 24), 60);
  assert.equal(profitPerUnit(60, 24), 36);
  assert.equal(marginPct(0, 24), 0);
});

test("lowest price for a margin never goes under the 25% safety floor", () => {
  assert.equal(minPriceForMargin(24, 40), 40);
  assert.equal(minPriceForMargin(24, 10), 30); // 24 × 1.25
  assert.equal(minPriceForMargin(0, 40), 0);
});

test("suggested margin gives up part of the normal margin but keeps at least 30%", () => {
  assert.equal(suggestedMargin(70, "slow_mover"), 55);
  assert.equal(suggestedMargin(70, "overstock"), 50);
  assert.equal(suggestedMargin(70, "best_seller"), 62);
  assert.equal(suggestedMargin(35, "overstock"), 30);
  assert.equal(suggestedMargin(20, "overstock"), 20);
});

test("classifies slow, overstock and best sellers with a reason, and never prices under the margin", () => {
  const rows = [
    row({ product_id: "slow", name: "Mocha", name_ar: "موكا", qty: 2 }),
    row({ product_id: "mid1", qty: 20 }),
    row({ product_id: "mid2", qty: 25 }),
    row({ product_id: "mid3", qty: 30 }),
    row({ product_id: "best", name: "Espresso", name_ar: "اسبريسو", qty: 200, base_price: 40, unit_cost: 8 }),
    row({ product_id: "stock", qty: 22, stock_item: "حليب شوفان", stock_days: 75 }),
    row({ product_id: "nocost", qty: 1, unit_cost: 0 }),
  ];
  const s = buildSuggestions(rows, 30, "ar");
  const kinds = Object.fromEntries(s.map((x) => [x.product_id, x.kind]));
  assert.equal(kinds["slow"], "slow_mover");
  assert.equal(kinds["best"], "best_seller");
  assert.equal(kinds["stock"], "overstock");
  assert.equal(kinds["nocost"], undefined);
  for (const x of s) {
    assert.ok(x.reason.ar.length > 10 && x.reason.en.length > 10);
    assert.ok(x.suggested_price >= x.floor_price - 0.5, `${x.product_id} under floor`);
    assert.ok(x.suggested_price <= x.base_price);
    assert.ok(marginPct(x.suggested_price, x.unit_cost) >= x.suggested_margin - 1);
  }
  assert.match(s.find((x) => x.product_id === "stock")!.reason.ar, /حليب شوفان/);
});

test("no priced products → no suggestions", () => {
  assert.deepEqual(buildSuggestions([row({ base_price: 0 })], 30), []);
});
