(() => {
  function computeHighlightSlices(segments, start, end) {
    if (!Array.isArray(segments)) return [];
    if (!Number.isFinite(start) || !Number.isFinite(end)) return [];
    if (end <= start) return [];

    const slices = [];
    for (const segment of segments) {
      if (!segment || !Number.isFinite(segment.start) || !Number.isFinite(segment.end)) {
        continue;
      }
      if (segment.end <= start) continue;
      if (segment.start >= end) break;

      const startOffset = Math.max(start, segment.start) - segment.start;
      const endOffset = Math.min(end, segment.end) - segment.start;
      if (endOffset <= startOffset) continue;

      slices.push({
        segment,
        startOffset,
        endOffset
      });
    }

    return slices;
  }

  const api = { computeHighlightSlices };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }

  if (typeof globalThis !== "undefined") {
    globalThis.ReedahHighlightRanges = api;
  }
})();
