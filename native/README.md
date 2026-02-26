# Reedah Native Host (macOS)

Reedah uses a Python native messaging host on macOS.
Sentence audio is generated with Kokoro (`mlx-audio`) and sent to the extension for playback.
The host is started on demand by Chrome when narration begins.

## No Build Step

There is no compile/build step now. Chrome runs the Python host directly:

- `native/reedah_native_host.py`
- `native/kokoro_worker.py`

## Install (Chrome)

1. Load the extension in Chrome (Developer Mode).
2. Copy the extension ID from `chrome://extensions`.
3. Install the native host manifest:

```bash
./scripts/install_native_host.sh <chrome-extension-id>
```

The install script sets executable permissions for host and worker automatically.

That writes the manifest to:

```
~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.reedah.sayer.json
```

## Settings

Open the extension options page to configure:

- Kokoro voice (for example `am_adam`, `af_heart`)
- Speed multiplier (`0.5` to `2.0`)
- Python path for Kokoro runtime
- Model repo/path (default `mlx-community/Kokoro-82M-bf16`)
- Language code (default `a`)

Set up a local environment in this repo:

```bash
./scripts/setup_native_env.sh
```

This installs the `tts` dependency set for `mlx-audio` and runs a Python preflight check.
It also installs the required spaCy English model (`en_core_web_sm`) if missing.

To run preflight manually:

```bash
native/.venv/bin/python native/check_native_env.py
```

Default Python path used by the host:

```
native/.venv/bin/python
```

That Python environment must have `mlx-audio` installed.

## Notes

- The host runs only while narration is active.
- If the native host is not installed, the extension logs an error and stops.
- On Kokoro failures, the host logs the error to stderr, emits an error event, and stops.
