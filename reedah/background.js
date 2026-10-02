importScripts("narration_text.js", "native_request_builder.js", "audio_transfer.js");

const NATIVE_HOST = "com.reedah.sayer";
const ICON_SIZES = [16, 32, 48];
const tabState = new Map();
let iconCache = null;
const nativeRequestBuilder = globalThis.ReedahNativeRequestBuilder;
if (!nativeRequestBuilder ||
  typeof nativeRequestBuilder.buildSentenceJobs !== "function") {
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
  ctx.fillStyle = enabled ? "#2563EB" : "#424242";
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
      length: event.length,
      stream: event.stream,
      samples: event.samples,
      sampleRate: event.sampleRate,
      pieceIndex: event.pieceIndex,
      pieceCount: event.pieceCount,
      progressStart: event.progressStart,
      progressEnd: event.progressEnd,
      rate: event.rate
    });
    return;
  }

  if (event.event === "audio_end") {
    port.postMessage({type: "audio_end", utteranceId: event.utteranceId, index: event.index, chunks: event.chunks});
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

chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== "reedah-native") return;

  let session = null;
  let disconnected = false;
  function stopSession() {
    if (!session) return;
    const old = session;
    session = null;
    if (old.host) {
      // Give the bridge time to delete its PA3 job before Chrome terminates it.
      old.closeTimer = setTimeout(() => old.host.disconnect(), 25000);
      try { old.host.postMessage({ action: "stop" }); }
      catch (error) {
        console.error("Reedah: Could not stop PA3 bridge.", error);
        clearTimeout(old.closeTimer);
        old.host.disconnect();
      }
    }
  }

  port.onMessage.addListener(async (message) => {
    if (!message || typeof message.type !== "string") return;

    if (message.type === "stop") {
      stopSession();
      return;
    }

    if (message.type === "consumed" || message.type === "window") {
      if (!session) return;
      try {
        if (message.type === "window") {
          if (![1, 2].includes(message.window)) throw new Error("Invalid sentence window");
          session.window = message.window;
          session.host?.postMessage({action:"window", window:message.window});
        } else if (!session.consumed.has(message.index)) {
          session.host?.postMessage({action:"consumed", index:message.index});
          session.consumed.add(message.index);
        }
      } catch (error) {
        console.error("Reedah: Playback flow control failed.", error);
        port.postMessage({type:"error", error:"flow_control", details:error.message});
        stopSession();
      }
      return;
    }
    if (message.type !== "start") return;
    stopSession();
    const current = {window:message.window ?? 2, consumed:new Set()};
    session = current;

    // Sentence ranges address the content script's original UTF-16 text.
    // Trimming here shifts every range past its opening and into the next one.
    const text = typeof message.text === "string" ? message.text : "";
    const sentenceRanges = Array.isArray(message.sentenceRanges)
      ? message.sentenceRanges
      : null;
    if (!text.trim()) {
      port.postMessage({ type: "error", error: "empty_text" });
      return;
    }
    if (!sentenceRanges || sentenceRanges.length === 0) {
      port.postMessage({ type: "error", error: "missing_sentence_ranges" });
      return;
    }

    const utteranceId = message.utteranceId || `${Date.now()}`;
    const settings = await getSettings();
    if (disconnected || session !== current) return;
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

    if (resolvedRate != null && (resolvedRate < 0.5 || resolvedRate > 2)) {
      console.error("Reedah: Invalid playback speed.");
      port.postMessage({ type: "error", utteranceId, error: "invalid_rate" });
      return;
    }
    let sentenceJobs;
    try {
      sentenceJobs = nativeRequestBuilder.buildSentenceJobs(text, sentenceRanges);
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

    const assembler = new ReedahAudioTransfer.Assembler();
    try {
      const host = chrome.runtime.connectNative(NATIVE_HOST);
      current.host = host;
      host.onMessage.addListener((event) => {
        if (event.event === "cancelled") {
          clearTimeout(current.closeTimer);
          host.disconnect();
          return;
        }
        if (session !== current || disconnected) return;
        try {
          if (event.event === "audio_chunk") {
            const audio = assembler.accept(event);
            if (audio) relayServerEvent(port, { ...audio, rate: resolvedRate ?? 1 });
          } else {
            if (event.event === "finished" && assembler.pending) throw new Error("Incomplete audio transfer");
            relayServerEvent(port, event);
            if (event.event === "finished" || event.event === "error") {
              session = null;
              host.disconnect();
            }
          }
        } catch (error) {
          console.error("Reedah: Invalid PA3 audio transfer.", error);
          port.postMessage({ type: "error", utteranceId, error: "invalid_audio", details: error.message });
          stopSession();
        }
      });
      host.onDisconnect.addListener(() => {
        const error = chrome.runtime.lastError;
        clearTimeout(current.closeTimer);
        if (session !== current || disconnected) return;
        session = null;
        console.error("Reedah: PA3 bridge disconnected.", error?.message);
        port.postMessage({ type: "error", utteranceId, error: "bridge_unavailable",
          details: error?.message || "PA3 bridge disconnected. Install the native host and start PA3." });
      });
      host.postMessage({ action: "speak", utteranceId, sentenceJobs, window:current.window });
    } catch (error) {
      console.error("Reedah: Could not connect to PA3 bridge.", error);
      port.postMessage({ type: "error", utteranceId, error: "bridge_unavailable", details: error.message });
      stopSession();
    }
  });

  port.onDisconnect.addListener(() => {
    disconnected = true;
    stopSession();
  });
});

function getSettings() {
  return new Promise((resolve) => {
    chrome.storage.local.get(["pa3Rate"], (items) => resolve({rate: parseRate(items.pa3Rate)}));
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
