const voiceInput = document.getElementById("voice");
const rateInput = document.getElementById("rate");
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
  chrome.storage.local.get(["nativeVoice", "nativeRate"], (items) => {
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
  });
}

function saveSettings() {
  const voice = voiceInput.value.trim();
  const rateRaw = rateInput.value.trim();
  let rate = null;

  if (rateRaw) {
    rate = Number(rateRaw);
    if (!Number.isFinite(rate)) {
      setStatus("Rate must be a number.", true);
      return;
    }
    if (rate < 0 || rate > 1) {
      setStatus("Rate must be between 0.0 and 1.0.", true);
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
  chrome.storage.local.remove(["nativeVoice", "nativeRate"], () => {
    if (chrome.runtime.lastError) {
      setStatus("Failed to clear settings.", true);
      return;
    }

    voiceInput.value = "";
    rateInput.value = "";
    setStatus("Cleared.");
  });
}

saveButton.addEventListener("click", saveSettings);
clearButton.addEventListener("click", clearSettings);

loadSettings();
