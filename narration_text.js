(() => {
  const WHITESPACE_RE = /\s/;

  function normalizeNarrationText(value) {
    if (typeof value !== "string") return "";
    return value.replace(/[\r\n]/g, " ");
  }

  function isWordLikeChar(char) {
    if (typeof char !== "string" || !char) return false;
    if (/[0-9A-Za-z_]/.test(char)) return true;
    return char.toLowerCase() !== char.toUpperCase();
  }

  function shouldInsertImplicitSpaceChars(previousChar, nextChar) {
    if (typeof previousChar !== "string" || typeof nextChar !== "string") return false;
    if (!previousChar || !nextChar) return false;
    if (WHITESPACE_RE.test(previousChar) || WHITESPACE_RE.test(nextChar)) return false;
    return isWordLikeChar(previousChar) && isWordLikeChar(nextChar);
  }

  function shouldInsertImplicitSpace(previousText, nextText) {
    if (typeof previousText !== "string" || typeof nextText !== "string") return false;
    if (!previousText || !nextText) return false;
    return shouldInsertImplicitSpaceChars(
      previousText.charAt(previousText.length - 1),
      nextText.charAt(0)
    );
  }

  const api = {
    normalizeNarrationText,
    shouldInsertImplicitSpace,
    shouldInsertImplicitSpaceChars
  };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }

  if (typeof globalThis !== "undefined") {
    globalThis.ReedahNarrationText = api;
  }
})();
