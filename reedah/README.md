# Reedah

Reedah adds paragraph narration controls to web pages in Chrome. PA3 runs Qwen3-TTS locally and streams audio through Reedah's native messaging bridge. Chrome plays the audio and handles pause, sentence navigation, highlighting, and playback speed.

Reedah lives in the PA3 repository so changes to the app, extension, and bridge can ship together. The extension remains separately loaded in Chrome; building PA3 does not install it.

## Setup on macOS

1. From the repository root, build and launch PA3 as described in the [main README](../README.md#build-and-run). Let its speech models finish downloading.
2. Open `chrome://extensions`, enable Developer mode, choose **Load unpacked**, and select this repository's **`reedah/` directory**. Do not select the repository root or `reedah/native/`.
3. Copy Reedah's extension ID and run this command from the repository root:

   ```sh
   make reedah-install EXTENSION_ID=<chrome-extension-id>
   ```

4. Open a web page, press **Alt+X** (Option+X on Mac), and use the paragraph controls. **Alt+D** pauses or resumes playback. **Test Narration** in extension options also checks playback.

The bridge requires Python 3 and uses only its standard library. Chrome launches it on demand. Keep this checkout in place: the installed native host manifest points at `reedah/native/reedah_native_host.py` here. After moving the checkout or changing the extension ID, repeat registration. If PA3 uses a custom port, set `PA3_NARRATION_PORT` in Chrome's launch environment as well.

After changing extension scripts, reload Reedah in `chrome://extensions` and refresh web pages that already contain its content script. Rebuild PA3 with `make app` and restart it after app or native helper changes.

## Existing standalone installations

All future development belongs in this repository's `reedah/` directory. An unpacked extension's ID can change when loaded from a different path; Chrome treats that as a separate installation with separate settings. Save any custom vocabulary and playback settings before removing the old installation, load this directory, and register the ID Chrome displays. Remove the old extension once the new installation works to avoid duplicate overlays.

## Voice and playback

The voice is PA3's American senior engineer. Playback speed is applied in Chrome without changing pitch. Custom vocabulary uses plain spoken spellings, for example `PA3` → `P A three`. Legacy model-specific voices and phonemes are not used.

Each complete sentence is a streaming request. Highlighting is approximate because Qwen does not supply word timestamps. Generation can fall behind playback on a busy GPU; the player then shows **Buffering** and resumes when audio is available.

## Development and tests

Run these from the repository root:

```sh
make test              # PA3 plus Reedah unit and decoder checks
make reedah-test       # Only Reedah; Node.js and Python 3 required
make browser-test      # Isolated headless Chrome; Node.js 22+ and Chrome required
make integration-test  # Live bridge and Qwen checks; PA3 must be running and idle
```

The three Reedah targets are also available inside this directory as `make test`, `make browser-test`, and `make integration-test`. Browser tests use a temporary Chrome profile, and integration tests do not play sound.

See the [bridge documentation](native/README.md) for streaming behavior and the [PA3 narration API](../README.md#local-narration) for HTTP endpoints and limits. PA3 targets macOS 14 and later; automated tests do not replace testing on an actual older Mac or a physical sleep/wake cycle.
