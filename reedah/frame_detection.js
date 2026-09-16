(() => {
  function shouldRunInFrame(win) {
    if (!win) win = window;
    if (win.top === win) return true;
    return isEditorFrame(win);
  }

  function isEditorFrame(win) {
    if (!win) win = window;
    if (win.top === win) return false;

    try {
      const hostname = win.location.hostname;
      if (!hostname.endsWith(".officeapps.live.com")) return false;
      if (hostname.startsWith("oauth.")) return false;
      return true;
    } catch (error) {
      return false;
    }
  }

  const api = { shouldRunInFrame, isEditorFrame };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }

  if (typeof globalThis !== "undefined") {
    globalThis.ReedahFrameDetection = api;
  }
})();
