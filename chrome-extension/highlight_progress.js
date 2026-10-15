(() => {
  function clamp(value, min, max) {
    return Math.max(min, Math.min(max, value));
  }

  function computeFocusStops(spanStart, spanEnd, progress, width = 0.5) {
    if (!Number.isFinite(spanStart) || !Number.isFinite(spanEnd)) return null;
    if (!Number.isFinite(progress) || !Number.isFinite(width)) return null;
    if (spanEnd <= spanStart) return null;
    if (width <= 0) return null;

    const localRange = spanEnd - spanStart;
    const localCenter = (progress - spanStart) / localRange;
    const localHalfWidth = (width * 0.5) / localRange;
    const localStart = localCenter - localHalfWidth;
    const localEnd = localCenter + localHalfWidth;

    if (localEnd <= 0 || localStart >= 1) return null;

    const start = clamp(localStart, 0, 1);
    const center = clamp(localCenter, 0, 1);
    const end = clamp(localEnd, 0, 1);
    const centerSafe = clamp(center, start, end);

    return {
      startPercent: start * 100,
      centerPercent: centerSafe * 100,
      endPercent: end * 100
    };
  }

  function computeWordFocusStrength(
    wordStart,
    wordEnd,
    focusStart,
    focusEnd,
    edgeSize = 8
  ) {
    if (!Number.isFinite(wordStart) ||
      !Number.isFinite(wordEnd) ||
      !Number.isFinite(focusStart) ||
      !Number.isFinite(focusEnd)) {
      return null;
    }
    if (!Number.isFinite(edgeSize)) return null;
    if (wordEnd <= wordStart) return null;
    if (focusEnd <= focusStart) return null;
    if (edgeSize < 0) return null;

    if (wordEnd > focusStart && wordStart < focusEnd) {
      return 1;
    }
    if (edgeSize === 0) return 0;

    const distance = wordEnd <= focusStart
      ? focusStart - wordEnd
      : wordStart - focusEnd;
    if (!Number.isFinite(distance) || distance < 0) {
      return null;
    }
    if (distance >= edgeSize) {
      return 0;
    }

    const t = 1 - (distance / edgeSize);
    return t * t;
  }

  const api = { computeFocusStops, computeWordFocusStrength };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }

  if (typeof globalThis !== "undefined") {
    globalThis.ReedahHighlightProgress = api;
  }
})();
