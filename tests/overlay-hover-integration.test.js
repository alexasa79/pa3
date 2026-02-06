const assert = require("node:assert/strict");
const test = require("node:test");
const { computeOverlayRect } = require("../overlay_geometry");
const { computeHoverBounds } = require("../hover_bounds");

function isPointInside(pointX, pointY, bounds) {
  return pointX >= bounds.left &&
    pointX <= bounds.right &&
    pointY >= bounds.top &&
    pointY <= bounds.bottom;
}

test("ordered-list overlay position always stays within hover bounds", () => {
  const padding = 32;
  for (let targetLeft = 20; targetLeft <= 620; targetLeft += 40) {
    for (let gutter = 24; gutter <= 80; gutter += 8) {
      for (let anchorInset = 0; anchorInset <= 48; anchorInset += 12) {
        const targetRect = {
          left: targetLeft,
          right: targetLeft + 260,
          top: 120,
          bottom: 156
        };
        const anchorRect = {
          left: targetRect.left + anchorInset,
          right: targetRect.left + anchorInset + 1,
          top: targetRect.top,
          bottom: targetRect.top + 1
        };
        const listRect = {
          left: targetRect.left - gutter,
          right: targetRect.right
        };

        const overlayRect = computeOverlayRect({
          anchorRect,
          overlayWidth: 18,
          overlayHeight: 18,
          overlayOffset: 8,
          isListItem: true,
          listRect,
          listOverlayMaxGap: 32,
          viewportPadding: 8
        });
        const bounds = computeHoverBounds({
          targetRect,
          overlayRect,
          padding
        });

        const centerX = (overlayRect.left + overlayRect.right) / 2;
        const centerY = (overlayRect.top + overlayRect.bottom) / 2;
        assert.ok(
          isPointInside(centerX, centerY, bounds),
          `Overlay center escaped hover bounds for targetLeft=${targetLeft}, gutter=${gutter}, anchorInset=${anchorInset}`
        );
      }
    }
  }
});

test("cursor path from anchor to overlay remains inside hover bounds", () => {
  const targetRect = {
    left: 120,
    right: 360,
    top: 200,
    bottom: 240
  };
  const anchorRect = {
    left: 140,
    right: 141,
    top: 200,
    bottom: 201
  };
  const listRect = {
    left: 72,
    right: 360
  };

  const overlayRect = computeOverlayRect({
    anchorRect,
    overlayWidth: 18,
    overlayHeight: 18,
    overlayOffset: 8,
    isListItem: true,
    listRect,
    listOverlayMaxGap: 32,
    viewportPadding: 8
  });
  const bounds = computeHoverBounds({
    targetRect,
    overlayRect,
    padding: 32
  });

  const targetX = anchorRect.left;
  const targetY = (overlayRect.top + overlayRect.bottom) / 2;
  const overlayX = (overlayRect.left + overlayRect.right) / 2;
  const overlayY = targetY;

  for (let step = 0; step <= 20; step += 1) {
    const ratio = step / 20;
    const pointX = targetX + (overlayX - targetX) * ratio;
    const pointY = targetY + (overlayY - targetY) * ratio;
    assert.ok(
      isPointInside(pointX, pointY, bounds),
      `Cursor path left hover bounds at step=${step}`
    );
  }
});
