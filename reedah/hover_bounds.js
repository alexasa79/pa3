(() => {
  function toFinite(value, fallback) {
    return Number.isFinite(value) ? value : fallback;
  }

  function rectToBounds(rect, padding) {
    const source = rect || {};
    return {
      left: toFinite(source.left, 0) - padding,
      right: toFinite(source.right, 0) + padding,
      top: toFinite(source.top, 0) - padding,
      bottom: toFinite(source.bottom, 0) + padding
    };
  }

  function mergeBounds(a, b) {
    return {
      left: Math.min(a.left, b.left),
      right: Math.max(a.right, b.right),
      top: Math.min(a.top, b.top),
      bottom: Math.max(a.bottom, b.bottom)
    };
  }

  function computeHoverBounds(options = {}) {
    const padding = toFinite(options.padding, 32);
    const targetBounds = rectToBounds(options.targetRect, padding);
    if (!options.overlayRect) {
      return targetBounds;
    }

    const overlayBounds = rectToBounds(options.overlayRect, padding);
    return mergeBounds(targetBounds, overlayBounds);
  }

  const api = { computeHoverBounds };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }

  if (typeof globalThis !== "undefined") {
    globalThis.ReedahHoverBounds = api;
  }
})();
