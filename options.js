const voiceInput = document.getElementById("voice");
const rateInput = document.getElementById("rate");
const statusEl = document.getElementById("status");
const saveButton = document.getElementById("save");
const clearButton = document.getElementById("clear");
const DEFAULT_VOICE = "am_adam";
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

function setStatus(message, isError = false) {
  statusEl.textContent = message;
  statusEl.style.color = isError ? "#b91c1c" : "#15803d";
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

function loadSettings() {
  chrome.storage.local.get(
    ["nativeVoice", "nativeRate"],
    (items) => {
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
    }
  );
}

function saveSettings() {
  const voice = normalizeVoice(voiceInput.value);
  const rateRaw = rateInput.value.trim();
  let rate = null;

  if (rateRaw) {
    rate = Number(rateRaw);
    if (!Number.isFinite(rate)) {
      setStatus("Speed must be a number.", true);
      return;
    }
    if (rate < 0.5 || rate > 2) {
      setStatus("Speed must be between 0.5 and 2.0.", true);
      return;
    }
  }

  chrome.storage.local.set(
    {
      nativeVoice: voice,
      nativeRate: rate
    },
    () => {
      if (chrome.runtime.lastError) {
        setStatus("Failed to save settings.", true);
        return;
      }

      setStatus("Saved.");
    }
  );
}

function clearSettings() {
  chrome.storage.local.remove(
    ["nativeVoice", "nativeRate"],
    () => {
      if (chrome.runtime.lastError) {
        setStatus("Failed to clear settings.", true);
        return;
      }

      voiceInput.value = DEFAULT_VOICE;
      rateInput.value = "";
      setStatus("Cleared.");
    }
  );
}

saveButton.addEventListener("click", saveSettings);
clearButton.addEventListener("click", clearSettings);

populateVoiceOptions();
loadSettings();
