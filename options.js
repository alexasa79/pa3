const apiKeyInput = document.getElementById("api-key");
const modelIdInput = document.getElementById("model-id");
const statusEl = document.getElementById("status");
const saveButton = document.getElementById("save");
const clearButton = document.getElementById("clear");

const DEFAULT_MODEL_ID = "eleven_multilingual_v2";

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
    ["elevenlabsApiKey", "elevenlabsModelId"],
    (items) => {
      if (chrome.runtime.lastError) {
        setStatus("Failed to load settings.", true);
        return;
      }

      apiKeyInput.value = items.elevenlabsApiKey || "";
      modelIdInput.value = items.elevenlabsModelId || "";
      if (!modelIdInput.value) {
        modelIdInput.value = DEFAULT_MODEL_ID;
      }
    }
  );
}

function saveSettings() {
  const apiKey = apiKeyInput.value.trim();
  const modelId = modelIdInput.value.trim();

  chrome.storage.local.set(
    {
      elevenlabsApiKey: apiKey,
      elevenlabsModelId: modelId
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
    ["elevenlabsApiKey", "elevenlabsModelId"],
    () => {
      if (chrome.runtime.lastError) {
        setStatus("Failed to clear settings.", true);
        return;
      }

      apiKeyInput.value = "";
      modelIdInput.value = DEFAULT_MODEL_ID;
      setStatus("Cleared.");
    }
  );
}

saveButton.addEventListener("click", saveSettings);
clearButton.addEventListener("click", clearSettings);

loadSettings();
