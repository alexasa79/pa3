import Foundation

private final class RecoveryTestWorker: NarrationWorker {
    let id = UUID()
    let onEvent: @Sendable (UUID, TTSWorkerEvent) -> Void
    var requests: [(text: String, path: URL, seed: Int)] = []
    var stopped = false
    init(_ onEvent: @escaping @Sendable (UUID, TTSWorkerEvent) -> Void) { self.onEvent = onEvent }
    func start() throws {}
    func stop() { stopped = true }
    func generate(id: String, text: String, voice: String, language: String, instruct: String?, path: URL, pause: Double, seed: Int) {
        requests.append((text, path, seed))
    }
    func emit(_ event: TTSWorkerEvent) { onEvent(id, event) }
}

@MainActor
func runNarrationRecoveryTests() async -> Int32 {
    var workers: [RecoveryTestWorker] = []
    let service = NarrationService(isConfigured: { true }) { callback in
        let worker = RecoveryTestWorker(callback)
        workers.append(worker)
        return worker
    }
    defer { service.shutdown() }
    var failures: [String] = []
    service.onSelectionFailure = { failures.append($0) }
    func settle() async { try? await Task.sleep(for: .milliseconds(30)) }
    let text = "Done. The reader is now compact."
    let body = try! JSONSerialization.data(withJSONObject: ["text": text])
    guard service.narrateSelection(SelectedTextResult(text: text, message: "")).status == 202, workers.count == 1 else { return 1 }
    workers[0].emit(TTSWorkerEvent(event: "ready"))
    await settle()
    guard workers[0].requests.count == 1, workers[0].requests[0].text == "Done." else { return 1 }
    let original = workers[0].requests[0]
    workers[0].emit(TTSWorkerEvent(event: "error", error: "The speech model returned silence.", retryable: true))
    await settle()
    guard workers.count == 2, workers[0].stopped, service.hasNarration, failures.isEmpty else { return 1 }
    // A late exit from the replaced process must not cancel the retry.
    workers[0].emit(TTSWorkerEvent(event: "exit", error: "Old worker exited"))
    workers[1].emit(TTSWorkerEvent(event: "ready"))
    await settle()
    guard workers[1].requests.count == 1, service.hasNarration else { return 1 }
    let retry = workers[1].requests[0]
    guard retry.text == original.text, retry.path == original.path, retry.seed != original.seed else { return 1 }
    workers[1].emit(TTSWorkerEvent(event: "error", error: "The speech model returned silence.", retryable: true))
    await settle()
    guard workers.count == 2, workers[1].stopped, !service.hasNarration, failures.count == 1 else { return 1 }
    // The next user request gets a fresh retry budget and can still be cancelled.
    guard service.submit(body).status == 202, workers.count == 3 else { return 1 }
    workers[2].emit(TTSWorkerEvent(event: "ready"))
    await settle()
    guard workers[2].requests.first?.seed == original.seed else { return 1 }
    service.stopAll()
    workers[2].emit(TTSWorkerEvent(event: "error", error: "Late silence", retryable: true))
    await settle()
    guard !service.hasNarration, workers.count == 3 else { return 1 }
    print("PASS silent output retries the same passage once, ignores stale events, and respects cancellation")
    return 0
}
