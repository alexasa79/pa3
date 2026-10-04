(function(root) {
  function highlightRange(result, time, mode) {
    if (!Number.isFinite(time) || time < 0) return null;
    let current = -1;
    let previousStart = 0;
    for (const word of result.words) {
      // Keep source order when neighboring timestamp estimates overlap or reverse.
      const start = Math.max(previousStart, word.start);
      previousStart = start;
      if (start > time) break;
      current = word.index;
    }
    if (current < 0) return null;
    const starts = result.sentence_starts;
    let sentence = 0;
    while (sentence + 1 < starts.length && starts[sentence + 1] <= current) sentence++;
    const lower = starts[sentence];
    const upper = starts[sentence + 1] ?? result.reference_words;
    if (mode === 'sentence') return [lower, upper];
    const width = Math.min(Number(mode), upper - lower);
    if (!Number.isInteger(width) || width < 1) return null;
    const first = Math.max(lower, Math.min(current - Math.floor((width - 1) / 2), upper - width));
    return [first, first + width];
  }
  if (typeof module !== 'undefined' && module.exports) module.exports = {highlightRange};
  else root.highlightRange = highlightRange;
})(globalThis);
