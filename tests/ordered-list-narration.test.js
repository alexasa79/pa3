const assert = require("node:assert/strict");
const test = require("node:test");
const {
  parseIntegerAttribute,
  resolveOrderedListItemNumber,
  integerToEnglishCardinal,
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
