(() => {
  function normalizeNarrationText(value) {
    if (typeof value !== "string") return "";
    return value.replace(/[\r\n]/g, " ");
  }

  const api = {
    normalizeNarrationText
  };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }

  if (typeof globalThis !== "undefined") {
    globalThis.ReedahNarrationText = api;
  }
})();
