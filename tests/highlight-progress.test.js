const assert = require("node:assert/strict");
const test = require("node:test");
const { computeFocusStops } = require("../highlight_progress");

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
