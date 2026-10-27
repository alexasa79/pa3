const rateInput = document.getElementById("rate");
const statusEl = document.getElementById("status");
const clearButton = document.getElementById("clear");
const testNarrationTextInput = document.getElementById("test-narration-text");
const testNarrateButton = document.getElementById("test-narrate");

const NIGHT_START_HOUR = 19;
const NIGHT_END_HOUR = 6;
const THEME_REFRESH_INTERVAL_MS = 60 * 1000;
const SETTINGS_KEYS = ["pa3Rate"];

let themeTimer = null;
let previewSession = null;

function resolveTheme(date = new Date()) {
  const hour = date.getHours();
  if (hour >= NIGHT_START_HOUR || hour < NIGHT_END_HOUR) {
    return "dark";
  }
  return "light";
}

function applyThemeForCurrentTime() {
  document.documentElement.dataset.theme = resolveTheme();
}

function startThemeScheduler() {
  applyThemeForCurrentTime();
  if (themeTimer !== null) {
    window.clearInterval(themeTimer);
  }
  themeTimer = window.setInterval(applyThemeForCurrentTime, THEME_REFRESH_INTERVAL_MS);
}

function setStatus(message, isError = false) {
  statusEl.textContent = message;
  statusEl.style.color = isError ? "var(--status-error)" : "var(--status-ok)";
  if (!message) return;

  window.clearTimeout(setStatus._timer);
  setStatus._timer = window.setTimeout(() => {
    statusEl.textContent = "";
  }, 2000);
}

function parseRateInputValue() {
  const rateRaw = rateInput.value.trim();
  if (!rateRaw) {
    return null;
  }
  const rate = Number(rateRaw);
  if (!Number.isFinite(rate)) {
    throw new Error("Speed must be a number.");
  }
  if (rate < 0.5 || rate > 2) {
    throw new Error("Speed must be between 0.5 and 2.0.");
  }
  return rate;
}

function normalizeTestNarrationText(value) {
  if (typeof value !== "string") {
    throw new Error("Test narration text must be a string.");
  }
  const normalized = value.replace(/\s+/g, " ").trim();
  if (!normalized) {
    throw new Error("Test narration text must be non-empty.");
  }
  return normalized;
}

function updateTestNarrateButtonState() {
  if (!testNarrateButton) return;
  const isActiveTestPreview =
    previewSession !== null && previewSession.previewType === "test";
  testNarrateButton.textContent = isActiveTestPreview ? "Stop Narration" : "Narrate Text";
}

function refreshPreviewUi() {
  updateTestNarrateButtonState();
}

function base64ToUint8Array(base64) {
  const binary = atob(base64);
  const len = binary.length;
  const bytes = new Uint8Array(len);
  for (let i = 0; i < len; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

function createAudioUrl(base64, mimeType) {
  const bytes = base64ToUint8Array(base64);
  const blob = new Blob([bytes], { type: mimeType || "audio/wav" });
  return URL.createObjectURL(blob);
}

function closePreviewSession(session, sendStop) {
  session.closing = true;
  for (const item of session.streams?.values() ?? []) item.stream.dispose();
  session.streams?.clear();

  if (session.currentAudio) {
    try {
      session.currentAudio.pause();
      session.currentAudio.src = "";
    } catch (error) {
      console.error("PA3 extension: Failed to stop preview audio.", error);
    }
    session.currentAudio = null;
  }

  if (session.currentAudioUrl) {
    URL.revokeObjectURL(session.currentAudioUrl);
    session.currentAudioUrl = null;
  }

  for (const queuedUrl of session.audioQueue) {
    URL.revokeObjectURL(queuedUrl);
  }
  session.audioQueue.length = 0;

  if (session.port) {
    if (sendStop) {
      try {
        session.port.postMessage({
          type: "stop",
          utteranceId: session.utteranceId
        });
      } catch (error) {
        console.error("PA3 extension: Failed to stop preview narration.", error);
      }
    }
    try {
      session.port.disconnect();
    } catch (error) {
      console.error("PA3 extension: Failed to disconnect preview narration.", error);
    }
    session.port = null;
  }
}

function stopPreview(sendStop = true) {
  if (!previewSession) return;
  const session = previewSession;
  previewSession = null;
  closePreviewSession(session, sendStop);
  refreshPreviewUi();
}

function finishPreviewSession(session) {
  if (previewSession !== session) return;
  previewSession = null;
  closePreviewSession(session, false);
  refreshPreviewUi();
}

function maybeFinishPreviewWhenDone(session) {
  if (previewSession !== session) return;
  if (!session.completed) return;
  if (session.currentAudio) return;
  if (session.audioQueue.length > 0) return;
  finishPreviewSession(session);
  setStatus("Preview complete.");
}

function playNextPreviewAudio(session) {
  if (previewSession !== session) return;
  if (session.currentAudio) return;
  if (session.audioQueue.length === 0) {
    maybeFinishPreviewWhenDone(session);
    return;
  }

  const audioUrl = session.audioQueue.shift();
  const streamItem = [...session.streams.values()].find(item => item.url === audioUrl);
  const audio = streamItem?.stream ?? new Audio();
  session.currentAudio = audio;
  session.currentAudioUrl = audioUrl;
  audio.src = audioUrl;
  audio.playbackRate = session.rate;

  audio.onended = () => {
    if (previewSession !== session) return;
    if (session.currentAudio !== audio) return;
    if (session.currentAudioUrl) {
      URL.revokeObjectURL(session.currentAudioUrl);
      session.currentAudioUrl = null;
    }
    session.currentAudio = null;
    if (streamItem) {
      try { session.port.postMessage({type:"consumed", index:streamItem.index}); }
      catch (error) {
        console.error("PA3 extension: Could not release preview queue slot.", error);
        finishPreviewSession(session);
        return;
      }
      streamItem.stream.dispose();
      session.streams.delete(streamItem.index);
    }
    playNextPreviewAudio(session);
  };

  audio.onerror = () => {
    if (previewSession !== session) return;
    if (session.currentAudioUrl) {
      URL.revokeObjectURL(session.currentAudioUrl);
      session.currentAudioUrl = null;
    }
    session.currentAudio = null;
    finishPreviewSession(session);
    setStatus("Preview audio playback failed.", true);
  };

  audio.play().catch((error) => {
    if (previewSession !== session) return;
    if (session.currentAudioUrl) {
      URL.revokeObjectURL(session.currentAudioUrl);
      session.currentAudioUrl = null;
    }
    session.currentAudio = null;
    finishPreviewSession(session);
    if (error && error.name === "AbortError") {
      return;
    }
    console.error("PA3 extension: Failed to start preview audio.", error);
    setStatus("Failed to start preview audio.", true);
  });
}

function startPreviewRequest({
  text,
  previewType = "generic"
}) {
  stopPreview(true);

  let rate = null;
  try {
    rate = parseRateInputValue();
  } catch (error) {
    setStatus(error.message, true);
    return false;
  }

  const utteranceId = `preview-${Date.now()}-${Math.floor(Math.random() * 1000000)}`;
  let port;
  try {
    port = chrome.runtime.connect({ name: "reedah-native" });
  } catch (error) {
    console.error("PA3 extension: Failed to open preview native port.", error);
    setStatus("Failed to open native preview port.", true);
    return false;
  }

  const session = {
    utteranceId,
    previewType,
    rate: rate ?? 1,
    completed: false,
    closing: false,
    streams: new Map(),
    audioQueue: [],
    currentAudio: null,
    currentAudioUrl: null,
    port
  };
  previewSession = session;
  refreshPreviewUi();
  ReedahStreamAudio.unlock().catch(error => {
    if (previewSession !== session) return;
    console.error("PA3 extension: Could not activate streaming preview.", error);
    finishPreviewSession(session);
    setStatus("Could not activate audio.", true);
  });

  port.onMessage.addListener((message) => {
    if (previewSession !== session) return;
    if (!message || typeof message.type !== "string") return;
    if (message.utteranceId && message.utteranceId !== utteranceId) return;

    if (message.type === "prepared_sentence_jobs") {
      if (!Array.isArray(message.sentenceJobs)) {
        console.error("PA3 extension: Invalid prepared sentence jobs payload in options preview.");
        return;
      }
      for (const job of message.sentenceJobs) {
        if (!job || typeof job !== "object") {
          console.error("PA3 extension: Invalid prepared sentence job in options preview.", job);
          continue;
        }
        console.info(
          "PA3 extension: Options preview source sent to PA3:",
          job.index,
          job.location,
          job.length,
          JSON.stringify(job.text)
        );
      }
      return;
    }

    if (message.type === "audio_end" || (message.type === "audio" && message.stream)) {
      try {
        let item = session.streams.get(message.index);
        if (message.type === "audio_end") {
          if (!item) throw new Error("Unknown preview stream");
          item.stream.finish(message.chunks);
        } else {
          if (!item) {
            item = {index:message.index, url:`reedah-preview:${message.index}`, stream:new ReedahStreamAudio.StreamAudio({playbackRate:session.rate})};
            session.streams.set(message.index, item);
            item.stream.append(message);
            session.audioQueue.push(item.url);
          } else item.stream.append(message);
          playNextPreviewAudio(session);
        }
      } catch (error) {
        console.error("PA3 extension: Invalid preview stream.", error);
        finishPreviewSession(session);
        setStatus("Streaming preview failed.", true);
      }
      return;
    }
    if (message.type === "audio") {
      if (typeof message.audioBase64 !== "string" || !message.audioBase64) {
        finishPreviewSession(session);
        setStatus("Invalid preview audio payload.", true);
        return;
      }
      let url;
      try {
        url = createAudioUrl(message.audioBase64, message.mimeType);
      } catch (error) {
        console.error("PA3 extension: Failed to decode preview audio payload.", error);
        finishPreviewSession(session);
        setStatus("Failed to decode preview audio.", true);
        return;
      }
      session.audioQueue.push(url);
      playNextPreviewAudio(session);
      return;
    }

    if (message.type === "end" || message.type === "cancelled") {
      session.completed = true;
      maybeFinishPreviewWhenDone(session);
      return;
    }

    if (message.type === "error") {
      const details = message.details || message.error || "native_error";
      console.error("PA3 extension: Native preview error.", details);
      finishPreviewSession(session);
      setStatus(`Preview failed: ${details}`, true);
    }
  });

  port.onDisconnect.addListener(() => {
    if (previewSession !== session) return;
    if (session.closing) return;
    const lastError = chrome.runtime.lastError;
    finishPreviewSession(session);
    if (lastError) {
      console.error("PA3 extension: Preview native host disconnected.", lastError.message);
      setStatus(`Preview disconnected: ${lastError.message}`, true);
      return;
    }
    setStatus("Preview disconnected.", true);
  });

  const payload = {
    type: "start",
    text,
    utteranceId,
    sentenceRanges: [{ start: 0, end: text.length }]
  };
  if (rate != null) {
    payload.rate = rate;
  }

  try {
    port.postMessage(payload);
  } catch (error) {
    console.error("PA3 extension: Failed to send preview request.", error);
    finishPreviewSession(session);
    setStatus("Failed to send preview request.", true);
    return false;
  }
  return true;
}

function handleTestNarrationClick() {
  const existing = previewSession;
  if (existing && existing.previewType === "test") {
    stopPreview(true);
    return;
  }

  let text;
  try {
    text = normalizeTestNarrationText(testNarrationTextInput.value);
  } catch (error) {
    setStatus(error.message, true);
    return;
  }

  const started = startPreviewRequest({
    text,
    previewType: "test"
  });
  if (started) {
    setStatus("Running test narration...");
  }
}

function loadSettings() {
  chrome.storage.local.get(SETTINGS_KEYS, (items) => {
    if (chrome.runtime.lastError) {
      setStatus("Failed to load settings.", true);
      return;
    }

    if (items.pa3Rate == null) {
      rateInput.value = "";
    } else {
      rateInput.value = String(items.pa3Rate);
    }

  });
}

function persistSettings(successMessage) {
  let rate = null;
  try {
    rate = parseRateInputValue();
  } catch (error) {
    setStatus(error.message, true);
    return false;
  }

  chrome.storage.local.set(
    {
      pa3Rate: rate
    },
    () => {
      if (chrome.runtime.lastError) {
        console.error(
          "PA3 extension: Failed to auto-save settings.",
          chrome.runtime.lastError.message
        );
        setStatus("Failed to save settings.", true);
        return;
      }

      if (successMessage) {
        setStatus(successMessage);
      }
    }
  );
  return true;
}

function handleRateChange() {
  persistSettings("Settings saved.");
}

function clearSettings() {
  stopPreview(true);
  chrome.storage.local.remove(SETTINGS_KEYS, () => {
    if (chrome.runtime.lastError) {
      setStatus("Failed to clear settings.", true);
      return;
    }

    rateInput.value = "";
    setStatus("Cleared.");
  });
}

clearButton.addEventListener("click", clearSettings);
testNarrateButton.addEventListener("click", handleTestNarrationClick);
rateInput.addEventListener("change", handleRateChange);
document.addEventListener("visibilitychange", () => {
  if (document.hidden) return;
  applyThemeForCurrentTime();
});

startThemeScheduler();
updateTestNarrateButtonState();
loadSettings();
