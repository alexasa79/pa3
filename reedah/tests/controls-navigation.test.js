const assert = require("node:assert/strict");
const test = require("node:test");
const { getAdjacentItem } = require("../controls_navigation");

test("getAdjacentItem returns next and previous items", () => {
  const items = ["a", "b", "c", "d"];
  assert.equal(getAdjacentItem(items, "b", 1), "c");
  assert.equal(getAdjacentItem(items, "c", -1), "b");
});

test("getAdjacentItem returns null at bounds", () => {
  const items = ["a", "b"];
  assert.equal(getAdjacentItem(items, "a", -1), null);
  assert.equal(getAdjacentItem(items, "b", 1), null);
});

test("getAdjacentItem returns null for invalid inputs", () => {
  assert.equal(getAdjacentItem(null, "a", 1), null);
  assert.equal(getAdjacentItem([], "a", 1), null);
  assert.equal(getAdjacentItem(["a"], null, 1), null);
  assert.equal(getAdjacentItem(["a"], "x", 1), null);
  assert.equal(getAdjacentItem(["a"], "a", 0), null);
});
