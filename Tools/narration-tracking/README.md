# Narration tracking experiment

This standalone prototype generates each fixture as **one paragraph in one Qwen request**, runs timestamped Whisper recognition on overlapping audio windows, and aligns the recognized words to the known source. It does not change PA3, restart it, capture a microphone, or play audio. Both models run in separate processes on the same machine. They can compete with PA3 for GPU resources.

Requires PA3's downloaded Qwen and Whisper models, the built `.build/native/pa3-narrator`, the bundled p311 reference, Python 3.9+, and `/opt/homebrew/bin/whisper-server`. No Python packages are required. Processes and logs belong to the experiment; child processes are terminated on exit.

```sh
python3 -m unittest discover -s Tools/narration-tracking -p 'test_*.py'
node Tools/narration-tracking/test_highlight.js
python3 Tools/narration-tracking/prototype.py --output /tmp/pa3-tracking
# Run recognition while Qwen is generating, to measure actual contention:
python3 Tools/narration-tracking/prototype.py --output /tmp/pa3-tracking-live --only technical --concurrent
# Reprocess existing audio without running Qwen:
python3 Tools/narration-tracking/prototype.py --output /tmp/pa3-tracking --reuse-audio
```

Open `index.html` in the output directory to listen with a moving three-word highlight. A per-sample selector offers two words, three words, five words, or a whole sentence. Groups stay within sentence boundaries and retain spaces and punctuation. `results.json` includes source matches, observed timestamps, processing times, Qwen chunk arrivals, and a calculated startup buffer. WAVs, original PCM, and unmodified Whisper responses are retained for inspection.

## Method and limits

- Whisper large-v3-turbo, English, `-ml 1 -sow`, no supplied text prompt. Recognition is independent of the expected passage; source text is used only afterward for matching.
- A new recognition window ends every 4 seconds; each window includes at most the preceding 12 seconds. A 0.6-second trailing margin is excluded until more context is available.
- Local edit alignment is bounded by previously recognized source positions. Repeated phrases select the earliest equally good position in that region. Only exact normalized word matches are retained. This is a prototype heuristic, not a confidence-calibrated aligner.
- First accepted timestamps are frozen so later recognition cannot silently improve the displayed result. Recognition output is available before playback only if generation runs far enough ahead.
- Word-match coverage is **not timestamp accuracy**. The full-clip recognition pass is an offline comparison, not human-annotated ground truth. Word timing is Whisper's experimental estimate; token splits and zero-duration timestamps can occur.
- The default run measures generation and recognition sequentially. Its calculated buffer is a simulation that excludes simultaneous GPU contention. `--concurrent` measures real completion times while both models are working, but still calculates the playback buffer rather than starting a live player.
- Timing excludes model startup and loading. Model processes remain warm between fixture paragraphs. User activity can change results.
- Tests cover monotonic matching, repeated phrases, recognition errors, and sample-rate conversion. Fixtures include ordinary prose, technical terms, and repeated sentences. No dictionary-substitution/source mapping is implemented in this isolated experiment; fixture text is already the intended spoken text.

This is a feasibility experiment, not an enabled narration feature. Accurate word highlighting, multilingual behavior, skipped/repeated synthesized words, model-startup cost, sustained contention, and streaming recovery need separate evaluation before integration.
