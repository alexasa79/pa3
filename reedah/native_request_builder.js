(() => {
  function buildSentenceJobs(text, sentenceRanges) {
    if (typeof text !== "string") {
      throw new Error("Narration text must be a string.");
    }
    if (!Array.isArray(sentenceRanges)) {
      throw new Error("Sentence ranges must be an array.");
    }

    const narrationText = typeof module !== "undefined" && module.exports
      ? require("./narration_text") : globalThis.ReedahNarrationText;
    // Filter the whole source: a parenthesized code reference may cross supplied sentence ranges.
    const filtered = narrationText.maskParentheses(text);
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

      let rawSentence = filtered.slice(start, end);
      if (rawSentence !== text.slice(start, end)) {
        rawSentence = rawSentence.replace(/[ \t]{2,}(?=[,.;:!?])/gu, "")
          .replace(/\s+/gu, " ").trim();
        if (/^[\s\p{P}]*$/u.test(rawSentence)) continue;
      }
      if (!rawSentence.trim()) {
        continue;
      }

      // PA3 applies its shared dictionary before filename/identifier/math pronunciation.
      jobs.push({
        index,
        location: start,
        length,
        text: rawSentence
      });
    }

    return jobs;
  }

  const api = { buildSentenceJobs };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  if (typeof globalThis !== "undefined") globalThis.ReedahNativeRequestBuilder = api;
})();
