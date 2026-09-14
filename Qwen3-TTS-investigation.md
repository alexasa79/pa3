# Qwen3-TTS integration proposal

Historical research, superseded by the native Homebrew integration in README.md. The Python worker described below has been removed.

Investigated September 12, 2026. This is a proposal based on repository inspection and upstream documentation. No model was installed or benchmarked, and no application code was changed.

I recommend Qwen3-TTS-12Hz-1.7B-CustomVoice through Python MLX-Audio, running as a persistent worker managed by PA3. PA3 would accept local HTTP requests and play the generated audio. This Mac has an Apple M3 Max, 128 GiB of memory, and macOS 26.6.2. Memory capacity makes the larger model a reasonable starting point; response time still needs measurement.

The relevant released models are:

| Qwen3-TTS variant | Use in PA3 |
| --- | --- |
| 1.7B CustomVoice | Recommended starting point. Nine preset voices and natural-language delivery instructions. |
| 0.6B CustomVoice | Compare for latency. Nine preset voices; Qwen does not list instruction control for this variant. |
| 0.6B or 1.7B Base | Voice cloning using reference audio. Optional future feature. |
| 1.7B VoiceDesign | Generate a voice from a description. Optional future feature. |

These distinctions come from the [official Qwen3-TTS repository](https://github.com/QwenLM/Qwen3-TTS). It lists ten languages, including English and Russian, but not Hebrew. PA3's Hebrew dictation setting therefore cannot imply Hebrew narration support. Ryan and Aiden are English preset voices worth auditioning. Qwen publishes the project under Apache 2.0.

For Apple Silicon, use the community MLX conversion `mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit`. Its complete repository is approximately [3.08 GB](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit/tree/main). The [0.6B 8-bit conversion is 1.97 GB](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit/tree/main). These are download sizes, not peak memory measurements.

[MLX-Audio](https://github.com/Blaizzy/mlx-audio) documents Qwen3-TTS generation and streaming on Apple Silicon. Its [Qwen implementation](https://github.com/Blaizzy/mlx-audio/blob/main/mlx_audio/tts/models/qwen3_tts/qwen3_tts.py) accepts a voice, language, instructions, and streaming interval. Keep one loaded model and serialize inference. Pin both the runtime and model revision after testing.

A native Swift runtime is possible, but I would defer it. The [Swift Qwen port inspected](https://github.com/AtomGradient/swift-qwen3-tts) requires macOS 15+, and its documented stream emits tokens followed by a final waveform, rather than playable audio chunks. Python MLX-Audio offers the more direct first implementation. Its existing [HTTP speech endpoint](https://github.com/Blaizzy/mlx-audio/blob/main/mlx_audio/server.py) returns generated audio; PA3 still needs its own playback and job management.

PA3 currently has no incoming narration server. Its relevant existing lifecycle is:

```text
applicationDidFinishLaunching(...): // Sources/PA3/AppDelegate.swift:18, creates the controller and transcriber
    DictationController(transcriber:): // Sources/PA3/DictationController.swift:99, connects dictation state
startDictation(): // Sources/PA3/DictationController.swift:404, begins a microphone session
    duckOutput(): // Sources/PA3/DictationController.swift:91, actually mutes system output
    startTranscribe(...): // Sources/PA3/TranscriberService.swift:185, prepares capture and Whisper
        ensureWhisperServerStarted(...): // Sources/PA3/TranscriberService.swift:753, coordinates startup
            startWhisperServer(...): // Sources/PA3/TranscriberService.swift:704, manages a child process on port 65461
applicationWillTerminate(...): // Sources/PA3/AppDelegate.swift:44, shuts down app services
    shutdown(): // Sources/PA3/DictationController.swift:146, closes dictation
```

The proposed implementation would add four components:

- `NarrationHTTPServer` binds explicitly to `127.0.0.1:65462`, configurable through settings. It starts at app launch and remains available while PA3 is hidden. A port conflict reports an error without breaking dictation.
- `NarrationController` owns a bounded FIFO queue, job states, cancellation, and dictation coordination. Network handlers acknowledge requests immediately; inference never runs on the main actor.
- `TTSWorkerService` starts an isolated Python environment with pinned MLX-Audio dependencies. A small worker loads the selected model once. Use framed messages over child-process pipes for commands and PCM audio, with diagnostic logs on stderr. Include job IDs, audio format, sequence numbers, completion, and error messages. No second public port is needed.
- `NarrationPlayer` feeds PCM buffers to `AVAudioEngine` and `AVAudioPlayerNode`. It handles buffering, output-device changes, and stop. Add a menu item to stop narration and show whether a job is waiting, loading, or speaking.

Proposed client request, after implementation:

```sh
curl http://127.0.0.1:65462/v1/narrations \
  -H "Authorization: Bearer $PA3_NARRATION_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"text":"The build has finished.","voice":"Ryan","language":"English","mode":"enqueue"}'
```

| Endpoint | Behavior |
| --- | --- |
| `POST /v1/narrations` | Return `202` with a job ID and state. Speak through this Mac's output. |
| `GET /v1/narrations/{id}` | Return queued, loading, generating, playing, completed, cancelled, or failed. Generation and playback can overlap. |
| `DELETE /v1/narrations/{id}` | Cancel that queued or active job. |
| `POST /v1/narrations/stop` | Stop playback and cancel all outstanding jobs. |
| `GET /health` | Report server identity, worker readiness, selected model, and queue depth. |

Default to enqueue. An explicit `mode: "replace"` cancels active and queued narration before accepting the new job. Disconnecting after acceptance does not cancel a job. Mark completed only after playback finishes. Keep job history in memory with a bounded retention limit.

Accept plain UTF-8 text and optional delivery instructions. Split long passages at sentence or paragraph boundaries, with a maximum chunk size for punctuation-free input. Preserve wording; never silently truncate at the model's generation limit. Start playback from early audio chunks while generating ahead, with bounded buffering and backpressure.

Use configurable limits, initially 100,000 text characters per request and ten queued jobs. Return clear validation, oversized-request, and queue-full errors. Validate voices and languages against the loaded model. Keep the model selection in PA3 settings rather than accepting arbitrary model paths from callers. Require a locally stored bearer token, reject browser cross-origin requests by default, and avoid logging narration text.

Dictation needs explicit coordination. New narration should wait while the microphone is active. Starting dictation should stop narration playback immediately and suspend that job until dictation ends. Resume at a saved sentence boundary if buffered audio was discarded. The current `stopDictation()` returns before microphone shutdown finishes, and capture shutdown is itself asynchronous. Add a completion signal for actual capture shutdown and output-route restoration before resuming narration. Preserve the user's original mute setting.

Store models and the worker environment outside `PA3.app`, which `make app` replaces. Download during explicit setup, then run from pinned local files. Warm the worker in the background when narration is enabled. On worker failure, stop playback, mark the affected job failed, and restart with bounded retries. A cancellation must discard late audio by job ID; if generation cannot stop promptly, terminate and reload the owned worker. Quit must close the listener and child process.

Before implementation is considered ready:

1. Benchmark both CustomVoice sizes with short alerts and several minutes of English and Russian prose. Measure cold load, warm time to first audible audio, generation time divided by audio duration, peak memory, and playback underruns. Listen for omissions, pronunciation, and sentence-boundary artifacts. [Qwen's advertised 97 ms latency](https://github.com/QwenLM/Qwen3-TTS) is not a measured result for this Mac or runtime.
2. Validate queue order, replace, cancellation during loading and playback, malformed and oversized requests, port conflicts, and worker crashes. Exercise speakers and Bluetooth output through dictation transitions.
3. Run PA3's existing tests and relevant new tests, rebuild with `make app`, cleanly quit `com.local.pa3`, and launch this checkout's `PA3.app`. Verify the new process, successful startup, HTTP acceptance, and audible narration.

The first implementation should keep voice cloning and voice design out of the setup flow. Preset-voice narration is enough to establish the API, audio behavior, and performance.
