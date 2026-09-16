# pa3

Native macOS personal assistant dictation app copied from `pa2`.

## Build and Run

```sh
brew install whisper.cpp
make app
open PA3.app
```

`brew install whisper.cpp` installs the native `whisper-server` and its llama.cpp dependency. PA3 finds Homebrew tools even when launched from Finder. No Python environment or source submodule is required. `make app` builds and signs PA3 and its small native narrator helper, linked against Homebrew's public libllama/libmtmd APIs. The helper was tested with llama.cpp 0.4.0. Rebuild PA3 after a Homebrew update that changes those APIs or library compatibility.

On launch, PA3 detects missing speech models and opens a download window with overall byte progress and each model’s status. It downloads Whisper large-v3-turbo and Qwen3-TTS 1.7B Base Q8_0, including its audio encoder/decoder, into `~/Library/Application Support/PA3/models`. Downloads are pinned to revisions and verified with SHA-256. Total model data is approximately 3.9 GB. `make speech-setup` remains available for terminal setup and reuses a matching `models/whisper.ggml` from an existing checkout. Repeating terminal setup verifies existing files without downloading them again. `make clean` leaves installed models intact.

On another Mac, install the Homebrew prerequisite, copy the built app, and launch it. PA3 downloads any missing models automatically. The app bundle contains the selected voice reference and has no links back to this checkout. Open **Speech models…** from the menu bar to view progress. Cancel stops the current download; Retry keeps completed models and restarts the incomplete file. Downloads are verified before being installed, so failed transfers cannot replace a working model. Closing the progress window leaves the download running. Setup never opens the microphone. Start dictation after its model is ready. Narration requests received before their models are installed return HTTP 503 and can be retried after setup; `GET /health` includes download status and progress. Set `PA3_MODEL_DIR` for a custom model directory in both setup and the app environment, or `PA3_WHISPER_MODEL` for a custom transcription model.

The app is signed with a local self-signed code-signing identity named `PA3 Local Code Signing Trusted`. `make app` creates and trusts that identity in your login keychain if it is missing. To skip the keychain identity and use ad-hoc signing for a one-off local build:

```sh
make SIGN_IDENTITY=- app
```

The app stays resident after paste. Use `Ctrl+Option+Command+P` to show it again, or use the menu-bar waveform icon.

## Testing

`make test` builds and runs unit tests and a local HTTP download fixture. It checks segmentation, model download progress, integrity verification, interrupted transfers, cancellation, retry, and the missing-model microphone guard.

`make replay-test` pushes spoken clips through the real transcription worker and checks that every cut lands in silence and that the words match the reference. Clips are built with the macOS `say` command by `make fixtures` and land in `Tests/fixtures`, together with `.txt` files holding the words spoken. The test needs the Homebrew speech tools and installed Whisper model. It uses recorded audio without opening the microphone.

Every dictation session is recorded in full to `~/.cache/pa3/rec` (or `$XDG_CACHE_HOME/pa3/rec`; set `PA3_RECORDING_DIR` to change it). To replay one:

```sh
PA3_INSTALL_DIR=$(pwd) .build/debug/pa3 --replay ~/.cache/pa3/rec/2026-09-06T10-00-00.wav --speed 4
```

Add `--reference file.txt` to compare against known text. Without it, the replay compares against a one-shot transcription of the whole clip when it is under 30 seconds. `--speed 1` paces the audio like a live session, which changes how much audio each Whisper round sees.

`--context-seconds N` sets the replay audio duration limit (5–28 seconds; default 28).

## Read selected text

Select text in another app and press **Ctrl+Option+Command+N**. PA3 reads it through macOS Accessibility and narrates it using sample 4. Press the same shortcut again to stop and cancel queued narration, including while speech is being generated or a selection is being read. The menu bar also has **Read selection / Stop**. The shortcut leaves focus in the source app and does not open the microphone or use the clipboard.

PA3 needs Accessibility permission in System Settings → Privacy & Security → Accessibility. Some apps do not expose selected text. In that case PA3 shows a brief notice instead of copying text or reading the whole document. Selection reads are bounded and limited to 100,000 characters. Stop dictation before using narration.

Narration plays in the background without a reader window or changing the original app's selection. If the speech model returns silence, PA3 retries once. A failed selection narration shows a brief notice.

## Local narration

PA3 accepts narration requests on `127.0.0.1:65462` while it is running, including when its window is hidden. Its default narrator is **sample 4, the American senior engineer**, identified as `senior-engineer-american`. Native llama.cpp runs Qwen3-TTS 1.7B Base Q8_0 on the Apple Silicon GPU, using the selected recording as its voice reference.

PA3 installs missing models automatically with a progress window. `make tts-setup` remains an alias for the same setup. The selected recording and provenance are in `Resources/Voices` and copied into the app. Narration runs offline after setup.

PA3 preloads Qwen in a persistent native helper once models are installed and keeps the weights on the GPU between requests. It prepares up to three pieces ahead of playback and limits the opening piece to 160 characters. Each piece is generated before playback, so startup still depends on its length. Generation can fall behind on a busy GPU. Excess silence at piece edges is trimmed, targeting 200 ms between sentences, 400 ms between list items, and 650 ms between paragraphs and before/after lists. A colon introducing a list gets the full list-boundary pause. Numeric labels stay with their sentence; bullet symbols are not spoken. Blank lines and Unicode paragraph separators mark paragraphs. A new unindented line after a complete sentence also starts a paragraph, while unfinished lines can wrap. For ambiguous unpunctuated lists, use a blank line after the list. Interior pauses are preserved. The existing reference remains sample 4, but the native implementation can render it differently from the earlier MLX experiment.

Send text with curl:

```sh
TOKEN=$(cat "$HOME/Library/Application Support/PA3/narration-token")
curl -s http://127.0.0.1:65462/v1/narrations \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"text":"PA3 is ready to narrate.","pronunciations":{"PA3":"P A three"}}'
```

The response is HTTP 202 with a job `id` and its current `state`. Accepted jobs continue if curl disconnects. Short pieces play in sequence while PA3 generates upcoming pieces. Cancelling an in-flight generation stops its worker; PA3 reloads it in the background when dictation is idle.

| Request | Result |
| --- | --- |
| `GET /health` | Configuration, runtime readiness, dictation status, and queue depth. `model_loaded` becomes true after preloading. No token required. |
| `POST /v1/narrations` | Queue text for playback. |
| `GET /v1/narrations/ID` | Job state, number of pieces generated/played, and audio availability. |
| `GET /v1/narrations/ID/audio` | Download WAV for a completed audio-only job. |
| `DELETE /v1/narrations/ID` | Cancel a queued or active job. |
| `POST /v1/narrations/stop` with `{}` | Stop playback and cancel all queued jobs. |

All job endpoints require the bearer token. POST requests require JSON and a Content-Length, as curl supplies above. Browser cross-origin requests, chunked request bodies, and HTTP pipelining are rejected. The listener binds only to IPv4 loopback. Set `PA3_NARRATION_PORT` in the app process environment to change its port.

Optional JSON fields are `voice`, `language`, `instruct`, `mode`, and `pronunciations`. Defaults are `senior-engineer-american`, `English`, and `enqueue`. Omitting `voice` uses sample 4; `"voice":"4"` and `"voice":"04-senior-engineer-american"` select it explicitly. Use `mode: "replace"` to cancel existing narration before speaking the new text. The default inherits its delivery from the saved reference recording. Nonempty `instruct` returns 422 because this native runtime has no delivery-instruction option. `pronunciations` maps literal written words or phrases to spoken spellings; matches are case-sensitive and do not replace parts of larger words. Longer matching phrases win, and substitutions do not run recursively.

The previous named preset voices and `Auto` language are no longer supported and return 422. Languages are English, Russian, Chinese, Japanese, Korean, German, French, Portuguese, Spanish, and Italian. Hebrew is unsupported. Voice and language names are case-insensitive.

Reedah can request `"output":"audio"` to generate a WAV without PA3 playing it. This mode accepts up to 4,000 characters per request. Poll the job until `completed`, then fetch `/v1/narrations/ID/audio` with the same bearer token. The response is `audio/wav`; DELETE the job after downloading to release the file. Audio expires after five minutes, and exports are limited to 32 MiB per job and 128 MiB of retained/generated audio. `pieces_generated` reports generation progress; `pieces_played` stays zero for audio-only jobs. The default `"output":"playback"` keeps normal PA3 playback. Audio-only completion means generation finished, not that a client has played the audio.

Reedah's Chrome native messaging bridge uses this API and keeps the token outside the browser. Chrome handles playback, pause, navigation, and speed. The bridge requires only Python 3's standard library; Qwen runs exclusively in PA3. Install the bridge and reload the extension as described in Reedah's `native/README.md`.

Jobs can be queued, loading, generating, playing, completed, cancelled, or failed. Completion means playback finished. Generation can overlap playback. History keeps the latest 100 jobs in memory; restarting clears it. The queue holds ten waiting jobs, plus one active job. Requests allow 100,000 text characters and 512 KB of JSON. Queue overflow returns 429; invalid fields return 422; missing runtime files return 503.

Starting dictation cancels narration. While dictation is active or its audio output is being restored, new narration requests return 409. PA3 preserves the user's system mute and volume settings. Press **Ctrl+Option+Command+N** again, use the menu bar's **Stop narration** item, or use the stop endpoint to interrupt speech.

`make test` includes HTTP framing, Unicode splitting, and pronunciation tests. To exercise the running app with queue, playback, and cancellation tests, run `make narration-test`. This plays short test phrases and cancels outstanding narration jobs.

## Dictation controls

- `Enter`: paste current transcript into the previously active app and hide PA3.
- `q`, `Esc`, `Ctrl+C`: discard and hide PA3.
- `Space`: pause/resume dictation.
- `Context`: audio duration limit in seconds (5–28; default 28). No sentence-count limit is used. When the clip exceeds the setting, PA3 removes audio through the earliest suitable sentence boundary that gets the remaining clip below the limit. If no suitable sentence boundary exists, it uses the earliest sufficient pause, or a minimal time cut when there is no pause. The old sentence-count preference is ignored.
- The audio capture callback feeds a bounded queue while a separate worker drains accumulated audio and talks to Whisper, matching the important `pa2` threading model.
- macOS may prompt for Microphone and Accessibility permissions. Accessibility is needed for paste automation through System Events.

For immediate client playback, use `"output":"pieces"`. Job status includes `audio_pieces`, an ordered array of ready pieces with `start`/`end` fractions of the submitted text (UTF-16 positions, for approximate highlighting). Fetch each `/v1/narrations/ID/audio/INDEX` as soon as it appears, including while the job is `generating`. Each response is a standalone WAV. `pieces` gives the total count; apply sentence pauses only after the last piece. This mode has the same authentication, limits, deletion, and five-minute retention as audio export. Reedah uses this mode so it can play the opening clause while Qwen generates the rest of the sentence.

Progressive narration splits long sentences at clause punctuation (commas, semicolons, colons, and em dashes). The opening and following character budgets are soft targets; phrases without clause punctuation stay together. Sentence endings of up to 40 characters stay attached to the preceding clause rather than becoming a tiny final piece. Startup can take longer for long uninterrupted sentences.
