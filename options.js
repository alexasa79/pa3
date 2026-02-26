const voiceInput = document.getElementById("voice");
const rateInput = document.getElementById("rate");
const statusEl = document.getElementById("status");
const clearButton = document.getElementById("clear");
const manageVocabButton = document.getElementById("manage-vocab");
const vocabCountEl = document.getElementById("vocab-count");
const testNarrationTextInput = document.getElementById("test-narration-text");
const testNarrateButton = document.getElementById("test-narrate");
const vocabDialog = document.getElementById("vocab-dialog");
const vocabSpellingInput = document.getElementById("vocab-spelling");
const vocabPronunciationInput = document.getElementById("vocab-pronunciation");
const vocabAddUpdateButton = document.getElementById("vocab-add-update");
const vocabResetButton = document.getElementById("vocab-reset");
const vocabListEl = document.getElementById("vocab-list");
const vocabCancelButton = document.getElementById("vocab-cancel");

const DEFAULT_VOICE = "am_adam";
const NIGHT_START_HOUR = 19;
const NIGHT_END_HOUR = 6;
const THEME_REFRESH_INTERVAL_MS = 60 * 1000;
const SETTINGS_KEYS = ["nativeVoice", "nativeRate", "nativeCustomVocab"];
const KOKORO_VOICES = [
  "af_alloy",
  "af_aoede",
  "af_bella",
  "af_heart",
  "af_jessica",
  "af_kore",
  "af_nicole",
  "af_nova",
  "af_river",
  "af_sarah",
  "af_sky",
  "am_adam",
  "am_echo",
  "am_eric",
  "am_fenrir",
  "am_liam",
  "am_michael",
  "am_onyx",
  "am_puck",
  "am_santa",
  "bf_alice",
  "bf_emma",
  "bf_isabella",
  "bf_lily",
  "bm_daniel",
  "bm_fable",
  "bm_george",
  "bm_lewis",
  "ef_dora",
  "em_alex",
  "em_santa",
  "ff_siwis",
  "hf_alpha",
  "hf_beta",
  "hm_omega",
  "hm_psi",
  "if_sara",
  "im_nicola",
  "jf_alpha",
  "jf_gongitsune",
  "jf_nezumi",
  "jf_tebukuro",
  "jm_kumo",
  "pf_dora",
  "pm_alex",
  "pm_santa",
  "zf_xiaobei",
  "zf_xiaoni",
  "zf_xiaoxiao",
  "zf_xiaoyi",
  "zm_yunjian",
  "zm_yunxi",
  "zm_yunxia",
  "zm_yunyang"
];

let themeTimer = null;
let customVocabEntries = [];
let vocabDraftEntries = [];
let editingVocabIndex = null;
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

function populateVoiceOptions() {
  voiceInput.textContent = "";
  for (const voice of KOKORO_VOICES) {
    const option = document.createElement("option");
    option.value = voice;
    option.textContent = voice;
    voiceInput.appendChild(option);
  }
  voiceInput.value = DEFAULT_VOICE;
}

function normalizeVoice(value) {
  if (typeof value !== "string") return DEFAULT_VOICE;
  const trimmed = value.trim();
  if (!trimmed) return DEFAULT_VOICE;
  if (!KOKORO_VOICES.includes(trimmed)) return DEFAULT_VOICE;
  return trimmed;
}

function normalizeSpelling(value, label) {
  if (typeof value !== "string") {
    throw new Error(`${label} spelling must be a string.`);
  }
  const normalized = value.trim();
  if (!normalized) {
    throw new Error(`${label} spelling must be non-empty.`);
  }
  if (normalized.includes("[") || normalized.includes("]")) {
    throw new Error(`${label} spelling must not contain '[' or ']'.`);
  }
  if (normalized.includes("\n") || normalized.includes("\r")) {
    throw new Error(`${label} spelling must be a single line.`);
  }
  return normalized;
}

function normalizePronunciation(value, label) {
  if (typeof value !== "string") {
    throw new Error(`${label} pronunciation must be a string.`);
  }
  let normalized = value.trim();
  if (normalized.startsWith("/") && normalized.endsWith("/") && normalized.length >= 2) {
    normalized = normalized.slice(1, -1).trim();
  }
  if (!normalized) {
    throw new Error(`${label} pronunciation must be non-empty.`);
  }
  if (normalized.includes("/")) {
    throw new Error(`${label} pronunciation must not contain '/'.`);
  }
  if (normalized.includes("\n") || normalized.includes("\r")) {
    throw new Error(`${label} pronunciation must be a single line.`);
  }
  return normalized;
}

function normalizeCustomVocabEntries(rawEntries) {
  if (rawEntries == null) return [];
  if (!Array.isArray(rawEntries)) {
    throw new Error("Custom vocabulary must be an array.");
  }

  const normalized = [];
  const seen = new Set();
  for (let index = 0; index < rawEntries.length; index += 1) {
    const rawEntry = rawEntries[index];
    if (!rawEntry || typeof rawEntry !== "object") {
      throw new Error(`Custom vocabulary entry ${index + 1} must be an object.`);
    }

    const spelling = normalizeSpelling(rawEntry.spelling, `Entry ${index + 1}`);
    const pronunciation = normalizePronunciation(
      rawEntry.pronunciation,
      `Entry ${index + 1}`
    );
    const key = spelling.toLocaleLowerCase();
    if (seen.has(key)) {
      throw new Error(`Duplicate custom spelling: ${spelling}`);
    }
    seen.add(key);
    normalized.push({ spelling, pronunciation });
  }
  return normalized;
}

function cloneCustomVocab(entries) {
  return entries.map((entry) => ({
    spelling: entry.spelling,
    pronunciation: entry.pronunciation
  }));
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
  renderVocabList();
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

  if (session.currentAudio) {
    try {
      session.currentAudio.pause();
      session.currentAudio.src = "";
    } catch (error) {
      console.error("Reedah: Failed to stop preview audio.", error);
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
        console.error("Reedah: Failed to stop preview narration.", error);
      }
    }
    try {
      session.port.disconnect();
    } catch (error) {
      console.error("Reedah: Failed to disconnect preview narration.", error);
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
  const audio = new Audio();
  session.currentAudio = audio;
  session.currentAudioUrl = audioUrl;
  audio.src = audioUrl;

  audio.onended = () => {
    if (previewSession !== session) return;
    if (session.currentAudio !== audio) return;
    if (session.currentAudioUrl) {
      URL.revokeObjectURL(session.currentAudioUrl);
      session.currentAudioUrl = null;
    }
    session.currentAudio = null;
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
    console.error("Reedah: Failed to start preview audio.", error);
    setStatus("Failed to start preview audio.", true);
  });
}

function startPreviewRequest({
  text,
  customVocab = null,
  entryIndex = null,
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
    console.error("Reedah: Failed to open preview native port.", error);
    setStatus("Failed to open native preview port.", true);
    return false;
  }

  const session = {
    utteranceId,
    previewType,
    entryIndex,
    completed: false,
    closing: false,
    audioQueue: [],
    currentAudio: null,
    currentAudioUrl: null,
    port
  };
  previewSession = session;
  refreshPreviewUi();

  port.onMessage.addListener((message) => {
    if (previewSession !== session) return;
    if (!message || typeof message.type !== "string") return;
    if (message.utteranceId && message.utteranceId !== utteranceId) return;

    if (message.type === "prepared_sentence_jobs") {
      if (!Array.isArray(message.sentenceJobs)) {
        console.error("Reedah: Invalid prepared sentence jobs payload in options preview.");
        return;
      }
      for (const job of message.sentenceJobs) {
        if (!job || typeof job !== "object") {
          console.error("Reedah: Invalid prepared sentence job in options preview.", job);
          continue;
        }
        console.info(
          "Reedah: Options preview sentence sent to model:",
          job.index,
          job.location,
          job.length,
          JSON.stringify(job.text)
        );
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
        console.error("Reedah: Failed to decode preview audio payload.", error);
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
      console.error("Reedah: Native preview error.", details);
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
      console.error("Reedah: Preview native host disconnected.", lastError.message);
      setStatus(`Preview disconnected: ${lastError.message}`, true);
      return;
    }
    setStatus("Preview disconnected.", true);
  });

  const payload = {
    type: "start",
    text,
    utteranceId,
    sentenceRanges: [{ start: 0, end: text.length }],
    voice: normalizeVoice(voiceInput.value)
  };
  if (Array.isArray(customVocab)) {
    payload.customVocab = customVocab;
  }
  if (rate != null) {
    payload.rate = rate;
  }

  try {
    port.postMessage(payload);
  } catch (error) {
    console.error("Reedah: Failed to send preview request.", error);
    finishPreviewSession(session);
    setStatus("Failed to send preview request.", true);
    return false;
  }
  return true;
}

function startPreviewForVocabEntry(index) {
  if (!Number.isInteger(index) || index < 0 || index >= vocabDraftEntries.length) {
    setStatus("Invalid custom vocabulary selection.", true);
    return;
  }

  const existing = previewSession;
  if (existing && existing.previewType === "vocab" && existing.entryIndex === index) {
    stopPreview(true);
    return;
  }

  const entry = vocabDraftEntries[index];
  startPreviewRequest({
    text: entry.spelling,
    customVocab: [entry],
    entryIndex: index,
    previewType: "vocab"
  });
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

  const customVocab = cloneCustomVocab(customVocabEntries);
  const started = startPreviewRequest({
    text,
    customVocab,
    previewType: "test"
  });
  if (started) {
    setStatus("Running test narration...");
  }
}

function updateCustomVocabSummary() {
  const count = customVocabEntries.length;
  if (count === 0) {
    vocabCountEl.textContent = "No custom words configured.";
    return;
  }
  if (count === 1) {
    vocabCountEl.textContent = "1 custom word configured.";
    return;
  }
  vocabCountEl.textContent = `${count} custom words configured.`;
}

function resetVocabEditor() {
  editingVocabIndex = null;
  vocabSpellingInput.value = "";
  vocabPronunciationInput.value = "";
  vocabAddUpdateButton.textContent = "Add Word";
}

function renderVocabList() {
  vocabListEl.textContent = "";
  if (vocabDraftEntries.length === 0) {
    const empty = document.createElement("p");
    empty.className = "vocab-list__empty";
    empty.textContent = "No vocabulary entries yet.";
    vocabListEl.appendChild(empty);
    return;
  }

  for (let index = 0; index < vocabDraftEntries.length; index += 1) {
    const entry = vocabDraftEntries[index];
    const row = document.createElement("div");
    row.className = "vocab-item";

    const text = document.createElement("div");
    const spellingCode = document.createElement("code");
    spellingCode.textContent = entry.spelling;
    const arrow = document.createTextNode(" -> ");
    const pronunciationCode = document.createElement("code");
    pronunciationCode.textContent = `/${entry.pronunciation}/`;
    text.appendChild(spellingCode);
    text.appendChild(arrow);
    text.appendChild(pronunciationCode);

    const actions = document.createElement("div");
    actions.className = "vocab-item__actions";
    const isPreviewingThisEntry =
      previewSession !== null && previewSession.entryIndex === index;

    const playButton = document.createElement("button");
    playButton.type = "button";
    playButton.dataset.action = "play";
    playButton.dataset.index = String(index);
    playButton.className = "vocab-play-button";
    playButton.textContent = isPreviewingThisEntry ? "Stop" : "Play";

    const editButton = document.createElement("button");
    editButton.type = "button";
    editButton.dataset.action = "edit";
    editButton.dataset.index = String(index);
    editButton.textContent = "Edit";

    const removeButton = document.createElement("button");
    removeButton.type = "button";
    removeButton.dataset.action = "remove";
    removeButton.dataset.index = String(index);
    removeButton.textContent = "Remove";

    actions.appendChild(playButton);
    actions.appendChild(editButton);
    actions.appendChild(removeButton);
    row.appendChild(text);
    row.appendChild(actions);
    vocabListEl.appendChild(row);
  }
}

function openVocabDialog() {
  if (!vocabDialog || typeof vocabDialog.showModal !== "function") {
    console.error("Reedah: Browser does not support HTML dialog API.");
    setStatus("Custom vocabulary dialog is unavailable in this browser.", true);
    return;
  }
  vocabDraftEntries = cloneCustomVocab(customVocabEntries);
  resetVocabEditor();
  renderVocabList();
  vocabDialog.showModal();
}

function closeVocabDialog() {
  stopPreview(true);
  if (vocabDialog.open) {
    vocabDialog.close();
  }
  resetVocabEditor();
}

function addOrUpdateVocabEntry() {
  const isAdding = editingVocabIndex == null;
  const label = isAdding ? "New entry" : `Entry ${editingVocabIndex + 1}`;
  let spelling;
  let pronunciation;
  try {
    spelling = normalizeSpelling(vocabSpellingInput.value, label);
    pronunciation = normalizePronunciation(vocabPronunciationInput.value, label);
  } catch (error) {
    setStatus(error.message, true);
    return;
  }

  const spellingKey = spelling.toLocaleLowerCase();
  const duplicateIndex = vocabDraftEntries.findIndex(
    (entry, index) =>
      entry.spelling.toLocaleLowerCase() === spellingKey && index !== editingVocabIndex
  );
  if (duplicateIndex !== -1) {
    setStatus(`Custom spelling already exists: ${spelling}`, true);
    return;
  }

  const entry = { spelling, pronunciation };
  if (isAdding) {
    vocabDraftEntries.push(entry);
  } else {
    vocabDraftEntries[editingVocabIndex] = entry;
  }
  resetVocabEditor();
  renderVocabList();
  persistCustomVocabDraft(isAdding ? "Word added." : "Word updated.");
}

function handleVocabListClick(event) {
  const button = event.target.closest("button[data-action][data-index]");
  if (!button) return;

  const index = Number(button.dataset.index);
  if (!Number.isInteger(index) || index < 0 || index >= vocabDraftEntries.length) {
    setStatus("Invalid custom vocabulary selection.", true);
    return;
  }

  const action = button.dataset.action;
  if (action === "play") {
    startPreviewForVocabEntry(index);
    return;
  }

  if (action === "edit") {
    const entry = vocabDraftEntries[index];
    editingVocabIndex = index;
    vocabSpellingInput.value = entry.spelling;
    vocabPronunciationInput.value = entry.pronunciation;
    vocabAddUpdateButton.textContent = "Update Word";
    return;
  }

  if (action === "remove") {
    stopPreview(true);
    vocabDraftEntries.splice(index, 1);
    if (editingVocabIndex === index) {
      resetVocabEditor();
    } else if (editingVocabIndex != null && editingVocabIndex > index) {
      editingVocabIndex -= 1;
    }
    renderVocabList();
    persistCustomVocabDraft("Word removed.");
  }
}

function persistCustomVocabDraft(successMessage) {
  let normalizedEntries;
  try {
    normalizedEntries = normalizeCustomVocabEntries(vocabDraftEntries);
  } catch (error) {
    setStatus(error.message, true);
    return false;
  }

  chrome.storage.local.set({ nativeCustomVocab: normalizedEntries }, () => {
    if (chrome.runtime.lastError) {
      console.error(
        "Reedah: Failed to save custom vocabulary.",
        chrome.runtime.lastError.message
      );
      setStatus("Failed to save custom vocabulary.", true);
      return;
    }
    customVocabEntries = cloneCustomVocab(normalizedEntries);
    updateCustomVocabSummary();
    if (successMessage) {
      setStatus(successMessage);
    }
  });
  return true;
}

function loadSettings() {
  chrome.storage.local.get(SETTINGS_KEYS, (items) => {
    if (chrome.runtime.lastError) {
      setStatus("Failed to load settings.", true);
      return;
    }

    voiceInput.value = normalizeVoice(items.nativeVoice);
    if (items.nativeRate == null) {
      rateInput.value = "";
    } else {
      rateInput.value = String(items.nativeRate);
    }
    try {
      customVocabEntries = normalizeCustomVocabEntries(items.nativeCustomVocab);
    } catch (error) {
      console.error("Reedah: Failed to parse custom vocabulary settings.", error);
      setStatus(`Failed to load custom vocabulary: ${error.message}`, true);
      return;
    }
    updateCustomVocabSummary();
  });
}

function persistSettings(successMessage) {
  const voice = normalizeVoice(voiceInput.value);
  voiceInput.value = voice;

  let rate = null;
  try {
    rate = parseRateInputValue();
  } catch (error) {
    setStatus(error.message, true);
    return false;
  }

  chrome.storage.local.set(
    {
      nativeVoice: voice,
      nativeRate: rate
    },
    () => {
      if (chrome.runtime.lastError) {
        console.error(
          "Reedah: Failed to auto-save settings.",
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

function handleVoiceChange() {
  persistSettings("Settings saved.");
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

    voiceInput.value = DEFAULT_VOICE;
    rateInput.value = "";
    customVocabEntries = [];
    vocabDraftEntries = [];
    resetVocabEditor();
    updateCustomVocabSummary();
    setStatus("Cleared.");
  });
}

clearButton.addEventListener("click", clearSettings);
manageVocabButton.addEventListener("click", openVocabDialog);
vocabAddUpdateButton.addEventListener("click", addOrUpdateVocabEntry);
vocabResetButton.addEventListener("click", resetVocabEditor);
vocabListEl.addEventListener("click", handleVocabListClick);
vocabCancelButton.addEventListener("click", closeVocabDialog);
testNarrateButton.addEventListener("click", handleTestNarrationClick);
voiceInput.addEventListener("change", handleVoiceChange);
rateInput.addEventListener("change", handleRateChange);
document.addEventListener("visibilitychange", () => {
  if (document.hidden) return;
  applyThemeForCurrentTime();
});

startThemeScheduler();
populateVoiceOptions();
updateCustomVocabSummary();
updateTestNarrateButtonState();
loadSettings();
