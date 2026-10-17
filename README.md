# pa3

Native macOS dictation and narration, with the PA3 Chrome extension for reading web pages aloud. PA3 runs Whisper and Qwen locally; the extension requests narration through a small native messaging bridge and plays the audio in Chrome.

Press `Space` to pause dictation or resume into a new paragraph. Press `o` to start a new paragraph, or `O` (Shift+O) to continue dictating at the end of the current, last paragraph without a paragraph break. While already dictating, `O` leaves dictation running unchanged.

Use **Shortcuts** in the toolbar or press `?` to show or hide the complete, grouped keyboard reference. Opening it pauses dictation; closing it with `?`, Escape, or its close button resumes dictation if it was active before opening. If dictation was already paused, it stays paused. Scroll to see all commands, including editing and global shortcuts; commands stay listed even when unavailable in the current state. In a text editor, `?` remains ordinary text. Dictation detects the spoken language automatically for each audio clip; no language selection is needed, and transcription stays in the spoken language rather than translating to English.

Hebrew paragraphs display right to left using native bidirectional text layout. English phrases and numbers within Hebrew retain their normal order, and English paragraphs remain left to right. Whisper's detected language travels with each transcription and supplies the direction hint for text without strong letters, such as a paragraph containing only numbers. Arrow keys follow the displayed words; copying/pasting preserves the original logical text order.

While dictation is paused, press `t` to cycle the current word through lowercase → initial capital → uppercase → lowercase. Existing capitalization determines the next form; mixed casing resets to lowercase. Punctuation stays intact. `a` appends text after the selection; `i` or `I` inserts before it.

Deleting with `x` conservatively cleans up the deletion boundary: orphan commas, semicolons and colons at a paragraph start, separators newly adjacent to a sentence stop (such as `.,`), and newly doubled separators. A plain lowercase word exposed at a clear sentence or paragraph start receives an initial capital. Acronyms, mixed casing, dotted abbreviations, common abbreviations, and ambiguous boundaries are preserved. Existing ellipses and combinations such as `?!` are left alone.

Press `u` to undo the last transcript edit, restoring its text and selection. A deletion and its automatic cleanup undo together. Repeated presses step backward through up to 100 edits, including capitalization, insertion, replacement, repeat change, paragraph joins/splits, clipboard insertion, and completed spell checks. Undo history resets when a new session or dictation begins. In the text editor, `u` is ordinary text. Cleanup runs only on deletion, never on paste, manual replacement/insertion, or `t`, so you can retain unusual punctuation or capitalization. Abbreviation detection is conservative but cannot identify every lowercase abbreviation; use `t` or manual editing to correct its choice.

After replacing `foo` with `bar`, `.` replaces the current selection with `bar`, while `>` replaces every remaining matching `foo` with `bar`. Matching is case-sensitive and uses whole tokens or selected phrases, preserving surrounding punctuation and paragraph boundaries. `.` does not change the original rule remembered for `>`. Bulk replacement is one undoable edit; replacement text is not recursively processed during the same command.

## Repository layout

- `Sources/`, `Native/`, and `Resources/`: the PA3 macOS app and native speech helper.
- `chrome-extension/`: the Chrome extension, Python native messaging bridge, and extension tests.
- `Tools/` and `Tests/`: app setup and validation tools.

The Chrome extension is a regular directory in this repository. Its original Git history is preserved; there is no submodule or separate checkout to update. App and extension changes can be reviewed and committed together while keeping their builds separate.

## Build and Run

```sh
brew install whisper.cpp
make app
open PA3.app
```

`brew install whisper.cpp` installs the native `whisper-server` and its llama.cpp dependency. PA3 finds Homebrew tools even when launched from Finder. No Python environment or source submodule is required. `make app` builds and signs PA3 and its small native narrator helper, linked against Homebrew's public libllama/libmtmd APIs. The streaming helper requires the validated llama.cpp 0.4.1 decoder and rejects other versions with a clear startup error. When validating a newer version, inspect the decoder window semantics, update the compatibility guard, and require `make decoder-test` to pass before distributing the build. Rebuild PA3 after changes to the Homebrew libraries.

On launch, PA3 detects missing speech models and opens a download window with overall byte progress and each model’s status. It downloads Whisper large-v3-turbo and Qwen3-TTS 1.7B Base Q8_0, including its audio encoder/decoder, into `~/Library/Application Support/PA3/models`. Downloads are pinned to revisions and verified with SHA-256. Total model data is approximately 3.9 GB. `make speech-setup` remains available for terminal setup and reuses a matching `models/whisper.ggml` from an existing checkout. Repeating terminal setup verifies existing files without downloading them again. `make clean` leaves installed models intact.

On another Mac, install the Homebrew prerequisite, copy the built app, and launch it. PA3 downloads any missing models automatically. The app bundle contains the selected voice reference and has no links back to this checkout. Open **Speech models…** from the menu bar to view progress. Cancel stops the current download; Retry keeps completed models and restarts the incomplete file. Downloads are verified before being installed, so failed transfers cannot replace a working model. Closing the progress window leaves the download running. Setup never opens the microphone. Start dictation after its model is ready. Narration requests received before their models are installed return HTTP 503 and can be retried after setup; `GET /health` includes download status and progress. Set `PA3_MODEL_DIR` for a custom model directory in both setup and the app environment, or `PA3_WHISPER_MODEL` for a custom transcription model.

The app is signed with a local self-signed code-signing identity named `PA3 Local Code Signing Trusted`. `make app` creates and trusts that identity in your login keychain if it is missing. To skip the keychain identity and use ad-hoc signing for a one-off local build:

```sh
make SIGN_IDENTITY=- app
```

The app stays resident after paste. Use `Ctrl+Option+Command+P` to show it again, or use the menu-bar waveform icon.

To change the three global shortcuts, right-click PA3's menu-bar icon and choose **Keyboard shortcuts…**. Click a shortcut and press the new combination, then choose **Save**. Include Control, Option, or Command. Escape cancels recording; Cancel discards edits. **Restore defaults** fills in the original combinations for review before saving. PA3 remembers saved shortcuts across launches and reports duplicate or unavailable combinations. Opening settings pauses active dictation.

## Testing

Run `make test` from this repository's root to check both PA3 and its Chrome extension. It requires the Homebrew speech tools, installed Qwen models, Node.js, and Python 3. The app checks include segmentation, HTTP framing, pronunciation, model-backed streaming decoder comparisons, model download integrity, interrupted transfers, cancellation, retry, and the missing-model microphone guard. The extension checks cover text extraction, highlighting, audio playback, and native bridge lifecycle.

| Command | Scope |
| --- | --- |
| `make test` | PA3 checks plus Chrome extension JavaScript and Python tests. |
| `make pa3-test` | PA3 checks only. |
| `make transcription-scheduling-test` | Deterministic live-preview scheduling regression; no model server or microphone needed. |
| `make extension-test` | Chrome extension JavaScript and Python tests only; no running app or models needed. |
| `make browser-test` | Audio, paragraph detection, and highlighting in isolated headless Chrome; requires Node.js 22+ and Chrome. Set `CHROME` for a custom executable. |
| `make integration-test` | Chrome extension bridge → running PA3 → real Qwen audio, including flow control and independent cancellation. Run with PA3 ready and idle; this does not play sound. |

See [Chrome extension setup](chrome-extension/README.md) to install the extension and register its native bridge. Browser and live-model integration checks are explicit targets because they need Chrome or a running PA3 instance.

`make transcription-scheduling-test` supplies fixed recognition responses that disagree at a boundary. It measures publication order using simulated request time, without sleeping or running Whisper. It checks that validated live text is published before boundary verification, verification is bounded per round, and unchanged rejected boundaries are not retried.

`make replay-test` pushes spoken clips through the real transcription worker and checks that every cut lands in silence and that the words match the reference. Clips are built with the macOS `say` command by `make fixtures` and land in `Tests/fixtures`, together with `.txt` files holding the words spoken. The test needs the Homebrew speech tools and installed Whisper model. It uses recorded audio without opening the microphone.

Every dictation session is recorded in full to `~/.cache/pa3/rec` (or `$XDG_CACHE_HOME/pa3/rec`; set `PA3_RECORDING_DIR` to change it). To replay one:

```sh
PA3_INSTALL_DIR=$(pwd) .build/debug/pa3 --replay ~/.cache/pa3/rec/2026-09-06T10-00-00.wav --speed 4
```

Add `--reference file.txt` to compare against known text. Without it, the replay compares against a one-shot transcription of the whole clip when it is under 30 seconds. `--speed 1` paces the audio like a live session, which changes how much audio each Whisper round sees.

`--context-seconds N` sets the minimum window duration before sentence trimming becomes eligible (5–28 seconds; default 28). Unfinished sentences may extend beyond this threshold.

## Dictionaries

Open **Dictionaries…** from PA3’s menu-bar menu without starting dictation. The **Transcription** tab edits the words and phrases Whisper should recognize; the dictation toolbar’s Dictionary button and `D` open this tab. The **Narration** tab stores written-text → spoken-pronunciation entries shared by selected-text narration, HTTP narration, and the extension. Use **Add entry**, edit either field, **Preview** to listen without saving, and **Save** to persist changes. **Stop preview** stops narration. Transcription vocabulary and narration pronunciations are stored separately.

Narration matching ignores case, matches whole words or phrases, prefers longer phrases, and does not recursively substitute replacements. Dictionary substitutions run before filename, identifier, and comparison-symbol pronunciation. Request-specific `pronunciations` override saved entries with the same written text; previews do not alter the saved dictionary. Up to 100 entries are stored in `~/Library/Application Support/PA3/narration-dictionary.json`.

## Read selected text

Select text in another app and press **Ctrl+Option+Command+O**. PA3 reads it through macOS Accessibility and narrates it using VCTK p311. Press the same shortcut again to stop and cancel queued narration, including while speech is being generated or a selection is being read. The menu bar also has **Read selection / Stop**. The shortcut leaves focus in the source app and does not open the microphone or use the clipboard.

PA3 needs Accessibility permission in System Settings → Privacy & Security → Accessibility. Some apps do not expose selected text. In that case PA3 shows a brief notice instead of copying text or reading the whole document. Selection reads are bounded and limited to 100,000 characters. Stop dictation before using narration.

To read a screen rectangle, including in apps such as Kindle that do not expose selected text, press **Ctrl+Option+Command+R** or choose **Read screen rectangle / Stop** from the menu bar. Release the shortcut keys, drag a rectangle around the text, and release the mouse to narrate it. Press **Escape** to cancel the picker; either narration shortcut or **Stop narration** cancels pending recognition and stops speech. Stop dictation before starting screen narration. The selected-text shortcut remains separate: an unavailable selection shows a notice and never opens the rectangle picker.

On first use, allow PA3 in **System Settings → Privacy & Security → Screen Recording** (called **Screen & System Audio Recording** on newer macOS versions). Reopen PA3 if macOS requests it, then retry the shortcut. OCR runs locally with Apple Vision; the temporary screenshot is deleted after recognition. Select one column at a time for predictable reading order. Small, blurry, or protected screen content may not be readable. No text found, permission failures, and capture failures show a notice instead of starting speech.

Narration plays in the background without a reader window or changing the original app's selection. If the speech model returns silence, PA3 retries once. A failed selection narration shows a brief notice.

## Local narration

Narration skips parenthesized single file/path references with a colon and line number, such as `(src/file.swift:42)`. Line ranges and optional columns also qualify. PA3 also skips complete parenthetical groups containing an `http://`, `https://`, or `www.` link, including Markdown links such as `(see [docs](https://example.org))`. This applies to selected terminal text and API narration. Ordinary parenthetical explanations, nested prose without links, and unmatched parentheses remain spoken. Source text and highlighting positions are unchanged.

Narration reads filenames and paths explicitly, including underscores, `:line:column` references, and line ranges such as `file.c:100-200` ("file dot C, lines 100 to 200"). Standalone identifiers such as `type_name_t` read as "type underscore name underscore tee", with single-letter parts pronounced by their letter names. See the [supported file extensions and pronunciation rules](FileExtensions.md).

PA3 accepts narration requests on `127.0.0.1:65462` while it is running, including when its window is hidden. Its default narrator is **VCTK p311, an American male speaker from Iowa**, identified as `vctk-p311`. Native llama.cpp runs Qwen3-TTS 1.7B Base Q8_0 on the Apple Silicon GPU, using the selected recording as its voice reference. The reference is used at its natural pitch and speed. PA3 plays narration at 1.1× using AVAudioPlayer’s pitch-preserving rate adjustment. Exported audio and streams remain at the generated speed; the extension applies its own playback-speed setting. It is from the CSTR VCTK Corpus, by Junichi Yamagishi, Christophe Veaux, and Kirsten MacDonald (University of Edinburgh), licensed under CC BY 4.0. Source details and license are bundled in `Resources/Voices/`.

PA3 installs missing models automatically with a progress window. `make tts-setup` remains an alias for the same setup. The selected recording and provenance are in `Resources/Voices` and copied into the app. Narration runs offline after setup.

PA3 preloads Qwen in a persistent native helper once models are installed and keeps the weights on the GPU between requests. It prepares up to three pieces ahead of playback and limits the opening piece to 160 characters. Each piece is generated before playback, so startup still depends on its length. Generation can fall behind on a busy GPU. Excess silence at piece edges is trimmed, targeting 200 ms between sentences, 400 ms between list items, and 650 ms between paragraphs and before/after lists. A colon introducing a list gets the full list-boundary pause. Numeric labels stay with their sentence; bullet symbols are not spoken. Blank lines and Unicode paragraph separators mark paragraphs. A new unindented line after a complete sentence also starts a paragraph, while unfinished lines can wrap. For ambiguous unpunctuated lists, use a blank line after the list. Interior pauses are preserved. The generated voice can differ from the reference recording.

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

Optional JSON fields are `voice`, `language`, `instruct`, `mode`, and `pronunciations`. Defaults are `vctk-p311`, `English`, and `enqueue`. Omitting `voice` uses p311; `"voice":"p311"` and `"voice":"vctk-p311"` select it explicitly. Use `mode: "replace"` to cancel existing narration before speaking the new text. The default inherits its delivery from the saved reference recording. Nonempty `instruct` returns 422 because this native runtime has no delivery-instruction option. `pronunciations` maps literal written words or phrases to spoken spellings; matches are case-insensitive and do not replace parts of larger words. Longer matching phrases win, and substitutions do not run recursively.

The previous named preset voices and `Auto` language are no longer supported and return 422. Languages are English, Russian, Chinese, Japanese, Korean, German, French, Portuguese, Spanish, and Italian. Hebrew is unsupported. Voice and language names are case-insensitive.

The extension can request `"output":"audio"` to generate a WAV without PA3 playing it. This mode accepts up to 4,000 characters per request. Poll the job until `completed`, then fetch `/v1/narrations/ID/audio` with the same bearer token. The response is `audio/wav`; DELETE the job after downloading to release the file. Audio expires after five minutes, and exports are limited to 32 MiB per job and 128 MiB of retained/generated audio. `pieces_generated` reports generation progress; `pieces_played` stays zero for audio-only jobs. The default `"output":"playback"` keeps normal PA3 playback. Audio-only completion means generation finished, not that a client has played the audio.

For paragraph narration with source timings, send `"output":"stream","timing":"words"`. PA3 joins sentences within each paragraph up to 600 spoken characters per generation. A private Whisper worker recognizes overlapping audio windows locally; each published PCM block includes `word_timings` with `start`/`end` in seconds from the start of the job and `location`/`length` in UTF-16 units of the original request. Dictionary and pronunciation expansions keep their original source ranges. Chunks wait for recognition before publication. Timings are estimates, and unmatched words may have no individual timing. If alignment is uncertain, audio continues with no new timings and highlighting holds its last reliable position until recognition recovers. Cold model loading and recognition add startup latency. Plain streaming requests without `timing` retain sentence generation.

The opt-in `--narration-timing-live-test` runs paragraph generation and recognition in a separate process without an HTTP listener or playback. From the checkout, use `PA3_INSTALL_DIR="$PWD/PA3.app/Contents/Resources" .build/debug/pa3 --narration-timing-live-test` after building. It requires installed Qwen and Whisper models.

The extension's Chrome native messaging bridge uses this API and keeps the token outside the browser. Chrome handles playback, pause, navigation, and speed. The bridge requires only Python 3's standard library; Qwen runs exclusively in PA3. Follow [Chrome extension setup](chrome-extension/README.md) to install it. The [bridge documentation](chrome-extension/native/README.md) describes streaming and playback flow control.

Jobs can be queued, loading, generating, playing, completed, cancelled, or failed. Completion means playback finished. Generation can overlap playback. History keeps the latest 100 jobs in memory; restarting clears it. The queue holds ten waiting jobs, plus one active job. Requests allow 100,000 text characters and 512 KB of JSON. Queue overflow returns 429; invalid fields return 422; missing runtime files return 503.

Starting dictation cancels narration. While dictation is active or its audio output is being restored, new narration requests return 409. PA3 preserves the user's system mute and volume settings. Press **Ctrl+Option+Command+O** again, use the menu bar's **Stop narration** item, or use the stop endpoint to interrupt speech.

`make test` includes HTTP framing, Unicode splitting, and pronunciation tests. To exercise the running app with queue, playback, and cancellation tests, run `make narration-test`. This plays short test phrases and cancels outstanding narration jobs.

## Dictation controls

- `Enter`: paste current transcript into the previously active app and hide PA3.
- `q`, `Esc`, `Ctrl+C`: discard and hide PA3.
- `Space`: pause/resume dictation.
- `Context`: minimum window duration before trimming is eligible (5–28 seconds; default 28). This is a lower threshold, not an input ceiling: an unfinished sentence may continue through 60–70 seconds or longer. PA3 trims only completed sentences at acoustic pauses, checking the retained opening and committed head. Live text is published before those checks. Each round attempts at most one sentence boundary with two verification requests; a disagreement preserves provisional text and audio, and an unchanged rejected head is skipped until the wording or available sentence boundaries change. Each ordinary update makes one dictionary-guided recognition request. The prompt contains only the comma-separated glossary ending in a period, without a heading or invented punctuation example; the old combination caused glossary-prefix hallucinations in saved recordings. Startup retains one second of pre-roll and requires sustained speech activity; silence does not trigger repeated transcription. Full session recordings retain the original timeline.
- The audio capture callback feeds a bounded queue while a separate worker drains accumulated audio and talks to Whisper, matching the important `pa2` threading model.
- macOS may prompt for Microphone and Accessibility permissions. Accessibility is needed for paste automation through System Events.

For immediate client playback, use `"output":"pieces"`. Job status includes `audio_pieces`, an ordered array of ready pieces with `start`/`end` fractions of the submitted text (UTF-16 positions, for approximate highlighting). Fetch each `/v1/narrations/ID/audio/INDEX` as soon as it appears, including while the job is `generating`. Each response is a standalone WAV. `pieces` gives the total count; apply sentence pauses only after the last piece. This mode has the same authentication, limits, deletion, and five-minute retention as audio export. This mode remains available for clients that need standalone WAV pieces.

The `pieces` mode splits long sentences at clause punctuation (commas, semicolons, colons, and em dashes). The opening and following character budgets are soft targets; phrases without clause punctuation stay together. Sentence endings of up to 40 characters stay attached to the preceding clause rather than becoming a tiny final piece. Startup can take longer for long uninterrupted sentences.

For true incremental audio, use `"output":"stream"`. PA3 passes each whole sentence to Qwen and decodes audio during generation without resetting sentence context. Poll `audio_chunks` in job status; each entry has `samples` and `sample_rate`. Download new entries from `/v1/narrations/ID/chunks/INDEX` as `application/octet-stream`: mono little-endian float32 PCM at 24 kHz. Blocks are contiguous and immutable, with only initial silence trimmed. Completion marks the end of the audio stream; clients must consume every published block before finishing playback and then DELETE the job. The same export size limits and five-minute retention apply. The extension uses this mode and schedules blocks with Web Audio; the older punctuation-based `pieces` mode remains available to API clients.

The Homebrew llama.cpp 0.4.1 Qwen decoder advances state in fixed 72-frame windows (about 5.76 seconds of audio). PA3 publishes only complete windows during generation and flushes a short remainder only at sentence end. Calling the decoder on shorter intermediate blocks corrupts subsequent audio because its state includes padding. This limits safe startup latency on the current backend. `make test` includes publication boundaries and model-backed waveform comparisons against full-window decoding with identical codec frames. `make decoder-test` runs just these compatibility checks. Both need the models installed by PA3 or `make speech-setup`; use `PA3_MODEL_DIR=/path/to/models` for a custom location. The fixture also reproduces the old short-window corruption, so a passing comparison alone cannot hide a broken test.
