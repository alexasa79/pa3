import Foundation
import AVFoundation

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
    return await runNarrationExportTests()
}

@MainActor
private func runNarrationExportTests() async -> Int32 {
    var workers: [RecoveryTestWorker] = []
    let service = NarrationService(isConfigured: { true }, token: "test-token") { callback in
        let worker = RecoveryTestWorker(callback)
        workers.append(worker)
        return worker
    }
    defer { service.shutdown() }
    func request(_ method: String, _ path: String, authorized: Bool = true) -> NarrationHTTPResponse {
        service.handle(NarrationHTTPRequest(method: method, path: path,
            headers: authorized ? ["authorization": "Bearer test-token"] : [:], body: Data()))
    }
    do {
        let body = try JSONSerialization.data(withJSONObject: ["text": "First. Second.", "output": "audio"])
        let response = service.submit(body)
        guard response.status == 202,
              let job = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let id = job["id"] as? String else { return 1 }
        let path = "/v1/narrations/\(id)"
        guard request("GET", path + "/audio", authorized: false).status == 401,
              request("GET", path + "/audio").status == 404 else { return 1 }
        workers[0].emit(TTSWorkerEvent(event: "ready"))
        try await Task.sleep(for: .milliseconds(30))
        // Synthetic WAVs verify ordered concatenation without model downloads or playback.
        for index in 0..<2 {
            guard workers[0].requests.count == index + 1 else { return 1 }
            let generated = workers[0].requests[index]
            let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240)!
            buffer.frameLength = 240
            for frame in 0..<240 { buffer.floatChannelData![0][frame] = index == 0 ? 0.1 : 0.2 }
            do {
                let file = try AVAudioFile(forWriting: generated.path, settings: format.settings)
                try file.write(from: buffer)
            }
            workers[0].emit(TTSWorkerEvent(event: "audio", id: id, path: generated.path.path))
            try await Task.sleep(for: .milliseconds(30))
        }
        let status = try JSONSerialization.jsonObject(with: request("GET", path).body) as! [String: Any]
        guard status["state"] as? String == "completed", status["pieces_played"] as? Int == 0,
              status["pieces_generated"] as? Int == 2, !service.hasNarration else { return 1 }
        let audio = request("GET", path + "/audio")
        guard audio.status == 200, audio.contentType == "audio/wav", audio.body.starts(with: Data("RIFF".utf8)) else { return 1 }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("pa3-export-test-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try audio.body.write(to: temporary)
        let file = try AVAudioFile(forReading: temporary)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 480)!
        try file.read(into: buffer)
        guard file.length == 480, abs(buffer.floatChannelData![0][0] - 0.1) < 0.001,
              abs(buffer.floatChannelData![0][240] - 0.2) < 0.001 else { return 1 }
        guard request("DELETE", path).status == 200, request("GET", path + "/audio").status == 404 else { return 1 }
        let oversized = try JSONSerialization.data(withJSONObject: ["text": String(repeating: "x", count: 4001), "output": "audio"])
        guard service.submit(oversized).status == 422 else { return 1 }
        let second = service.submit(body)
        let secondJob = try JSONSerialization.jsonObject(with: second.body) as! [String: Any]
        let secondID = secondJob["id"] as! String
        guard request("DELETE", "/v1/narrations/\(secondID)").status == 200, workers[0].stopped,
              !service.hasNarration else { return 1 }
        print("PASS audio export auth, ordered WAV, no local playback, deletion, limits, and cancellation")
        return await runNarrationPieceTests()
    } catch {
        print("FAIL audio export: \(error)")
        return 1
    }
}

@MainActor
private func runNarrationPieceTests() async -> Int32 {
    var worker: RecoveryTestWorker!
    let service = NarrationService(isConfigured: { true }, token: "test-token") { callback in
        worker = RecoveryTestWorker(callback)
        return worker
    }
    defer { service.shutdown() }
    func request(_ method: String, _ path: String) -> NarrationHTTPResponse {
        service.handle(NarrationHTTPRequest(method: method, path: path,
            headers: ["authorization": "Bearer test-token"], body: Data()))
    }
    do {
        let body = try JSONSerialization.data(withJSONObject: ["text": "First. Second.", "output": "pieces"])
        let response = service.submit(body)
        let job = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
        let id = job["id"] as! String, path = "/v1/narrations/\(id)"
        worker.emit(TTSWorkerEvent(event: "ready"))
        try await Task.sleep(for: .milliseconds(30))
        for index in 0..<2 {
            guard request("GET", path + "/audio/\(index)").status == 404 else { return 1 }
            let generated = worker.requests[index]
            try Data("RIFFpiece\(index)".utf8).write(to: generated.path)
            worker.emit(TTSWorkerEvent(event: "audio", id: id, path: generated.path.path))
            try await Task.sleep(for: .milliseconds(30))
            let status = try JSONSerialization.jsonObject(with: request("GET", path).body) as! [String: Any]
            let pieces = status["audio_pieces"] as! [[String: Double]]
            guard pieces.count == index + 1, pieces[index]["start"]! < pieces[index]["end"]!,
                  status["state"] as? String == (index == 0 ? "generating" : "completed"),
                  status["pieces_played"] as? Int == 0,
                  request("GET", path + "/audio/\(index)").body == Data("RIFFpiece\(index)".utf8),
                  request("GET", path + "/audio/-1").status == 404 else { return 1 }
        }
        guard request("DELETE", path).status == 200,
              request("GET", path + "/audio/0").status == 404 else { return 1 }
        let next = try JSONSerialization.jsonObject(with: service.submit(body).body) as! [String: Any]
        let nextPath = "/v1/narrations/" + (next["id"] as! String)
        guard request("DELETE", nextPath).status == 200,
              request("GET", nextPath + "/audio/0").status == 404, worker.stopped else { return 1 }
        print("PASS pieces available before completion, ordered metadata, no playback, deletion, and cancellation")
        return 0
    } catch { print("FAIL audio pieces: \(error)"); return 1 }
}
