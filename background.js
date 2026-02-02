const DEFAULT_VOICE_ID = "CwhRBWXzGAHq8TQ4Fs17";

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

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || message.type !== "reedah-narrate") return;

  handleNarrationRequest(message)
    .then((response) => sendResponse(response))
    .catch((error) => {
      sendResponse({ ok: false, error: error && error.message ? error.message : "request_failed" });
    });

  return true;
});

async function handleNarrationRequest(message) {
  const text = typeof message.text === "string" ? message.text.trim() : "";
  if (!text) {
    return { ok: false, error: "empty_text" };
  }

  const settings = await getSettings();
  if (!settings.apiKey) {
    return { ok: false, error: "missing_api_key" };
  }
  const voiceId = settings.voiceId || DEFAULT_VOICE_ID;
  if (!voiceId) {
    return { ok: false, error: "missing_voice_id" };
  }

  let audioBuffer;
  try {
    audioBuffer = await fetchElevenLabsAudio({
      apiKey: settings.apiKey,
      voiceId,
      modelId: settings.modelId,
      text
    });
  } catch (error) {
    console.error("Reedah: ElevenLabs TTS request failed.", error);
    return { ok: false, error: error && error.message ? error.message : "tts_request_failed" };
  }

  console.log("Reedah: Using ElevenLabs voice:", voiceId);

  return {
    ok: true,
    mimeType: "audio/mpeg",
    audioBase64: arrayBufferToBase64(audioBuffer),
    voiceId
  };
}

function getSettings() {
  return new Promise((resolve) => {
    chrome.storage.local.get(
      ["elevenlabsApiKey", "elevenlabsVoiceId", "elevenlabsModelId"],
      (items) => {
        resolve({
          apiKey: (items.elevenlabsApiKey || "").trim(),
          voiceId: (items.elevenlabsVoiceId || "").trim(),
          modelId: (items.elevenlabsModelId || "").trim()
        });
      }
    );
  });
}

async function fetchElevenLabsAudio({ apiKey, voiceId, modelId, text }) {
  const url = `https://api.elevenlabs.io/v1/text-to-speech/${encodeURIComponent(voiceId)}`;
  const payload = { text };
  if (modelId) {
    payload.model_id = modelId;
  }

  const response = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "audio/mpeg",
      "xi-api-key": apiKey
    },
    body: JSON.stringify(payload)
  });

  if (!response.ok) {
    const errorText = await safeReadText(response);
    throw new Error(errorText || `elevenlabs_${response.status}`);
  }

  return response.arrayBuffer();
}

async function safeReadText(response) {
  try {
    return await response.text();
  } catch (error) {
    return "";
  }
}

function arrayBufferToBase64(buffer) {
  const bytes = new Uint8Array(buffer);
  const chunkSize = 0x8000;
  let binary = "";
  for (let i = 0; i < bytes.length; i += chunkSize) {
    const chunk = bytes.subarray(i, i + chunkSize);
    binary += String.fromCharCode(...chunk);
  }
  return btoa(binary);
}
