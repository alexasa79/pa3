# Reedah → PA3 bridge (macOS)

Reedah uses PA3's persistent Qwen3-TTS model. Chrome plays the returned audio, preserving pause/resume, sentence navigation, highlighting, and playback speed. There is no separate speech server or model environment.

1. Build and start PA3 with the streaming PCM API, and let its speech models finish downloading.
2. Load this directory as an unpacked extension in `chrome://extensions` (or reload the existing extension). Accept the native messaging permission.
3. Copy its extension ID and run `./scripts/install_native_host.sh <extension-id>`.
4. Enable Reedah on a web page with Alt+X and use its paragraph narration controls. Test Narration in extension options is also available.

The bridge uses Python 3's standard library only. Chrome launches it on demand; it connects to PA3 on `127.0.0.1:65462` and reads `~/Library/Application Support/PA3/narration-token`. The token stays outside the extension and web pages. No localhost browser permissions or CORS exceptions are needed. If using a custom PA3 port, set `PA3_NARRATION_PORT` in Chrome's launch environment too.

The voice is PA3's American senior engineer. Speed is applied during browser playback. Custom vocabulary now uses plain spoken spellings (for example, `PA3` → `P A three`). Old model-specific voice, speed, and phoneme settings are not imported; configure them again in options.

Reedah sends each complete sentence as an `output: stream` job (up to 4,000 characters). PA3 returns incremental mono float32 PCM while Qwen continues generating the same sentence. The bridge polls every 50 ms, forwards only new PCM blocks, and sends an explicit sentence-end event. Web Audio schedules adjacent blocks continuously, with no text splits or pauses between blocks. Pause, resume, replay, sentence navigation and settings previews share the streaming player. Playback speed uses streaming waveform-similarity overlap/add to preserve pitch; 1× playback passes samples through unchanged. Word highlighting remains approximate even after the duration is known: Qwen does not supply word timestamps. A starved or interrupted player shows “Buffering” and resumes from the same audio position when more audio or the audio device becomes available. Generation can still fall behind playback on a busy GPU.

The bridge validates PCM lengths and ordering and deletes each job after transfer. PA3 never plays these jobs itself. Closing the tab or stopping narration cancels only that connection's current job. Errors are logged and narration stops; there is no alternate speech engine. Downloads expire on PA3 after five minutes if a client disappears.

The browser acknowledges sentences after playback or skip. The bridge allows at most two unconsumed sentences per active paragraph; next-paragraph prefetch starts with one and expands to two when activated. Pausing playback stops further sentence submissions once these slots are occupied. Already-started sentences finish generating. Two previous sentences are retained for replay. The shared per-page audio budget is 32 MiB for retained PCM and scheduled Web Audio copies (temporary transfer/processing allocations are additional). Exceeding this limit fails explicitly instead of growing without bound.

Validation:

- `node --test tests/*.test.js` and `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s native -p 'test_*.py'` run the automated unit and lifecycle checks.
- `node tests/run-browser-test.mjs` renders four playback speeds in real headless Chrome using an isolated temporary profile. Set `CHROME` to override the executable path.
- With PA3 running and idle, `PYTHONDONTWRITEBYTECODE=1 python3 native/live_stream_check.py` checks real model output, playback flow control and independent cancellation for two bridge connections. It does not play sound.
- PA3's `make test` includes the model-backed decoder compatibility regression. The native helper rejects unvalidated llama.cpp versions.

PA3 targets macOS 14 and later. These automated tests do not replace validation on an actual older Mac or a physical sleep/wake cycle. After changing extension scripts, reload Reedah in `chrome://extensions` and refresh pages that already have its content script loaded.
