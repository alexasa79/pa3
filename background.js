importScripts("native_request_builder.js");

const TTS_SERVER_URL = "http://127.0.0.1:7865";
const ICON_SIZES = [16, 32, 48];
const tabState = new Map();
let iconCache = null;
const nativeRequestBuilder = globalThis.ReedahNativeRequestBuilder;
if (!nativeRequestBuilder ||
  typeof nativeRequestBuilder.buildSentenceJobs !== "function" ||
  typeof nativeRequestBuilder.applyCustomVocab !== "function") {
  console.error("Reedah: Native request builder helpers unavailable.");
  throw new Error("Reedah: native request builder helpers unavailable");
}
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

function relayServerEvent(port, event) {
  if (!event || typeof event.event !== "string") return;

  if (event.event === "started") {
    port.postMessage({
      type: "started",
      utteranceId: event.utteranceId || null,
      voiceName: event.voiceName || null,
      voiceIdentifier: event.voiceIdentifier || null
    });
    return;
  }

  if (event.event === "audio") {
    port.postMessage({
      type: "audio",
      utteranceId: event.utteranceId || null,
      index: event.index,
      audioBase64: event.audioBase64,
      mimeType: event.mimeType || "audio/wav",
      location: event.location,
      length: event.length
    });
    return;
  }

  if (event.event === "finished") {
    port.postMessage({
      type: "end",
      utteranceId: event.utteranceId || null
    });
    return;
  }

  if (event.event === "error") {
    port.postMessage({
      type: "error",
      utteranceId: event.utteranceId || null,
      error: event.message || "server_error",
      details: event.details || null
    });
  }
}

async function streamTTSResponse(port, response) {
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split("\n");
      buffer = lines.pop();
      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed) continue;
        try {
          relayServerEvent(port, JSON.parse(trimmed));
        } catch (parseError) {
          console.error("Reedah: Failed to parse server event.", parseError);
        }
      }
    }
    if (buffer.trim()) {
      try {
        relayServerEvent(port, JSON.parse(buffer.trim()));
      } catch (parseError) {
        console.error("Reedah: Failed to parse final server event.", parseError);
      }
    }
  } finally {
    reader.releaseLock();
  }
}

chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== "reedah-native") return;

  let abortController = null;

  port.onMessage.addListener(async (message) => {
    if (!message || typeof message.type !== "string") return;

    if (message.type === "stop") {
      if (abortController) {
        abortController.abort();
        abortController = null;
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
    const hasCustomVocabOverride = Object.prototype.hasOwnProperty.call(message, "customVocab");
    let customVocab = settings.customVocab;
    if (hasCustomVocabOverride) {
      try {
        customVocab = normalizeCustomVocab(message.customVocab);
      } catch (error) {
        const details = error.message || String(error);
        console.error("Reedah: Invalid custom vocabulary override.", details);
        port.postMessage({
          type: "error",
          utteranceId,
          error: "invalid_custom_vocab",
          details
        });
        return;
      }
    } else if (settings.customVocabError) {
      console.error("Reedah: Invalid custom vocabulary settings.", settings.customVocabError);
      port.postMessage({
        type: "error",
        utteranceId,
        error: "invalid_custom_vocab",
        details: settings.customVocabError
      });
      return;
    }

    let resolvedVoice = settings.voice;
    if (typeof message.voice === "string") {
      resolvedVoice = message.voice.trim();
    }

    let resolvedRate = settings.rate;
    if (Object.prototype.hasOwnProperty.call(message, "rate")) {
      resolvedRate = parseRate(message.rate);
      if (message.rate != null && resolvedRate == null) {
        const details = `invalid_rate:${String(message.rate)}`;
        console.error("Reedah: Invalid narration rate override.", details);
        port.postMessage({
          type: "error",
          utteranceId,
          error: "invalid_rate",
          details
        });
        return;
      }
    }

    let sentenceJobs;
    try {
      sentenceJobs = nativeRequestBuilder.buildSentenceJobs(text, sentenceRanges, customVocab);
    } catch (error) {
      const details = error.message || String(error);
      console.error("Reedah: Failed to build sentence jobs.", details);
      port.postMessage({
        type: "error",
        utteranceId,
        error: "invalid_sentence_jobs",
        details
      });
      return;
    }
    if (sentenceJobs.length === 0) {
      console.error("Reedah: No sentence jobs available.");
      port.postMessage({
        type: "error",
        utteranceId,
        error: "empty_sentence_jobs"
      });
      return;
    }

    port.postMessage({
      type: "prepared_sentence_jobs",
      utteranceId,
      sentenceJobs
    });

    for (const job of sentenceJobs) {
      console.info(
        "Reedah: Narration sentence sent to model:",
        job.index,
        job.location,
        job.length,
        JSON.stringify(job.text)
      );
    }

    const requestBody = { utteranceId, sentenceJobs };
    if (resolvedVoice) {
      requestBody.voice = resolvedVoice;
    }
    if (resolvedRate != null) {
      requestBody.speed = resolvedRate;
    }
    if (settings.langCode) {
      requestBody.langCode = settings.langCode;
    }

    if (abortController) {
      abortController.abort();
    }
    abortController = new AbortController();
    const { signal } = abortController;

    try {
      const response = await fetch(`${TTS_SERVER_URL}/tts`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(requestBody),
        signal
      });

      if (!response.ok) {
        let errorDetail = `HTTP ${response.status}`;
        try {
          const errorBody = await response.json();
          errorDetail = errorBody.details || errorBody.error || errorDetail;
        } catch (_ignored) {
          // Use status code as detail.
        }
        console.error("Reedah: TTS server error.", errorDetail);
        port.postMessage({
          type: "error",
          utteranceId,
          error: "server_error",
          details: errorDetail
        });
        return;
      }

      await streamTTSResponse(port, response);
    } catch (error) {
      if (error.name === "AbortError") {
        port.postMessage({ type: "cancelled", utteranceId });
        return;
      }
      console.error("Reedah: TTS server request failed.", error);
      port.postMessage({
        type: "error",
        utteranceId,
        error: "server_unavailable",
        details: "Kokoro TTS server is not running. Start it with: python native/kokoro_server.py"
      });
    } finally {
      abortController = null;
    }
  });

  port.onDisconnect.addListener(() => {
    if (abortController) {
      abortController.abort();
      abortController = null;
    }
  });
});

function getSettings() {
  return new Promise((resolve) => {
    chrome.storage.local.get(
      ["nativeVoice", "nativeRate", "nativePythonPath", "nativeModel", "nativeLangCode", "nativeCustomVocab"],
      (items) => {
        const voice = (items.nativeVoice || "").trim();
        const rate = parseRate(items.nativeRate);
        const pythonPath = (items.nativePythonPath || "").trim();
        const model = (items.nativeModel || "").trim();
        const langCode = (items.nativeLangCode || "").trim();
        let customVocab = [];
        let customVocabError = null;
        try {
          customVocab = normalizeCustomVocab(items.nativeCustomVocab);
        } catch (error) {
          customVocabError = error.message || String(error);
        }
        resolve({ voice, rate, pythonPath, model, langCode, customVocab, customVocabError });
      }
    );
  });
}

function normalizeCustomVocab(rawValue) {
  if (rawValue == null) return [];
  if (!Array.isArray(rawValue)) {
    throw new Error("Custom vocabulary must be an array.");
  }
  const entries = [];
  const seen = new Set();
  for (let index = 0; index < rawValue.length; index += 1) {
    const rawEntry = rawValue[index];
    if (!rawEntry || typeof rawEntry !== "object") {
      throw new Error(`Custom vocabulary entry ${index + 1} must be an object.`);
    }

    const spelling =
      typeof rawEntry.spelling === "string" ? rawEntry.spelling.trim() : "";
    let pronunciation =
      typeof rawEntry.pronunciation === "string"
        ? rawEntry.pronunciation.trim()
        : "";

    if (pronunciation.startsWith("/") && pronunciation.endsWith("/") && pronunciation.length >= 2) {
      pronunciation = pronunciation.slice(1, -1).trim();
    }

    if (!spelling || !pronunciation) {
      throw new Error(`Custom vocabulary entry ${index + 1} must have spelling and pronunciation.`);
    }
    if (spelling.includes("[") || spelling.includes("]")) {
      throw new Error(`Custom vocabulary entry ${index + 1} spelling must not contain '[' or ']'.`);
    }
    if (pronunciation.includes("/")) {
      throw new Error(`Custom vocabulary entry ${index + 1} pronunciation must not contain '/'.`);
    }

    const spellingKey = spelling.toLocaleLowerCase();
    if (seen.has(spellingKey)) {
      throw new Error(`Duplicate custom vocabulary spelling: ${spelling}`);
    }
    seen.add(spellingKey);
    entries.push({ spelling, pronunciation });
  }
  return entries;
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
