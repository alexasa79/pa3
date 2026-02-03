const NATIVE_HOST_NAME = "com.reedah.sayer";

chrome.commands.onCommand.addListener((command) => {
  if (command !== "toggle-overlay") return;

  chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
    const tab = tabs && tabs[0];
    if (!tab || !tab.id) return;
    chrome.tabs.sendMessage(tab.id, { type: "reedah-toggle" }, () => {
      if (chrome.runtime.lastError) {
        // No content script on this page (e.g., chrome://, extensions page).
        return;
      }
    });
  });
});

chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== "reedah-native") return;

  let nativePort = null;
  let closing = false;

  const attachNativeHandlers = () => {
    if (!nativePort) return;

    nativePort.onMessage.addListener((message) => {
      if (!message || typeof message.event !== "string") return;

      if (message.event === "started") {
        port.postMessage({
          type: "started",
          utteranceId: message.utteranceId || null,
          voiceName: message.voiceName || null,
          voiceIdentifier: message.voiceIdentifier || null
        });
        return;
      }

      if (message.event === "range") {
        port.postMessage({
          type: "range",
          utteranceId: message.utteranceId || null,
          location: message.location,
          length: message.length
        });
        return;
      }

      if (message.event === "audio") {
        port.postMessage({
          type: "audio",
          utteranceId: message.utteranceId || null,
          index: message.index,
          audioBase64: message.audioBase64,
          mimeType: message.mimeType || "audio/mp4",
          location: message.location,
          length: message.length
        });
        return;
      }

      if (message.event === "finished") {
        port.postMessage({
          type: "end",
          utteranceId: message.utteranceId || null
        });
        return;
      }

      if (message.event === "cancelled") {
        port.postMessage({
          type: "cancelled",
          utteranceId: message.utteranceId || null
        });
        return;
      }

      if (message.event === "error") {
        port.postMessage({
          type: "error",
          utteranceId: message.utteranceId || null,
          error: message.message || "native_error"
        });
      }
    });

    nativePort.onDisconnect.addListener(() => {
      const lastError = chrome.runtime.lastError;
      if (!closing && lastError) {
        console.error("Reedah: Native host disconnected.", lastError.message);
        port.postMessage({
          type: "error",
          error: lastError.message || "native_disconnected"
        });
      }
      nativePort = null;
    });
  };

  const ensureNativePort = () => {
    if (nativePort) return nativePort;
    try {
      nativePort = chrome.runtime.connectNative(NATIVE_HOST_NAME);
    } catch (error) {
      console.error("Reedah: Unable to connect to native host.", error);
      port.postMessage({ type: "error", error: "native_connect_failed" });
      return null;
    }
    attachNativeHandlers();
    return nativePort;
  };

  port.onMessage.addListener(async (message) => {
    if (!message || typeof message.type !== "string") return;

    if (message.type === "stop") {
      closing = true;
      if (nativePort) {
        try {
          nativePort.postMessage({
            action: "stop",
            utteranceId: message.utteranceId || null
          });
        } catch (error) {
          console.error("Reedah: Failed to stop native narration.", error);
        }
      }
      return;
    }

    if (message.type !== "start") return;

    const text = typeof message.text === "string" ? message.text.trim() : "";
    const sentenceRanges = Array.isArray(message.sentenceRanges)
      ? message.sentenceRanges
      : null;
    if (!text) {
      port.postMessage({ type: "error", error: "empty_text" });
      return;
    }
    if (!sentenceRanges || sentenceRanges.length === 0) {
      port.postMessage({ type: "error", error: "missing_sentence_ranges" });
      return;
    }

    const utteranceId = message.utteranceId || `${Date.now()}`;
    const settings = await getSettings();
    const hostPort = ensureNativePort();
    if (!hostPort) return;

    closing = false;

    const payload = {
      action: "speak",
      text,
      utteranceId,
      sentenceRanges
    };

    if (settings.voice) {
      payload.voice = settings.voice;
    }
    if (settings.rate != null) {
      payload.rate = settings.rate;
    }

    try {
      hostPort.postMessage(payload);
    } catch (error) {
      console.error("Reedah: Failed to send narration request.", error);
      port.postMessage({ type: "error", error: "native_send_failed" });
    }
  });

  port.onDisconnect.addListener(() => {
    closing = true;
    if (nativePort) {
      try {
        nativePort.disconnect();
      } catch (error) {
        // Ignore disconnect errors.
      }
    }
    nativePort = null;
  });
});

function getSettings() {
  return new Promise((resolve) => {
    chrome.storage.local.get(["nativeVoice", "nativeRate"], (items) => {
      const voice = (items.nativeVoice || "").trim();
      const rate = parseRate(items.nativeRate);
      resolve({ voice, rate });
    });
  });
}

function parseRate(value) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string") {
    const trimmed = value.trim();
    if (!trimmed) return null;
    const parsed = Number(trimmed);
    if (Number.isFinite(parsed)) return parsed;
  }
  return null;
}
