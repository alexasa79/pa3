const NATIVE_HOST_NAME = "com.reedah.sayer";
const ICON_SIZES = [16, 32, 48];
const tabState = new Map();
let iconCache = null;
const iconSupported =
  typeof OffscreenCanvas !== "undefined" && typeof ImageData !== "undefined";

if (!iconSupported) {
  console.error("Reedah: OffscreenCanvas unavailable; icon updates disabled.");
}

function buildIconCache() {
  const enabled = {};
  const disabled = {};
  for (const size of ICON_SIZES) {
    enabled[size] = drawIcon(size, true);
    disabled[size] = drawIcon(size, false);
  }
  return { enabled, disabled };
}

function getIconData(enabled) {
  if (!iconSupported) {
    return null;
  }
  if (!iconCache) {
    iconCache = buildIconCache();
  }
  return enabled ? iconCache.enabled : iconCache.disabled;
}

function drawIcon(size, enabled) {
  const canvas = new OffscreenCanvas(size, size);
  const ctx = canvas.getContext("2d");
  const center = size / 2;
  const radius = center - 1;

  ctx.clearRect(0, 0, size, size);
  ctx.fillStyle = enabled ? "#2E7D32" : "#424242";
  ctx.beginPath();
  ctx.arc(center, center, radius, 0, Math.PI * 2);
  ctx.fill();

  ctx.fillStyle = "#FFFFFF";
  ctx.beginPath();
  ctx.moveTo(size * 0.42, size * 0.32);
  ctx.lineTo(size * 0.72, size * 0.5);
  ctx.lineTo(size * 0.42, size * 0.68);
  ctx.closePath();
  ctx.fill();

  return ctx.getImageData(0, 0, size, size);
}

function setTabIcon(tabId, enabled) {
  const imageData = getIconData(enabled);
  if (!imageData) return;
  chrome.action.setIcon({ tabId, imageData });
}

function updateTabState(tabId, enabled) {
  tabState.set(tabId, enabled);
  setTabIcon(tabId, enabled);
}

function clearTabState(tabId) {
  tabState.delete(tabId);
  setTabIcon(tabId, false);
}

function requestTabState(tabId) {
  chrome.tabs.sendMessage(tabId, { type: "reedah-state-request" }, (response) => {
    if (chrome.runtime.lastError) {
      clearTabState(tabId);
      return;
    }
    if (response && typeof response.enabled === "boolean") {
      updateTabState(tabId, response.enabled);
      return;
    }
    clearTabState(tabId);
  });
}

chrome.tabs.onActivated.addListener(({ tabId }) => {
  requestTabState(tabId);
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.status === "loading") {
    tabState.delete(tabId);
    setTabIcon(tabId, false);
  }
  if (changeInfo.status === "complete") {
    requestTabState(tabId);
  }
});

chrome.tabs.onRemoved.addListener((tabId) => {
  tabState.delete(tabId);
});

chrome.commands.onCommand.addListener((command) => {
  if (command !== "toggle-overlay" && command !== "pause-playback") return;

  chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
    const tab = tabs && tabs[0];
    if (!tab || !tab.id) return;
    const type =
      command === "pause-playback" ? "reedah-pause" : "reedah-toggle";
    chrome.tabs.sendMessage(tab.id, { type }, () => {
      if (chrome.runtime.lastError) {
        // No content script on this page (e.g., chrome://, extensions page).
        return;
      }
    });
  });
});

chrome.runtime.onMessage.addListener((message, sender) => {
  if (!message || message.type !== "reedah-state") return;
  const tabId = sender && sender.tab ? sender.tab.id : null;
  if (!tabId) return;
  updateTabState(tabId, !!message.enabled);
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
