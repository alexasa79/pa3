(() => {
  const WORD_BOUNDARY_CLASS = "[\\p{L}\\p{N}_]";
  // Keep these rules aligned with PA3's NarrationPath for native selections.
  const SPELLED_EXTENSIONS = new Set([
    "c", "h", "cc", "hh", "cpp", "hpp", "cxx", "hxx", "js", "ts", "jsx", "tsx", "css", "html", "xml",
    "sql", "csv", "txt", "md", "pdf", "png", "jpg", "svg", "yml", "gz", "rs", "py", "rb", "sh", "mm"
  ]);
  const FILE_EXTENSIONS = new Set([...SPELLED_EXTENSIONS,
    "swift", "m", "go", "java", "kt", "kts", "bash", "zsh", "fish", "json", "yaml", "toml", "ini", "cfg",
    "conf", "log", "rst", "scss", "jpeg", "gif", "webp", "wav", "mp3", "mp4", "zip", "tar", "bz2", "xz"
  ]);

  function pronouncePaths(text) {
    if (typeof text !== "string") throw new Error("Narration text must be a string.");
    // Consume URLs whole so their path components cannot be rewritten separately.
    return text.replace(/[\(\[\{“‘]*(?:[a-z][a-z0-9+.-]*:\/\/|www\.)[^\s"'`<>]+|[^\s"'`<>,;!?]+/giu, (token) => {
      const leading = token.match(/^[([{“‘]*/u)[0];
      const trailing = token.match(/[)\]}.:!?,”’]*$/u)[0];
      const path = token.slice(leading.length, token.length - trailing.length);
      if (!path.includes("/") && !path.includes(".")) return token;
      if (path.includes("://") || /^www\./i.test(path) || !/^[\p{L}\p{M}\p{N}_./~+\-]+$/u.test(path)) return token;
      const components = path.split("/");
      const explicitPath = /^(?:\/|\.\.?\/|~\/)/u.test(path);
      const filename = components.at(-1);
      const suffix = filename.split(".").at(-1).toLowerCase();
      const hasExtension = filename.includes(".") && !filename.startsWith(".") && /^[a-z][a-z0-9]*$/u.test(suffix);
      if (!explicitPath) {
        // Avoid dates/fractions, prose such as and/or, and bare website URLs.
        if (!/\p{L}/u.test(path)) return token;
        if (components.length > 1) {
          if (/^[\p{L}\p{N}-]+(?:\.[\p{L}\p{N}-]+)*\.[a-z]{2,}$/iu.test(components[0]) ||
              (components.length < 3 && !hasExtension)) return token;
        } else if (!hasExtension || filename.includes("..") || !FILE_EXTENSIONS.has(suffix)) return token;
      }
      const spoken = components.map(component => component.split(".").map((part, index) =>
        index > 0 && SPELLED_EXTENSIONS.has(part.toLowerCase()) ? [...part.toUpperCase()].join(" ") : part
      ).join(" dot ")).join(" slash ")
        .replace(/_/g, " underscore ").replace(/-/g, " dash ").replace(/~/g, "tilde")
        .replace(/\s+/gu, " ").trim();
      return leading + spoken + trailing;
    });
  }

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

      const preparedSentence = pronouncePaths(applyCustomVocab(rawSentence, customVocab));
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
    applyCustomVocab,
    pronouncePaths
  };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }

  if (typeof globalThis !== "undefined") {
    globalThis.ReedahNativeRequestBuilder = api;
  }
})();
