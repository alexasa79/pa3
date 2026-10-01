(() => {
  const WORD_BOUNDARY_CLASS = "[\\p{L}\\p{N}_]";
  const PATH_PAUSE_BOUNDARIES = ",;:.!?\"'`”’)]}";
  // Consume URLs whole so their components cannot be rewritten separately.
  const CODE_TOKENS = /[\(\[\{“‘]*(?:[a-z][a-z0-9+.-]*:\/\/|www\.)[^\s"'`<>]+|[^\s"'`<>,;!?]+/giu;
  // Keep aligned with PA3's NarrationIdentifier.
  const IDENTIFIER_LETTER_NAMES = {
    a: "ay", b: "bee", c: "see", d: "dee", e: "ee", f: "ef",
    g: "jee", h: "aitch", i: "eye", j: "jay", k: "kay", l: "ell",
    m: "em", n: "en", o: "oh", p: "pee", q: "cue", r: "ar",
    s: "ess", t: "tee", u: "you", v: "vee", w: "double you",
    x: "ex", y: "why", z: "zee"
  };
  // Keep this catalog aligned with PA3's NarrationPath for native selections.
  // The full list and pronunciation policy are documented in ../FileExtensions.md.
  const SPELLED_EXTENSIONS = new Set([
    // Shell and command scripts
    "sh", "zsh", "ksh", "csh", "ps1", "psm1", "psd1", "cmd",
    // C, C++, Objective-C, and CUDA
    "c", "h", "cc", "hh", "cpp", "hpp", "cxx", "hxx", "c++", "h++", "inl",
    "ipp", "tcc", "ixx", "cppm", "m", "mm", "cu", "cuh",
    // Python and notebooks
    "py", "pyi", "pyw", "pyc", "pyo", "ipynb", "whl",
    // JavaScript, TypeScript, and web
    "js", "mjs", "cjs", "jsx", "ts", "mts", "cts", "tsx", "html", "htm", "xhtml",
    "css", "scss", "gql",
    // Other programming languages
    "rs", "kt", "kts", "cs", "csx", "csproj", "sln", "fs", "fsx", "vb", "vbs",
    "rb", "php", "pl", "pm", "r", "rmd", "jl", "ex", "exs", "erl", "hrl",
    "hs", "ml", "mli", "clj", "cljs", "d",
    // Configuration, build files, and data
    "yml", "cfg", "mk", "sql", "csv", "tsv", "xml", "xsd", "xsl", "xslt", "db",
    // Word documents and templates
    "doc", "docx", "docm", "dot", "dotx", "dotm",
    // Excel workbooks, templates, and add-ins
    "xls", "xlsx", "xlsm", "xlsb", "xlt", "xltx", "xltm", "xla", "xlam", "xlw",
    // PowerPoint presentations, shows, templates, and add-ins
    "ppt", "pptx", "pptm", "pps", "ppsx", "ppsm", "pot", "potx", "potm", "ppa", "ppam",
    "sldx", "sldm", "thmx",
    // Other Microsoft Office files
    "mdb", "mde", "accdb", "accde", "accdt", "pst", "ost", "msg", "oft", "vsd", "vsdx",
    "vss", "vssx", "vst", "vstx", "mpp", "mpt", "pub",
    // Documents, books, and other office suites
    "txt", "md", "rst", "rtf", "pdf", "ps", "eps", "odt", "ods", "odp", "odg",
    "ott", "ots", "otp", "xps",
    // Images and graphics
    "png", "jpg", "svg", "bmp", "tif", "ico", "psd", "ai",
    // Audio and video
    "mp3", "mp4", "m4a", "m4v", "aac", "mkv", "avi", "mpg", "wma", "wmv",
    // Archives and compression
    "gz", "tgz", "bz2", "tbz2", "xz", "txz", "zst", "7z", "lz4",
    // Applications, packages, and compiled files
    "dmg", "pkg", "iso", "rpm", "msi", "dll", "so", "a", "o", "pdb", "apk",
    // Fonts and certificates
    "ttf", "otf", "woff2", "eot", "pem", "crt", "cer", "csr", "p12", "pfx"
  ]);
  const FILE_EXTENSIONS = new Set([...SPELLED_EXTENSIONS,
    // Shell and command scripts
    "bash", "fish", "bat",
    // Go
    "go", "mod", "sum",
    // JavaScript, TypeScript, and web
    "sass", "less", "vue", "svelte", "wasm", "graphql",
    // Other programming languages
    "swift", "java", "class", "jar", "scala", "ruby", "rake", "gem", "lua", "dart", "zig",
    // Configuration, build files, and data
    "json", "jsonc", "jsonl", "ndjson", "yaml", "toml", "ini", "conf", "properties", "env", "lock",
    "cmake", "proto", "sqlite", "sqlite3", "parquet", "avro", "arrow", "log", "patch", "diff",
    // Other Microsoft Office files
    "one", "onepkg",
    // Documents, books, and other office suites
    "markdown", "tex", "bib", "adoc", "epub", "mobi", "pages", "numbers", "key",
    // Images and graphics
    "jpeg", "gif", "webp", "avif", "tiff", "heic",
    // Audio and video
    "wav", "flac", "ogg", "opus", "aif", "aiff", "mov", "webm", "mpeg",
    // Archives and compression
    "zip", "tar", "rar",
    // Applications, packages, and compiled files
    "deb", "exe", "dylib", "obj", "lib", "bin", "app",
    // Fonts and certificates
    "woff"
  ]);
  const SPOKEN_CHARACTERS = {
    "0": "zero", "1": "one", "2": "two", "3": "three", "4": "four",
    "5": "five", "6": "six", "7": "seven", "8": "eight", "9": "nine", "+": "plus"
  };
  const MATH_COMPARISONS = {
    "≥": "is greater than or equal to", "≤": "is less than or equal to",
    "≠": "is not equal to", "≈": "is approximately equal to"
  };

  function pronounceMathComparisons(text) {
    // Expand only for speech, after sentence segmentation. The job's original
    // location and length continue to refer to the displayed symbols.
    return text.replace(/[ \t]*([≥≤≠≈])[ \t]*/gu,
      (_, symbol) => ` ${MATH_COMPARISONS[symbol]} `);
  }

  function pronouncePaths(text) {
    if (typeof text !== "string") throw new Error("Narration text must be a string.");
    return text.replace(CODE_TOKENS, (token, offset) => {
      const leading = token.match(/^[([{“‘]*/u)[0];
      const trailing = token.match(/[)\]}.:!?,”’]*$/u)[0];
      let path = token.slice(leading.length, token.length - trailing.length);
      if (!path.includes("/") && !path.includes(".")) return token;
      if (path.includes("://") || /^www\./i.test(path)) return token;
      // Parse compiler/editor locations before validating the path itself.
      const reference = path.match(/:([0-9]+)(?:-([0-9]+)|:([0-9]+))?$/u);
      let location = "";
      if (reference) {
        location = reference[2] == null ? `, line ${reference[1]}` : `, lines ${reference[1]} to ${reference[2]}`;
        if (reference[3] != null) location += `, column ${reference[3]}`;
        path = path.slice(0, reference.index);
      }
      if (!/^[\p{L}\p{M}\p{N}_./~+\-]+$/u.test(path)) return token;
      const components = path.split("/");
      const explicitPath = /^(?:\/|\.\.?\/|~\/)/u.test(path);
      const filename = components.at(-1);
      const suffix = filename.split(".").at(-1).toLowerCase();
      const hasExtension = filename.includes(".") && !filename.startsWith(".") &&
        (FILE_EXTENSIONS.has(suffix) || /^[a-z][a-z0-9]*$/u.test(suffix));
      if (!explicitPath) {
        // Avoid dates/fractions, prose such as and/or, and bare website URLs.
        if (!/\p{L}/u.test(path)) return token;
        if (components.length > 1) {
          if (/^[\p{L}\p{N}-]+(?:\.[\p{L}\p{N}-]+)*\.[a-z]{2,}$/iu.test(components[0]) ||
              (components.length < 3 && !hasExtension)) return token;
        } else if (!hasExtension || filename.includes("..") || !FILE_EXTENSIONS.has(suffix)) return token;
      }
      const spoken = components.map(component => component.split(".").map((part, index) =>
        index > 0 && SPELLED_EXTENSIONS.has(part.toLowerCase()) ? [...part.toUpperCase()].map(ch => SPOKEN_CHARACTERS[ch] ?? ch).join(" ") : part
      ).join(" dot ")).join(" slash ")
        .replace(/_/g, " underscore ").replace(/-/g, " dash ").replace(/~/g, "tilde")
        .replace(/\s+/gu, " ").trim();
      const following = text[offset + token.length];
      const hasPause = [...trailing].some(ch => PATH_PAUSE_BOUNDARIES.includes(ch)) ||
        (following != null && PATH_PAUSE_BOUNDARIES.includes(following));
      return leading + spoken + location + trailing + (location && !hasPause ? "," : "");
    });
  }

  function pronounceIdentifiers(text) {
    if (typeof text !== "string") throw new Error("Narration text must be a string.");
    return text.replace(CODE_TOKENS, token => {
      if (!token.includes("_")) return token;
      const body = token.replace(/[)\]}.:!?,”’]*$/u, "");
      // Paths are handled separately; leave URLs, email, and dotted names intact.
      if (/[/.@]/u.test(body)) return token;
      return token.replace(/[\p{L}\p{M}\p{N}_]+/gu, name => {
        if (!name.includes("_") || !/^[\p{L}_]/u.test(name) || !/\p{L}/u.test(name)) return name;
        return name.split("_").map(part => Object.hasOwn(IDENTIFIER_LETTER_NAMES, part.toLowerCase())
          ? IDENTIFIER_LETTER_NAMES[part.toLowerCase()] : part)
          .join(" underscore ").replace(/\s+/gu, " ").trim();
      });
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

    const narrationText = typeof module !== "undefined" && module.exports
      ? require("./narration_text") : globalThis.ReedahNarrationText;
    // Filter the whole source: a parenthesized aside may cross sentence ranges.
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

      const preparedSentence = pronounceMathComparisons(
        pronounceIdentifiers(pronouncePaths(applyCustomVocab(rawSentence, customVocab)))
      );
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
    pronouncePaths,
    pronounceIdentifiers
  };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }

  if (typeof globalThis !== "undefined") {
    globalThis.ReedahNativeRequestBuilder = api;
  }
})();
