(() => {
  function toFinite(value, fallback) {
    return Number.isFinite(value) ? value : fallback;
  }

  function computeOverlayLeft(options = {}) {
    const anchorRect = options.anchorRect || {};
    const overlayWidth = toFinite(options.overlayWidth, 14);
    const overlayOffset = toFinite(options.overlayOffset, 8);
    const listOverlayMaxGap = toFinite(options.listOverlayMaxGap, 32);
    const viewportPadding = toFinite(options.viewportPadding, 8);

    const anchorLeft = toFinite(anchorRect.left, 0);
    const anchorRight = toFinite(anchorRect.right, anchorLeft);
    const maxLeft = anchorLeft - overlayOffset - overlayWidth;
    let left = maxLeft;

    if (options.isListItem) {
      const listRect = options.listRect || {};
      const listLeft = toFinite(listRect.left, anchorLeft) - overlayOffset - overlayWidth;
      const cappedLeft = anchorLeft - overlayWidth - listOverlayMaxGap;
      left = Math.min(maxLeft, Math.max(listLeft, cappedLeft));
    }

    if (left < viewportPadding) {
      left = anchorRight + overlayOffset;
    }

    return left;
  }

  function computeOverlayPosition(options = {}) {
    const anchorRect = options.anchorRect || {};
    return {
      left: computeOverlayLeft(options),
      top: toFinite(anchorRect.top, 0)
    };
  }

  function computeOverlayRect(options = {}) {
    const overlayWidth = toFinite(options.overlayWidth, 14);
    const overlayHeight = toFinite(options.overlayHeight, overlayWidth);
    const position = computeOverlayPosition(options);
    return {
      left: position.left,
      right: position.left + overlayWidth,
      top: position.top,
      bottom: position.top + overlayHeight
    };
  }

  const api = {
    computeOverlayLeft,
    computeOverlayPosition,
    computeOverlayRect
  };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }

  if (typeof globalThis !== "undefined") {
    globalThis.ReedahOverlayGeometry = api;
  }
})();
