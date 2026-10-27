(() => {
  // Browser navigation/highlighting only. PA3 determines speech boundaries.
  const DEFAULT_MIN_SENTENCE_LENGTH = 20;
  const DEFAULT_ABBREVIATIONS = ["e.g.", "i.e.", "Mr."];
  const SENTENCE_CLOSERS = "\"'”’»›)]}";
  // Exactly two dots between range endpoints, with optional surrounding spaces.
  // Three dots remain an ellipsis. Keep offsets into the original text unchanged.
  const RANGE_OPERATOR = /(?<=[\p{L}\p{N}_)\]}])[ \t]*\.\.[ \t]*(?=[+\-−]?[\p{L}\p{N}_(\[{])/gu;

  function normalizeOptions(options = {}) {
    const abbreviations = Array.isArray(options.abbreviations)
      ? options.abbreviations
      : DEFAULT_ABBREVIATIONS;
    const minSentenceLength = Number.isFinite(options.minSentenceLength)
      ? options.minSentenceLength
      : DEFAULT_MIN_SENTENCE_LENGTH;

    return {
      abbreviations,
      minSentenceLength
    };
  }

  function buildSentenceRanges(fullText, options = {}) {
    if (!fullText) return [];
    const narrationText = typeof module !== "undefined" && module.exports
      ? require("./narration_text") : globalThis.ReedahNarrationText;
    fullText = narrationText.maskParentheses(fullText);

    const { abbreviations, minSentenceLength } = normalizeOptions(options);
    const ranges = [];
    let start = 0;
    const len = fullText.length;
    const isDelimiter = (ch) => ch === "." || ch === "!" || ch === "?";
    const isCloser = (ch) => SENTENCE_CLOSERS.includes(ch);
    const rangePeriods = new Set();
    for (const match of fullText.matchAll(RANGE_OPERATOR)) {
      const firstDot = fullText.indexOf(".", match.index);
      rangePeriods.add(firstDot);
      rangePeriods.add(firstDot + 1);
    }
    const abbrevRanges = buildAbbreviationRanges(fullText, abbreviations);
    let abbrevIndex = 0;

    for (let i = 0; i < len; i += 1) {
      if (isDelimiter(fullText[i])) {
        if (rangePeriods.has(i)) continue;
        while (abbrevIndex < abbrevRanges.length && i > abbrevRanges[abbrevIndex].end) {
          abbrevIndex += 1;
        }
        const inAbbrev = abbrevIndex < abbrevRanges.length &&
          i >= abbrevRanges[abbrevIndex].start &&
          i <= abbrevRanges[abbrevIndex].end;

        const inNumber = fullText[i] === "." &&
          i > 0 &&
          i + 1 < len &&
          /\d/.test(fullText[i - 1]) &&
          /\d/.test(fullText[i + 1]);

        const midWord = fullText[i] === "." &&
          i > 0 &&
          i + 1 < len &&
          !/[\s.!?]/.test(fullText[i - 1]) &&
          !/[\s.!?]/.test(fullText[i + 1]) &&
          !isCloser(fullText[i - 1]) && !isCloser(fullText[i + 1]);

        const inAcronym = fullText[i] === "." &&
          i >= 2 &&
          /[A-Za-z]/.test(fullText[i - 1]) &&
          fullText[i - 2] === "." && !rangePeriods.has(i - 2);

        if (fullText[i] === "." && (inAbbrev || inNumber || midWord || inAcronym)) {
          continue;
        }
        let end = i + 1;
        while (end < len && (isDelimiter(fullText[end]) || isCloser(fullText[end]))) {
          end += 1;
        }
        ranges.push({ start, end });
        start = end;
        i = end - 1;
      }
    }

    if (start < len) {
      ranges.push({ start, end: len });
    }

    const sentences = [];
    for (const range of ranges) {
      let sStart = range.start;
      let sEnd = range.end;
      while (sStart < sEnd && /\s/.test(fullText[sStart])) sStart += 1;
      while (sEnd > sStart && /\s/.test(fullText[sEnd - 1])) sEnd -= 1;
      if (sEnd <= sStart) continue;
      const raw = fullText.slice(sStart, sEnd);
      const text = raw.replace(/\s+/g, " ").trim();
      if (!text) continue;
      sentences.push({ start: sStart, end: sEnd, length: text.length });
    }

    return mergeShortSentences(sentences, fullText, minSentenceLength);
  }

  function buildAbbreviationRanges(fullText, abbreviations) {
    if (!abbreviations.length) return [];
    const lower = fullText.toLowerCase();
    const ranges = [];

    for (const abbr of abbreviations) {
      const needle = abbr.toLowerCase();
      let index = 0;
      while (index < lower.length) {
        const found = lower.indexOf(needle, index);
        if (found === -1) break;
        ranges.push({ start: found, end: found + needle.length - 1 });
        index = found + needle.length;
      }
    }

    ranges.sort((a, b) => a.start - b.start);
    return ranges;
  }

  function mergeShortSentences(sentences, fullText, minLength) {
    if (!sentences.length) return sentences;

    const merged = sentences.map((sentence) => ({ ...sentence }));

    const normalize = (index) => {
      const item = merged[index];
      if (!item) return;
      item.length = getSentenceLength(fullText, item.start, item.end);
    };

    for (let i = 0; i < merged.length; i += 1) {
      const current = merged[i];
      if (!current) continue;
      if (current.length >= minLength) continue;

      if (i === 0) {
        const next = merged[i + 1];
        if (next) {
          next.start = current.start;
          merged.splice(i, 1);
          normalize(i);
          i -= 1;
        }
        continue;
      }

      const previous = merged[i - 1];
      if (previous) {
        previous.end = current.end;
        merged.splice(i, 1);
        normalize(i - 1);
        i -= 1;
      }
    }

    return merged.map(({ start, end }) => ({ start, end }));
  }

  function getSentenceLength(fullText, start, end) {
    const raw = fullText.slice(start, end);
    return raw.replace(/\s+/g, " ").trim().length;
  }

  // Navigation stays in the browser. The full source is one transport stream;
  // PA3 alone determines model requests and pauses, including paragraph gaps.
  function buildTransportRanges(text) {
    return text && text.trim() ? [{start: 0, end: text.length}] : [];
  }
  // Playback passages are transport units, not sentence navigation boundaries.
  function buildNavigationTargets(text, passages) {
    return buildSentenceRanges(text, {minSentenceLength:0}).flatMap(range => {
      const passageIndex = passages.findIndex(passage => passage.end > range.start && passage.start < range.end);
      return passageIndex < 0 ? [] : [{...range, passageIndex}];
    });
  }
  const api = { buildSentenceRanges, buildTransportRanges, buildNavigationTargets };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }

  if (typeof globalThis !== "undefined") {
    globalThis.ReedahSentence = api;
  }
})();
