const assert = require("node:assert/strict");
const test = require("node:test");
const { computeHighlightSlices } = require("../highlight_ranges");

test("computeHighlightSlices selects only intersecting segment portions", () => {
  const segments = [
    { id: "a", start: 0, end: 4 },
    { id: "b", start: 4, end: 9 },
    { id: "c", start: 9, end: 14 }
  ];

  const slices = computeHighlightSlices(segments, 2, 11);
  assert.equal(slices.length, 3);

  assert.equal(slices[0].segment, segments[0]);
  assert.equal(slices[0].startOffset, 2);
  assert.equal(slices[0].endOffset, 4);

  assert.equal(slices[1].segment, segments[1]);
  assert.equal(slices[1].startOffset, 0);
  assert.equal(slices[1].endOffset, 5);

  assert.equal(slices[2].segment, segments[2]);
  assert.equal(slices[2].startOffset, 0);
  assert.equal(slices[2].endOffset, 2);
});

test("computeHighlightSlices maps start boundary to the following segment", () => {
  const segments = [
    { id: "a", start: 0, end: 4 },
    { id: "b", start: 4, end: 9 }
  ];

  const slices = computeHighlightSlices(segments, 4, 9);
  assert.equal(slices.length, 1);
  assert.equal(slices[0].segment, segments[1]);
  assert.equal(slices[0].startOffset, 0);
  assert.equal(slices[0].endOffset, 5);
});

test("computeHighlightSlices maps end boundary to the preceding segment", () => {
  const segments = [
    { id: "a", start: 0, end: 4 },
    { id: "b", start: 4, end: 9 }
  ];

  const slices = computeHighlightSlices(segments, 1, 4);
  assert.equal(slices.length, 1);
  assert.equal(slices[0].segment, segments[0]);
  assert.equal(slices[0].startOffset, 1);
  assert.equal(slices[0].endOffset, 4);
});

test("computeHighlightSlices returns empty for invalid inputs", () => {
  assert.deepEqual(computeHighlightSlices(null, 0, 1), []);
  assert.deepEqual(computeHighlightSlices([], 0, 1), []);
  assert.deepEqual(computeHighlightSlices([{ start: 0, end: 1 }], 4, 4), []);
  assert.deepEqual(computeHighlightSlices([{ start: 0, end: 1 }], 3, 1), []);
});
