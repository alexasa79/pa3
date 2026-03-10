const assert = require("node:assert/strict");
const test = require("node:test");
const {
  parseIntegerAttribute,
  resolveOrderedListItemNumber,
  integerToEnglishCardinal,
  numberToAlpha,
  buildOrderedListNarrationPrefix
} = require("../ordered_list_narration");

test("parseIntegerAttribute parses signed integer strings", () => {
  assert.equal(parseIntegerAttribute("12"), 12);
  assert.equal(parseIntegerAttribute(" -4 "), -4);
});

test("parseIntegerAttribute rejects invalid values", () => {
  assert.equal(parseIntegerAttribute(""), null);
  assert.equal(parseIntegerAttribute("5.2"), null);
  assert.equal(parseIntegerAttribute("abc"), null);
});

test("resolveOrderedListItemNumber computes non-reversed list values", () => {
  const values = [null, null, null];
  const number = resolveOrderedListItemNumber(values, 1, false, 1);
  assert.equal(number, 2);
});

test("resolveOrderedListItemNumber handles explicit li value overrides", () => {
  const values = [null, 7, null];
  const number = resolveOrderedListItemNumber(values, 1, false, 2);
  assert.equal(number, 8);
});

test("resolveOrderedListItemNumber handles reversed lists", () => {
  const values = [null, null, null];
  const number = resolveOrderedListItemNumber(values, 3, true, 2);
  assert.equal(number, 1);
});

test("integerToEnglishCardinal converts integers to spoken words", () => {
  assert.equal(integerToEnglishCardinal(1), "one");
  assert.equal(integerToEnglishCardinal(42), "forty-two");
  assert.equal(integerToEnglishCardinal(2305), "two thousand three hundred five");
});

test("buildOrderedListNarrationPrefix formats spoken prefixes", () => {
  assert.equal(buildOrderedListNarrationPrefix(2), "Two. ");
  assert.equal(buildOrderedListNarrationPrefix(-3), "Minus three. ");
});

test("buildOrderedListNarrationPrefix returns null for unsupported values", () => {
  assert.equal(buildOrderedListNarrationPrefix(Number.NaN), null);
  assert.equal(buildOrderedListNarrationPrefix(1000000000000), null);
});

test("numberToAlpha converts positive integers to alphabetic strings", () => {
  assert.equal(numberToAlpha(1), "a");
  assert.equal(numberToAlpha(2), "b");
  assert.equal(numberToAlpha(26), "z");
});

test("numberToAlpha wraps around after z", () => {
  assert.equal(numberToAlpha(27), "aa");
  assert.equal(numberToAlpha(28), "ab");
  assert.equal(numberToAlpha(53), "ba");
});

test("numberToAlpha returns null for non-positive integers", () => {
  assert.equal(numberToAlpha(0), null);
  assert.equal(numberToAlpha(-1), null);
  assert.equal(numberToAlpha(Number.NaN), null);
});

test("buildOrderedListNarrationPrefix with alphabetic marker type 'a'", () => {
  assert.equal(buildOrderedListNarrationPrefix(1, "a"), "A. ");
  assert.equal(buildOrderedListNarrationPrefix(2, "a"), "B. ");
  assert.equal(buildOrderedListNarrationPrefix(26, "a"), "Z. ");
  assert.equal(buildOrderedListNarrationPrefix(27, "a"), "AA. ");
});

test("buildOrderedListNarrationPrefix with marker type 'A' matches 'a'", () => {
  assert.equal(buildOrderedListNarrationPrefix(1, "A"), "A. ");
  assert.equal(buildOrderedListNarrationPrefix(3, "A"), "C. ");
});

test("buildOrderedListNarrationPrefix with alphabetic type returns null for non-positive", () => {
  assert.equal(buildOrderedListNarrationPrefix(0, "a"), null);
  assert.equal(buildOrderedListNarrationPrefix(-1, "A"), null);
});

test("buildOrderedListNarrationPrefix with roman numeral types uses English cardinal", () => {
  assert.equal(buildOrderedListNarrationPrefix(3, "i"), "Three. ");
  assert.equal(buildOrderedListNarrationPrefix(3, "I"), "Three. ");
});

test("buildOrderedListNarrationPrefix with default/missing type preserves current behavior", () => {
  assert.equal(buildOrderedListNarrationPrefix(2), "Two. ");
  assert.equal(buildOrderedListNarrationPrefix(2, "1"), "Two. ");
});
