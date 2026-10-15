const assert = require("node:assert/strict");
const test = require("node:test");
const { computeFocusStops, computeWordFocusStrength } = require("../highlight_progress");

test("computeFocusStops centers focus when progress is inside span", () => {
  const stops = computeFocusStops(0, 1, 0.5, 0.2);
  assert.deepEqual(stops, {
    startPercent: 40,
    centerPercent: 50,
    endPercent: 60
  });
});

test("computeFocusStops returns null when span does not intersect focus spread", () => {
  const stops = computeFocusStops(0.5, 1, 0.1, 0.1);
  assert.equal(stops, null);
});

test("computeFocusStops clamps focus range at span boundaries", () => {
  const stops = computeFocusStops(0.2, 0.4, 0.2, 0.2);
  assert.deepEqual(stops, {
    startPercent: 0,
    centerPercent: 0,
    endPercent: 50
  });
});

test("computeFocusStops returns null for invalid inputs", () => {
  assert.equal(computeFocusStops(0, 0, 0.5, 0.2), null);
  assert.equal(computeFocusStops(0, 1, Number.NaN, 0.2), null);
  assert.equal(computeFocusStops(0, 1, 0.5, 0), null);
});

test("computeWordFocusStrength returns full strength inside focus window", () => {
  const strength = computeWordFocusStrength(14, 20, 10, 40, 8);
  assert.equal(strength, 1);
});

test("computeWordFocusStrength fades smoothly in edge zones", () => {
  const near = computeWordFocusStrength(3, 8, 10, 40, 8);
  const far = computeWordFocusStrength(0, 2, 10, 40, 8);
  assert.ok(near > far);
  assert.ok(near > 0);
  assert.equal(far, 0);
});

test("computeWordFocusStrength returns zero outside focus edge range", () => {
  const strength = computeWordFocusStrength(60, 66, 10, 40, 8);
  assert.equal(strength, 0);
});

test("computeWordFocusStrength returns null for invalid inputs", () => {
  assert.equal(computeWordFocusStrength(8, 4, 10, 40, 8), null);
  assert.equal(computeWordFocusStrength(4, 8, Number.NaN, 40, 8), null);
  assert.equal(computeWordFocusStrength(4, 8, 40, 10, 8), null);
  assert.equal(computeWordFocusStrength(4, 8, 10, 40, -1), null);
});
