# pa3

Native macOS personal assistant dictation app copied from `pa2`.

## Build and Run

```sh
make app
open PA3.app
```

`make app` builds the SwiftUI app, initializes and incrementally builds the `whisper.cpp` submodule, and links local model assets. If this checkout is next to `../pa2`, it reuses `../pa2/models` by symlink unless local models already exist.

The app is signed with a local self-signed code-signing identity named `PA3 Local Code Signing Trusted`. `make app` creates and trusts that identity in your login keychain if it is missing. To skip the keychain identity and use ad-hoc signing for a one-off local build:

```sh
make SIGN_IDENTITY=- app
```

The app stays resident after paste. Use `Ctrl+Option+Command+P` to show it again, or use the menu-bar waveform icon.

## Testing

`make test` builds and runs the unit tests, including the segmentation rules that decide where live audio is cut.

`make replay-test` pushes spoken clips through the real transcription worker and checks that every cut lands in silence and that the words match the reference. Clips are built with the macOS `say` command by `make fixtures` and land in `Tests/fixtures`, together with `.txt` files holding the words spoken. The test needs whisper-server built and a model in `models`.

Every dictation session is recorded in full to `~/.cache/pa3/rec` (or `$XDG_CACHE_HOME/pa3/rec`; set `PA3_RECORDING_DIR` to change it). To replay one:

```sh
PA3_INSTALL_DIR=$(pwd) .build/debug/pa3 --replay ~/.cache/pa3/rec/2026-09-06T10-00-00.wav --speed 4
```

Add `--reference file.txt` to compare against known text. Without it, the replay compares against a one-shot transcription of the whole clip when it is under 30 seconds. `--speed 1` paces the audio like a live session, which changes how much audio each Whisper round sees.

`--context-seconds N` sets the replay audio duration limit (5–28 seconds; default 28).

## Runtime Notes

- `Enter`: paste current transcript into the previously active app and hide PA3.
- `q`, `Esc`, `Ctrl+C`: discard and hide PA3.
- `Space`: pause/resume dictation.
- `Context`: audio duration limit in seconds (5–28; default 28). No sentence-count limit is used. When the clip exceeds the setting, PA3 removes audio through the earliest suitable sentence boundary that gets the remaining clip below the limit. If no suitable sentence boundary exists, it uses the earliest sufficient pause, or a minimal time cut when there is no pause. The old sentence-count preference is ignored.
- The audio capture callback feeds a bounded queue while a separate worker drains accumulated audio and talks to Whisper, matching the important `pa2` threading model.
- macOS may prompt for Microphone and Accessibility permissions. Accessibility is needed for paste automation through System Events.
