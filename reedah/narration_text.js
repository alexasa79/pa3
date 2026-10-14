(() => {
  function isParenthesizedCodeReference(value) {
    value = value.trim();
    if (value.startsWith("`") && value.endsWith("`") && value.length >= 2) {
      value = value.slice(1, -1);
    }
    if (!/^(?:[A-Za-z]:[\\/])?[\p{L}\p{N}_@~.+/\\-]+:[0-9]+(?:-[0-9]+)?(?::[0-9]+)?$/u.test(value)) return false;
    return /[/\\]/u.test(value) || /\.[\p{L}_][\p{L}\p{N}_-]*:/u.test(value) ||
      ["Makefile", "Dockerfile", "Gemfile", "Rakefile", "Procfile"].includes(value.split(":")[0]);
  }

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
        if (depth === 0 && i > start + 1 && isParenthesizedCodeReference(text.slice(start + 1, i))) {
          units.fill(" ", start, i + 1);
        }
      }
    }
    return units.join("");
  }

  function normalizeNarrationText(value) {
    if (typeof value !== "string") return "";
    return value.replace(/[\r\n]/g, " ");
  }

  function shouldSkipSuperscript(value) {
    return typeof value === "string" && /^\S+$/.test(value.trim());
  }

  const api = {
    normalizeNarrationText,
    shouldSkipSuperscript,
    maskParentheses,
    isParenthesizedCodeReference
  };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }

  if (typeof globalThis !== "undefined") {
    globalThis.ReedahNarrationText = api;
  }
})();
