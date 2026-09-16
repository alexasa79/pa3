const assert = require("node:assert/strict");
const test = require("node:test");
const { computeHoverBounds } = require("../hover_bounds");

test("computeHoverBounds keeps ordered-list overlay area inside hover hitbox", () => {
  const targetRect = { left: 120, right: 360, top: 200, bottom: 240 };
  const overlayRect = { left: 70, right: 88, top: 200, bottom: 218 };
  const bounds = computeHoverBounds({
    targetRect,
    overlayRect,
    padding: 32
  });

  const overlayCenterX = (overlayRect.left + overlayRect.right) / 2;
  const overlayCenterY = (overlayRect.top + overlayRect.bottom) / 2;

  assert.ok(overlayCenterX >= bounds.left && overlayCenterX <= bounds.right);
  assert.ok(overlayCenterY >= bounds.top && overlayCenterY <= bounds.bottom);
  assert.equal(bounds.left, 38);
});

test("computeHoverBounds falls back to target rectangle when overlay is hidden", () => {
  const targetRect = { left: 100, right: 200, top: 300, bottom: 340 };
  const bounds = computeHoverBounds({
    targetRect,
    overlayRect: null,
    padding: 16
  });

  assert.deepEqual(bounds, {
    left: 84,
    right: 216,
    top: 284,
    bottom: 356
  });
});
