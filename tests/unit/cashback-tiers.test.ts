import { test } from "node:test";
import assert from "node:assert/strict";

import { accrueCashback, nextTier, parseCashbackConfig, tierError } from "../../src/lib/cashback-tiers.ts";

const tiers = [
  { target: 500, reward: 25 },
  { target: 1000, reward: 60 },
  { target: 2000, reward: 150 },
];

test("each level reached pays its own reward", () => {
  assert.deepEqual(accrueCashback(tiers, 0, 0, 400), { earned: 0, progress: 400, level: 0 });
  assert.deepEqual(accrueCashback(tiers, 400, 0, 700), { earned: 85, progress: 1100, level: 2 });
});

test("after the last level the customer starts again from level 1", () => {
  // 1100 + 1500 = 2600: level 3 pays 150, restart with 600, which passes level 1 again.
  assert.deepEqual(accrueCashback(tiers, 1100, 2, 1500), { earned: 175, progress: 600, level: 1 });
  assert.deepEqual(nextTier(tiers, 600, 1)?.left, 400);
});

test("one level works like the old every-X rule", () => {
  const one = [{ target: 500, reward: 25 }];
  assert.deepEqual(accrueCashback(one, 300, 0, 1250), { earned: 75, progress: 50, level: 0 });
});

test("old configs without tiers become one level", () => {
  const cfg = parseCashbackConfig({ enabled: true, target_amount: 500, reward_amount: 25 });
  assert.deepEqual(cfg.tiers, [{ target: 500, reward: 25 }]);
});

test("levels must grow and pay less than their target", () => {
  assert.equal(tierError(tiers, "en"), "");
  assert.notEqual(tierError([{ target: 500, reward: 25 }, { target: 400, reward: 30 }], "en"), "");
  assert.notEqual(tierError([{ target: 500, reward: 500 }], "en"), "");
  assert.notEqual(tierError([], "en"), "");
});
