# PA3 workflow

After changes to the app, run the appropriate tests, rebuild with `make app`, and restart PA3 so the user can use the updated build immediately. This is the user's standing preference; do not require a separate rebuild or restart request unless the user explicitly asks to defer it.

Quit the running app cleanly using its bundle identifier `com.local.pa3`, wait for it to exit, then launch this checkout's `PA3.app`. Verify that the new process is running from that bundle and that startup completed successfully.

# Dictation context design

The configured context duration (28 seconds by default) is a **lower threshold for trimming eligibility**, not an upper limit on the audio window or a deadline to cut. After reaching that threshold, trim only at a verified completed sentence boundary with an acoustic pause. If no suitable boundary exists, preserve the audio and let the clip grow, including through 60–70 seconds or longer. Never split an unfinished sentence or restore a 28/29.5-second request ceiling just to meet the context setting.

Keep regression coverage for unfinished sentences extending beyond the threshold. Publish validated live text before boundary verification, and keep verification bounded so disputed cuts cannot create a long retry chain that stalls live updates. `make transcription-scheduling-test` checks publication order and bounded verification.

# Whisper dictionary prompting

Use one dictionary-guided Whisper request per ordinary live update. Supply the custom dictionary as a plain comma-separated glossary ending in a period to preserve sentence punctuation. Do not add a `vocabulary:` heading followed by a fabricated transcript/punctuation example: that combination reproducibly injected glossary words into saved recordings. Do not reintroduce an unprompted comparison decode on every update as a workaround. Preserve prompt-format and single-request regression tests, and check recorded prefix cases when changing prompting.
