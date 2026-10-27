(() => {
  function buildNarrationJobs(text) {
    if (typeof text !== "string") throw new Error("Narration text must be a string.");
    if (text.length > 100000) throw new Error("Text exceeds 100,000 characters.");
    if (!text.trim()) return [];
    // The single transport job preserves paragraph boundaries and UTF-16 offsets.
    // PA3 owns filtering, pronunciation, sentence splitting, and pauses.
    return [{index: 0, location: 0, length: text.length, text}];
  }

  const api = { buildNarrationJobs };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  if (typeof globalThis !== "undefined") globalThis.ReedahNativeRequestBuilder = api;
})();
