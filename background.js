const DEFAULT_VOICE_ID = "TX3LPaxmHKxFdv7VOQHJ";
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

    const voiceId = DEFAULT_VOICE_ID;
    if (!voiceId) {
      port.postMessage({ type: "error", error: "missing_voice_id" });
      return;
    }

    streaming = true;
    abortController = new AbortController();

    try {
      console.log("Reedah: Using ElevenLabs voice:", voiceId);

      await streamElevenLabsAudioWithTimestamps({
        apiKey: settings.apiKey,
        voiceId,
        modelId: settings.modelId,
        text,
        signal: abortController.signal,
        onStart: () => {
          port.postMessage({ type: "start", mimeType: "audio/mpeg", voiceId });
        },
        onAudioChunk: (chunk) => {
          port.postMessage({ type: "chunk", data: chunk });
        },
        onAlignment: (alignment, normalizedAlignment) => {
          port.postMessage({
            type: "alignment",
            alignment: alignment || null,
            normalizedAlignment: normalizedAlignment || null
          });
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
    } finally {
      streaming = false;
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
      ["elevenlabsApiKey", "elevenlabsModelId"],
      (items) => {
        resolve({
          apiKey: (items.elevenlabsApiKey || "").trim(),
          modelId: (items.elevenlabsModelId || "").trim()
        });
      }
    );
  });
}

async function streamElevenLabsAudioWithTimestamps({
  apiKey,
  voiceId,
  modelId,
  text,
  signal,
  onStart,
  onAudioChunk,
  onAlignment,
  onEnd
}) {
  const url = `${STREAM_ENDPOINT}/${encodeURIComponent(voiceId)}/stream/with-timestamps`;
  const payload = { text };
  if (modelId) {
    payload.model_id = modelId;
  }

  const response = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "xi-api-key": apiKey
    },
    body: JSON.stringify(payload),
    signal
  });

  if (!response.ok) {
    const errorText = await safeReadText(response);
    throw new Error(errorText || `elevenlabs_${response.status}`);
  }

  if (onStart) onStart();

  if (!response.body) {
    throw new Error("missing_stream_body");
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    if (!value || !value.length) continue;
    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split("\n");
    buffer = lines.pop() || "";
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      const payloadLine = trimmed.startsWith("data:")
        ? trimmed.slice(5).trim()
        : trimmed;
      try {
        const payload = JSON.parse(payloadLine);
        if (payload.audio_base64 && onAudioChunk) {
          onAudioChunk(payload.audio_base64);
        }
        if ((payload.alignment || payload.normalized_alignment) && onAlignment) {
          onAlignment(payload.alignment, payload.normalized_alignment);
        }
      } catch (error) {
        console.error("Reedah: Failed to parse streaming payload.", error);
      }
    }
  }

  const leftover = buffer.trim();
  if (leftover) {
    const payloadLine = leftover.startsWith("data:") ? leftover.slice(5).trim() : leftover;
    try {
      const payload = JSON.parse(payloadLine);
      if (payload.audio_base64 && onAudioChunk) {
        onAudioChunk(payload.audio_base64);
      }
      if ((payload.alignment || payload.normalized_alignment) && onAlignment) {
        onAlignment(payload.alignment, payload.normalized_alignment);
      }
    } catch (error) {
      console.error("Reedah: Failed to parse streaming payload.", error);
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

// Streaming with timestamps returns base64 audio directly in JSON payloads.
