import { test } from "node:test";
import assert from "node:assert/strict";

import { nextPayoutRange, payoutMonths } from "../../src/core/finance/payout-months.ts";

test("nothing paid yet: every month is open and the payout starts on the first business day", () => {
  const months = payoutMonths("2026-09-18", "2026-10-24", []);
  assert.deepEqual(
    months.map((m) => [m.month, m.start, m.end, m.status, m.days]),
    [
      ["2026-09", "2026-09-18", "2026-09-30", "open", 13],
      ["2026-10", "2026-10-01", "2026-10-24", "open", 24],
    ],
  );
  assert.equal(months[1]!.current, true);
  assert.deepEqual(nextPayoutRange(months, "2026-10-24", []), {
    from: "2026-09-18",
    to: "2026-09-30",
  });
});

test("a later month paid first: the next payout goes back to the earliest unpaid month", () => {
  const paid = [{ from: "2026-10-01", to: "2026-10-31", status: "active" }];
  const months = payoutMonths("2026-09-18", "2026-11-10", paid);
  assert.deepEqual(
    months.map((m) => [m.month, m.status]),
    [
      ["2026-09", "open"],
      ["2026-10", "paid"],
      ["2026-11", "open"],
    ],
  );
  assert.deepEqual(nextPayoutRange(months, "2026-11-10", paid), {
    from: "2026-09-18",
    to: "2026-09-30",
  });
});

test("a reversed payout does not count", () => {
  const months = payoutMonths("2026-09-18", "2026-10-24", [
    { from: "2026-09-18", to: "2026-09-30", status: "reversed" },
  ]);
  assert.equal(months[0]!.status, "open");
});

test("a part-paid month continues the day after, and stops before a later paid stretch", () => {
  const paid = [
    { from: "2026-09-18", to: "2026-09-22", status: "active" },
    { from: "2026-09-27", to: "2026-09-30", status: "active" },
  ];
  const months = payoutMonths("2026-09-18", "2026-10-24", paid);
  assert.equal(months[0]!.status, "partial");
  assert.equal(months[0]!.paidDays, 9);
  assert.equal(months[0]!.firstUnpaid, "2026-09-23");
  assert.deepEqual(nextPayoutRange(months, "2026-10-24", paid), {
    from: "2026-09-23",
    to: "2026-09-26",
  });
});

test("only the running month is left: it pays out up to yesterday", () => {
  const paid = [{ from: "2026-09-18", to: "2026-09-30", status: "active" }];
  const months = payoutMonths("2026-09-18", "2026-10-24", paid);
  assert.deepEqual(nextPayoutRange(months, "2026-10-24", paid), {
    from: "2026-10-01",
    to: "2026-10-23",
  });
});

test("everything paid: no next payout", () => {
  const paid = [{ from: "2026-09-18", to: "2026-10-24", status: "active" }];
  const months = payoutMonths("2026-09-18", "2026-10-24", paid);
  assert.ok(months.every((m) => m.status === "paid"));
  assert.equal(nextPayoutRange(months, "2026-10-24", paid), null);
});
