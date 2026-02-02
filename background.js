const DEFAULT_VOICE_ID = "CwhRBWXzGAHq8TQ4Fs17";
const STREAM_ENDPOINT = "https://api.elevenlabs.io/v1/text-to-speech";

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

chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== "reedah-stream") return;

  let abortController = null;
  let streaming = false;

  port.onMessage.addListener(async (message) => {
    if (!message || typeof message.type !== "string") return;

    if (message.type === "abort") {
      if (abortController) {
        abortController.abort();
      }
      return;
    }

    if (message.type !== "start" || streaming) return;

    const text = typeof message.text === "string" ? message.text.trim() : "";
    if (!text) {
      port.postMessage({ type: "error", error: "empty_text" });
      return;
    }

    const settings = await getSettings();
    if (!settings.apiKey) {
      port.postMessage({ type: "error", error: "missing_api_key" });
      return;
    }

    const voiceId = settings.voiceId || DEFAULT_VOICE_ID;
    if (!voiceId) {
      port.postMessage({ type: "error", error: "missing_voice_id" });
      return;
    }

    streaming = true;
    abortController = new AbortController();

    try {
      console.log("Reedah: Using ElevenLabs voice:", voiceId);

      await streamElevenLabsAudio({
        apiKey: settings.apiKey,
        voiceId,
        modelId: settings.modelId,
        text,
        signal: abortController.signal,
        onStart: (mimeType) => {
          port.postMessage({ type: "start", mimeType, voiceId });
        },
        onChunk: (chunk) => {
          port.postMessage({ type: "chunk", data: chunk });
        },
        onEnd: () => {
          port.postMessage({ type: "end" });
        }
      });
    } catch (error) {
      if (!abortController.signal.aborted) {
        console.error("Reedah: ElevenLabs streaming failed.", error);
        port.postMessage({
          type: "error",
          error: error && error.message ? error.message : "streaming_failed"
        });
      }
    }
  });

  port.onDisconnect.addListener(() => {
    if (abortController) {
      abortController.abort();
    }
  });
});

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

async function streamElevenLabsAudio({
  apiKey,
  voiceId,
  modelId,
  text,
  signal,
  onStart,
  onChunk,
  onEnd
}) {
  const url = `${STREAM_ENDPOINT}/${encodeURIComponent(voiceId)}/stream`;
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
    body: JSON.stringify(payload),
    signal
  });

  if (!response.ok) {
    const errorText = await safeReadText(response);
    throw new Error(errorText || `elevenlabs_${response.status}`);
  }

  const mimeType = response.headers.get("content-type") || "audio/mpeg";
  if (onStart) onStart(mimeType);

  if (!response.body) {
    throw new Error("missing_stream_body");
  }

  const reader = response.body.getReader();
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    if (value && value.length) {
      const chunk = uint8ToBase64(value);
      if (onChunk) onChunk(chunk);
    }
  }

  if (onEnd) onEnd();
}

async function safeReadText(response) {
  try {
    return await response.text();
  } catch (error) {
    return "";
  }
}

function uint8ToBase64(bytes) {
  const chunkSize = 0x8000;
  let binary = "";
  for (let i = 0; i < bytes.length; i += chunkSize) {
    const chunk = bytes.subarray(i, i + chunkSize);
    binary += String.fromCharCode(...chunk);
  }
  return btoa(binary);
}
