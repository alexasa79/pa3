(() => {
  // Use UTF-16 code units so source positions survive emoji and nested groups.
  function maskParentheses(text) {
    const units = text.split("");
    let depth = 0, start = 0;
    for (let i = 0; i < units.length; i += 1) {
      if (units[i] === "(") {
        if (depth === 0) start = i;
        depth += 1;
      } else if (units[i] === ")" && depth > 0) {
        depth -= 1;
        // Empty function-call parentheses contain nothing to omit.
        if (depth === 0 && i > start + 1) units.fill(" ", start, i + 1);
      }
    }
    return units.join("");
  }

  function normalizeNarrationText(value) {
    if (typeof value !== "string") return "";
    return value.replace(/[\r\n]/g, " ");
  }

  const api = {
    normalizeNarrationText,
    maskParentheses
  };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }

  if (typeof globalThis !== "undefined") {
    globalThis.ReedahNarrationText = api;
  }
})();
