# Reedah Native Host (macOS)

Reedah uses a native messaging host on macOS to call the system `say` command.
Each sentence is rendered to audio via `say -o` (AAC in M4A) and sent to the extension for playback.
The host is started on demand by Chrome when narration begins.

## Build

```bash
./scripts/build_native_host.sh
```

This produces:

```
native/bin/reedah-sayer
```

## Install (Chrome)

1. Load the extension in Chrome (Developer Mode).
2. Copy the extension ID from `chrome://extensions`.
3. Install the native host manifest:

```bash
./scripts/install_native_host.sh <chrome-extension-id>
```

That writes the manifest to:

```
~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.reedah.sayer.json
```

## Settings

Open the extension options page to set an optional voice name (as accepted by `say -v`).
Rate is a 0.0–1.0 slider mapped to `say -r` (words per minute).
If no voice is set, the system default voice is used.

## Notes

- The host runs only while narration is active.
- If the native host is not installed, the extension logs an error and stops.
