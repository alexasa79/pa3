const voiceInput = document.getElementById("voice");
const rateInput = document.getElementById("rate");
const pythonPathInput = document.getElementById("python-path");
const modelInput = document.getElementById("model");
const langCodeInput = document.getElementById("lang-code");
const statusEl = document.getElementById("status");
const saveButton = document.getElementById("save");
const clearButton = document.getElementById("clear");

function setStatus(message, isError = false) {
  statusEl.textContent = message;
  statusEl.style.color = isError ? "#b91c1c" : "#15803d";
  if (!message) return;

  window.clearTimeout(setStatus._timer);
  setStatus._timer = window.setTimeout(() => {
    statusEl.textContent = "";
  }, 2000);
}

function loadSettings() {
  chrome.storage.local.get(
    ["nativeVoice", "nativeRate", "nativePythonPath", "nativeModel", "nativeLangCode"],
    (items) => {
      if (chrome.runtime.lastError) {
        setStatus("Failed to load settings.", true);
        return;
      }

      voiceInput.value = items.nativeVoice || "";
      if (items.nativeRate == null) {
        rateInput.value = "";
      } else {
        rateInput.value = String(items.nativeRate);
      }
      pythonPathInput.value = items.nativePythonPath || "";
      modelInput.value = items.nativeModel || "";
      langCodeInput.value = items.nativeLangCode || "";
    }
  );
}

function saveSettings() {
  const voice = voiceInput.value.trim();
  const rateRaw = rateInput.value.trim();
  const pythonPath = pythonPathInput.value.trim();
  const model = modelInput.value.trim();
  const langCode = langCodeInput.value.trim();
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
      nativeRate: rate,
      nativePythonPath: pythonPath,
      nativeModel: model,
      nativeLangCode: langCode
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
    ["nativeVoice", "nativeRate", "nativePythonPath", "nativeModel", "nativeLangCode"],
    () => {
      if (chrome.runtime.lastError) {
        setStatus("Failed to clear settings.", true);
        return;
      }

      voiceInput.value = "";
      rateInput.value = "";
      pythonPathInput.value = "";
      modelInput.value = "";
      langCodeInput.value = "";
      setStatus("Cleared.");
    }
  );
}

saveButton.addEventListener("click", saveSettings);
clearButton.addEventListener("click", clearSettings);

loadSettings();
