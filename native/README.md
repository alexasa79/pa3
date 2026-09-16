# Reedah → PA3 bridge (macOS)

Reedah uses PA3's persistent Qwen3-TTS model. Chrome plays the returned audio, preserving pause/resume, sentence navigation, highlighting, and playback speed. There is no separate speech server or model environment.

1. Build and start PA3 with the progressive audio-pieces API, and let its speech models finish downloading.
2. Load this directory as an unpacked extension in `chrome://extensions` (or reload the existing extension). Accept the native messaging permission.
3. Copy its extension ID and run `./scripts/install_native_host.sh <extension-id>`.
4. Enable Reedah on a web page with Alt+X and use its paragraph narration controls. Test Narration in extension options is also available.

The bridge uses Python 3's standard library only. Chrome launches it on demand; it connects to PA3 on `127.0.0.1:65462` and reads `~/Library/Application Support/PA3/narration-token`. The token stays outside the extension and web pages. No localhost browser permissions or CORS exceptions are needed. If using a custom PA3 port, set `PA3_NARRATION_PORT` in Chrome's launch environment too.

The voice is PA3's American senior engineer. Speed is applied during browser playback. Custom vocabulary now uses plain spoken spellings (for example, `PA3` → `P A three`). Old model-specific voice, speed, and phoneme settings are not imported; configure them again in options.

Playback starts when the opening audio piece is ready, while the remainder of the sentence is still being generated. Each original sentence is sent as an `output: pieces` PA3 job (up to 4,000 characters); the bridge polls every 50 ms and transfers each ready WAV in bounded native messages. Chrome queues the pieces without a sentence pause between them. Highlight progress is estimated from each piece's text fraction, including when custom vocabulary changes spoken text length. The server files are deleted after the sentence is transferred. PA3 never plays these jobs itself. Closing the tab or stopping narration cancels only that connection's current job. Errors are logged and narration stops; there is no alternate speech engine. Downloads expire on PA3 after five minutes if a client disappears.
