import assert from "node:assert/strict";
import { test } from "node:test";

import { DB_ERROR_TEMPLATES, dbErrorToArabic } from "../../src/lib/db-errors-ar.ts";
import { friendlyError } from "../../src/lib/format.ts";

test("every database message has Arabic wording", () => {
  for (const template of DB_ERROR_TEMPLATES) {
    const sample = template
      .split("%%")
      .map((part) => part.replace(/%/g, "X"))
      .join("%");
    const ar = dbErrorToArabic(sample);
    assert.ok(ar && /[؀-ۿ]/.test(ar), template);
  }
});

test("values from the database are carried into the Arabic text", () => {
  assert.equal(
    dbErrorToArabic("Cannot refund more than the remaining 1 on Latte"),
    "مينفعش ترجّع أكتر من الباقي (1) من Latte.",
  );
  assert.equal(
    dbErrorToArabic("Payments (90.00) are less than order total (100.00)"),
    "المدفوع (90.00) أقل من إجمالي الفاتورة (100.00).",
  );
  assert.equal(dbErrorToArabic("not authenticated"), "لازم تسجل دخول الأول.");
  assert.equal(
    dbErrorToArabic("Waste must be between 0 and 100%"),
    "نسبة الهالك لازم تبقى من 0 لـ 100%.",
  );
});

test("friendlyError shows Arabic for database messages and never raw English in Arabic", () => {
  assert.equal(
    friendlyError({ message: "This order is fully refunded" }, "ar"),
    "الفاتورة دي اترجعت كلها خلاص.",
  );
  assert.equal(
    friendlyError({ message: "Shift not found", details: "x" }, "ar"),
    "الوردية مش موجودة.",
  );
  // Unknown English text falls back to the generic Arabic message.
  assert.equal(
    friendlyError({ message: "Some brand new English error" }, "ar"),
    "حدث خطأ ما. حاول مرة أخرى.",
  );
  // Arabic text from the database is shown as it is.
  assert.equal(friendlyError({ message: "الوردية مقفولة" }, "ar"), "الوردية مقفولة");
  // English screens keep the original message.
  assert.equal(
    friendlyError({ message: "This order is fully refunded" }, "en"),
    "This order is fully refunded",
  );
  assert.equal(
    friendlyError({ message: "Not enough stock available for Milk" }, "ar"),
    "الكمية المتاحة غير كافية من: Milk",
  );
});
