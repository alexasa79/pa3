# Sentence tracking prototype — measured results

Three whole-paragraph samples were generated with Qwen3-TTS and p311, then analyzed with Whisper large-v3-turbo. A fourth run generated the technical paragraph while Whisper processed incoming audio concurrently. PA3 was left running; no microphone or app state was changed. Other activity could affect timings.

| Sample | Audio seconds | Qwen generation seconds | Windowed ASR seconds | Source words matched across windows | Largest boundary difference vs full-clip ASR (seconds) |
|---|---:|---:|---:|---:|---:|
| plain | 16.0 | 7.2 | 2.4 | 100% | 0.46 |
| technical | 25.2 | 9.1 | 3.6 | 100% | 1.10 |
| repeated | 19.3 | 16.3 | 2.5 | 100% | 0.16 |
| technical-concurrent | 26.0 | 12.3 | 4.3 | 100% | 0.16 |

Recognition windows cover up to 12 seconds of audio, advancing 4 seconds each time. Model loading is excluded. All generation uses entire paragraphs, not stitched sentence audio.

The concurrent run matched all 59 source words across its overlapping windows. It produced 26 seconds of speech in 12.3 seconds while recognizing it. Individual ASR requests took approximately 0.5–1.0 seconds. The observed delivery times imply a roughly 3.1-second initial playback buffer at normal speed would have made both audio and sentence timestamps available on time in this run. This is a calculated replay, not a live playback/stall measurement.

Whole-sentence highlighting is the intended UI: open index.html and play the technical-concurrent sample. The display freezes each sentence's first accepted timestamp rather than using later full-clip results to improve it.

The full-clip comparison is NOT independent ground truth. High text coverage does not establish timestamp accuracy, and the default word timestamps are experimental. Sequential technical estimates differed by up to 1.1 seconds; the concurrent sample differed by at most 0.16 seconds. These small samples support feasibility, not a general accuracy guarantee. Repeated phrases did not cause source-position jumps in this fixture.

No automatic migration into the app has been made. Before integration: verify a broader collection, measure at 1.1× and 1.5× playback, handle uncertainty/repeated or omitted speech, and preserve dictionary-to-document source mapping. No app rebuild/restart was necessary because only prototype tools were added.
