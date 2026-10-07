(() => {
  function shouldRunInFrame(win) {
    if (!win) win = window;
    if (win.top === win) return true;
    // Ordinary embedded documents have their own DOM and controls.
    // Keep known authentication/Office shell frames out of narration.
    try {
      return win.location.hostname !== 'oauth.officeapps.live.com' &&
        win.location.hostname !== 'webshell.suite.office.com';
    } catch (error) {
      console.error('Reedah: Unable to inspect frame location.', error);
      return false;
    }
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
