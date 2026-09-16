(() => {
  const WORD_BOUNDARY_CLASS = "[\\p{L}\\p{N}_]";

  function buildSentenceJobs(text, sentenceRanges, customVocab) {
    if (typeof text !== "string") {
      throw new Error("Narration text must be a string.");
    }
    if (!Array.isArray(sentenceRanges)) {
      throw new Error("Sentence ranges must be an array.");
    }
    if (!Array.isArray(customVocab)) {
      throw new Error("Custom vocabulary must be an array.");
    }

    const maxLength = text.length;
    const jobs = [];
    for (let index = 0; index < sentenceRanges.length; index += 1) {
      const entry = sentenceRanges[index];
      if (!entry || typeof entry !== "object") {
        throw new Error(`sentenceRanges[${index}] must be an object.`);
      }
      if (!Number.isInteger(entry.start) || !Number.isInteger(entry.end)) {
        throw new Error(`sentenceRanges[${index}] must include integer start/end.`);
      }

      const start = Math.min(Math.max(entry.start, 0), maxLength);
      const end = Math.min(Math.max(entry.end, start), maxLength);
      const length = end - start;
      if (length <= 0) {
        continue;
      }

      const rawSentence = text.slice(start, end);
      if (!rawSentence.trim()) {
        continue;
      }

      const preparedSentence = applyCustomVocab(rawSentence, customVocab);
      jobs.push({
        index,
        location: start,
        length,
        text: preparedSentence
      });
    }

    return jobs;
  }

  function applyCustomVocab(text, customVocab) {
    if (typeof text !== "string") {
      throw new Error("Narration sentence text must be a string.");
    }
    if (!Array.isArray(customVocab) || customVocab.length === 0) {
      return text;
    }

    const spellings = [...new Set(customVocab.map((entry) => entry.spelling))]
      .sort((a, b) => b.length - a.length);
    if (spellings.length === 0) {
      return text;
    }

    const pronunciationBySpelling = new Map();
    for (const entry of customVocab) {
      pronunciationBySpelling.set(entry.spelling.toLocaleLowerCase(), entry.pronunciation);
    }

    const alternatives = spellings.map(escapeRegex).join("|");
    const matcher = new RegExp(
      `(?<!${WORD_BOUNDARY_CLASS})(${alternatives})(?!${WORD_BOUNDARY_CLASS})`,
      "giu"
    );
    return text.replace(matcher, (matchedSpelling) => {
      const pronunciation = pronunciationBySpelling.get(matchedSpelling.toLocaleLowerCase());
      if (typeof pronunciation !== "string" || !pronunciation) {
        throw new Error(`Missing pronunciation mapping for '${matchedSpelling}'.`);
      }
      return pronunciation;
    });
  }

  function escapeRegex(value) {
    return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  }

  const api = {
    buildSentenceJobs,
    applyCustomVocab
  };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }

  if (typeof globalThis !== "undefined") {
    globalThis.ReedahNativeRequestBuilder = api;
  }
})();
