# pa3

Native macOS personal assistant dictation app copied from `pa2`.

## Build and Run

```sh
make app
open PA3.app
```

`make app` builds the SwiftUI app, initializes and incrementally builds the `whisper.cpp` submodule, and links local model assets. If this checkout is next to `../pa2`, it reuses `../pa2/models` by symlink unless local models already exist.

The app stays resident after paste. Use `Ctrl+Option+Command+P` to show it again, or use the menu-bar waveform icon.

## Runtime Notes

- `Enter`: paste current transcript into the previously active app and hide PA3.
- `q`, `Esc`, `Ctrl+C`: discard and hide PA3.
- `Space`: pause/resume dictation.
- The audio capture callback feeds a bounded queue while a separate worker drains accumulated audio and talks to Whisper, matching the important `pa2` threading model.
- macOS may prompt for Microphone and Accessibility permissions. Accessibility is needed for paste automation through System Events.
