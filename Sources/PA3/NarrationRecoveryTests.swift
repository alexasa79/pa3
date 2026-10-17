import Foundation
import AVFoundation

private final class RecoveryTestWorker: NarrationWorker {
    let id = UUID()
    let onEvent: @Sendable (UUID, TTSWorkerEvent) -> Void
    var requests: [(text: String, path: URL, seed: Int, stream: Bool)] = []
    var stopped = false
    init(_ onEvent: @escaping @Sendable (UUID, TTSWorkerEvent) -> Void) { self.onEvent = onEvent }
    func start() throws {}
    func stop() { stopped = true }
    func generate(id: String, text: String, voice: String, language: String, instruct: String?, path: URL, pause: Double, seed: Int, stream: Bool) {
        requests.append((text, path, seed, stream))
    }
    func emit(_ event: TTSWorkerEvent) { onEvent(id, event) }
}

@MainActor
func runNarrationRecoveryTests() async -> Int32 {
    guard await runTimingServiceTests(), await runScreenPlaybackTimingTests(), await runScreenHighlightPauseTests(), await runSharedDictionaryServiceTests() else { return 1 }
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
        return await runNarrationStreamTests()
    } catch { print("FAIL audio pieces: \(error)"); return 1 }
}

@MainActor
private func runNarrationStreamTests() async -> Int32 {
    var worker: RecoveryTestWorker!
    let service = NarrationService(isConfigured: { true }, token: "test-token") { callback in
        worker = RecoveryTestWorker(callback)
        return worker
    }
    defer { service.shutdown() }
    func request(_ method: String, _ path: String, auth: Bool = true) -> NarrationHTTPResponse {
        service.handle(NarrationHTTPRequest(method: method, path: path,
            headers: auth ? ["authorization": "Bearer test-token"] : [:], body: Data()))
    }
    do {
        let text = "The day we discovered we had been designated a global terrorist organization, we promised that we would try to resist as long as this was possible."
        let body = try JSONSerialization.data(withJSONObject: ["text": text, "output": "stream"])
        func submit() throws -> String {
            let response = service.submit(body)
            guard response.status == 202 else { throw NarrationText.Invalid("Stream submit failed") }
            return (try JSONSerialization.jsonObject(with: response.body) as! [String: Any])["id"] as! String
        }
        let id = try submit(), path = "/v1/narrations/" + id
        worker.emit(TTSWorkerEvent(event: "ready"))
        try await Task.sleep(for: .milliseconds(30))
        guard worker.requests.count == 1, worker.requests[0].text == text, worker.requests[0].stream else { return 1 }
        let base = worker.requests[0].path
        let pcm = Data(repeating: 0, count: 16)
        for index in 0..<2 {
            let chunk = base.path + ".part-\(index).pcm"
            try pcm.write(to: URL(fileURLWithPath: chunk))
            worker.emit(TTSWorkerEvent(event: "partial", id: id, path: chunk, chunk: index, samples: 4, sampleRate: 24000))
            try await Task.sleep(for: .milliseconds(30))
            let response = request("GET", path + "/chunks/\(index)")
            guard response.status == 200, response.body == pcm, response.contentType == "application/octet-stream",
                  request("GET", path + "/chunks/\(index)", auth: false).status == 401,
                  request("GET", path + "/chunks/\(index + 1)").status == 404,
                  service.hasNarration else { return 1 }
        }
        worker.emit(TTSWorkerEvent(event: "audio", id: id, path: base.path))
        try await Task.sleep(for: .milliseconds(30))
        let status = try JSONSerialization.jsonObject(with: request("GET", path).body) as! [String: Any]
        guard status["state"] as? String == "completed", status["pieces_played"] as? Int == 0,
              (status["audio_chunks"] as? [[String: Int]])?.count == 2, !service.hasNarration,
              request("DELETE", path).status == 200, request("GET", path + "/chunks/0").status == 404 else { return 1 }
        let next = try submit(), nextPath = "/v1/narrations/" + next
        let chunk = worker.requests.last!.path.path + ".part-0.pcm"
        try pcm.write(to: URL(fileURLWithPath: chunk))
        worker.emit(TTSWorkerEvent(event: "partial", id: next, path: chunk, chunk: 0, samples: 4, sampleRate: 24000))
        try await Task.sleep(for: .milliseconds(30))
        guard request("GET", nextPath + "/chunks/0").status == 200,
              request("DELETE", nextPath).status == 200,
              request("GET", nextPath + "/chunks/0").status == 404,
              !FileManager.default.fileExists(atPath: chunk), worker.stopped else { return 1 }
        print("PASS whole-sentence streaming, early PCM, auth, ordering, completion, and partial cancellation")
        return 0
    } catch { print("FAIL narration streaming: \(error)"); return 1 }
}

@MainActor
private func runSharedDictionaryServiceTests() async -> Bool {
    for output in ["selection", "stream", "preview"] {
        var worker: RecoveryTestWorker?
        let service = NarrationService(isConfigured: { true }) { callback in
            let created = RecoveryTestWorker(callback)
            worker = created
            return created
        }
        defer { service.shutdown() }
        service.pronunciationDictionary = { ["SQL": "sequel", "src/main.cpp": "the main source"] }
        let text = "Read sql in src/main.cpp."
        let response: NarrationHTTPResponse
        if output == "selection" {
            response = service.narrateSelection(SelectedTextResult(text: text, message: ""))
        } else {
            var body: [String: Any] = ["text": text, "output": "stream"]
            if output == "preview" { body["pronunciations"] = ["sql": "ess cue ell"] }
            response = service.submit(try! JSONSerialization.data(withJSONObject: body))
        }
        guard response.status == 202, let worker else {
            print("FAIL shared dictionary service acceptance: \(output)"); return false
        }
        worker.emit(TTSWorkerEvent(event: "ready"))
        try? await Task.sleep(for: .milliseconds(30))
        let expected = output == "preview" ? "Read ess cue ell in the main source." : "Read sequel in the main source."
        guard worker.requests.first?.text == expected else {
            print("FAIL shared dictionary did not reach model: \(output)"); return false
        }
    }
    print("PASS shared dictionary for selected text, browser streams, and unsaved preview overrides")
    return true
}

private final class TimingTestWorker: NarrationTimingWorker {
    let id = UUID()
    let callback: @Sendable (UUID, NarrationTimingEvent) -> Void
    var requests: [(id: String, chunk: Int, words: [NarrationWord])] = []
    var stopped = false
    init(_ callback: @escaping @Sendable (UUID, NarrationTimingEvent) -> Void) { self.callback = callback }
    func start() throws {}
    func stop() { stopped = true }
    func recognize(id: String, chunk: Int, segment: Int, paths: [URL], words: [NarrationWord], offset: Double, language: String) {
        requests.append((id, chunk, words))
    }
    func emit(_ event: NarrationTimingEvent) { callback(id, event) }
}

@MainActor
private func runTimingServiceTests() async -> Bool {
    var narrator: RecoveryTestWorker!, timing: TimingTestWorker!
    let service = NarrationService(isConfigured: { true }, token: "test-token", makeWorker: {
        narrator = RecoveryTestWorker($0); return narrator
    }, makeTimingWorker: { timing = TimingTestWorker($0); return timing })
    defer { service.shutdown() }
    func settle() async { try? await Task.sleep(for: .milliseconds(30)) }
    func request(_ method: String, _ path: String) -> NarrationHTTPResponse {
        service.handle(NarrationHTTPRequest(method: method, path: path, headers: ["authorization": "Bearer test-token"], body: Data()))
    }
    func json(_ response: NarrationHTTPResponse) -> [String: Any] { (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:] }
    let response = service.submit(try! JSONSerialization.data(withJSONObject: ["text": "First sentence. Second sentence.", "output": "stream", "timing": "words"]))
    guard let id = json(response)["id"] as? String else { print("FAIL timed stream acceptance"); return false }
    let path = "/v1/narrations/" + id
    narrator.emit(TTSWorkerEvent(event: "ready")); await settle()
    guard narrator.requests.count == 1, narrator.requests[0].text.contains("Second sentence.") else { print("FAIL paragraph generation"); return false }
    let output = narrator.requests[0].path
    let partial = output.path + ".part-0.pcm"
    do { try Data(repeating: 0, count: 96000).write(to: URL(fileURLWithPath: partial)) }
    catch { return false }
    narrator.emit(TTSWorkerEvent(event: "partial", id: id, path: partial, chunk: 0, samples: 24000, sampleRate: 24000))
    narrator.emit(TTSWorkerEvent(event: "audio", id: id, path: output.path)); await settle()
    guard timing.requests.count == 1, request("GET", path + "/chunks/0").status == 404,
          json(request("GET", path))["state"] as? String == "generating" else { print("FAIL audio must wait for timings"); return false }
    timing.emit(NarrationTimingEvent(id: id, chunk: 0, words: [NarrationWordTiming(location: 0, length: 5, start: 0, end: 0.5)]))
    await settle()
    let status = json(request("GET", path))
    guard status["state"] as? String == "completed", request("GET", path + "/chunks/0").status == 200,
          let chunks = status["audio_chunks"] as? [[String: Any]], chunks[0]["word_timings"] != nil else { print("FAIL timed stream publication"); return false }
    // An uncertain first chunk still publishes audio; later chunks can recover and lose alignment again.
    let uncertain = service.submit(try! JSONSerialization.data(withJSONObject: ["text":"Technical identifier. Then readable words.", "output":"stream", "timing":"words"]))
    guard let uncertainID = json(uncertain)["id"] as? String, let uncertainOutput = narrator.requests.last?.path else { return false }
    let uncertainPath = "/v1/narrations/" + uncertainID
    for index in 0..<3 {
        let partialPath = uncertainOutput.path + ".part-\(index).pcm"
        do { try Data(repeating: 0, count: 96000).write(to: URL(fileURLWithPath: partialPath)) }
        catch { return false }
        narrator.emit(TTSWorkerEvent(event: "partial", id: uncertainID, path: partialPath, chunk: index, samples: 24000, sampleRate: 24000))
        await settle()
        let words = index == 1 ? [NarrationWordTiming(location: 22, length: 4, start: 1, end: 1.5)] : []
        timing.emit(NarrationTimingEvent(id: uncertainID, chunk: index, words: words)); await settle()
        guard request("GET", uncertainPath + "/chunks/\(index)").status == 200,
              json(request("GET", uncertainPath))["state"] as? String == "generating", !timing.stopped else {
            print("FAIL uncertain recognition must publish audio and keep recognizer running"); return false
        }
    }
    narrator.emit(TTSWorkerEvent(event: "audio", id: uncertainID, path: uncertainOutput.path)); await settle()
    guard json(request("GET", uncertainPath))["state"] as? String == "completed" else { return false }
    // A new request reuses the recognizer; cancel stops it and ignores delayed callbacks.
    let second = service.submit(try! JSONSerialization.data(withJSONObject: ["text":"Another paragraph.", "output":"stream", "timing":"words"]))
    guard let secondID = json(second)["id"] as? String else { return false }
    _ = request("DELETE", "/v1/narrations/" + secondID)
    timing.emit(NarrationTimingEvent(id: secondID, chunk: 0, words: [])); await settle()
    guard timing.stopped, json(request("GET", "/v1/narrations/" + secondID))["state"] as? String == "cancelled" else { return false }
    print("PASS paragraph streaming, timing gating, metadata, cancellation, and stale recognition events")
    return true
}

@MainActor
private func runScreenPlaybackTimingTests() async -> Bool {
    var narrator: RecoveryTestWorker!, timing: TimingTestWorker!
    let service = NarrationService(isConfigured: { true }, makeWorker: {
        narrator = RecoveryTestWorker($0); return narrator
    }, makeTimingWorker: { timing = TimingTestWorker($0); return timing })
    defer { service.shutdown() }
    var highlights: [NSRange?] = []
    var screenPrepared = false
    service.onScreenProgress = { document, range in
        if document != nil && range == nil { screenPrepared = true }
        highlights.append(range)
    }
    func settle() async { try? await Task.sleep(for: .milliseconds(40)) }
    func begin() async throws -> String {
        let document = ScreenTextDocument(text: "First sentence.", spans: [])
        let response = service.narrateSelection(SelectedTextResult(text: document.text, message: "", screenDocument: document))
        let json = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
        let id = json["id"] as! String
        narrator.emit(TTSWorkerEvent(event: "ready")); await settle()
        let output = narrator.requests.last!.path
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000)!
        buffer.frameLength = 24000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 24000)
        do {
            let file = try AVAudioFile(forWriting: output, settings: format.settings)
            try file.write(from: buffer)
        }
        narrator.emit(TTSWorkerEvent(event: "audio", id: id, path: output.path)); await settle()
        return id
    }
    do {
        let id = try await begin()
        guard screenPrepared, timing.requests.count == 1, highlights.compactMap({ $0 }).isEmpty else {
            print("FAIL screen playback must wait for word timing"); return false
        }
        timing.emit(NarrationTimingEvent(id: id, chunk: 0, words: [NarrationWordTiming(location: 0, length: 5, start: 0, end: 0.8)]))
        await settle()
        guard highlights.contains(where: { $0 == NSRange(location: 0, length: 5) }) else {
            print("FAIL screen word highlight must follow playback"); return false
        }
        // Clearing a playing job removes the overlay and ignores stale timing callbacks.
        service.stopAll()
        let count = highlights.count
        timing.emit(NarrationTimingEvent(id: id, chunk: 0, words: [])); await settle()
        guard timing.stopped, highlights.last! == nil, highlights.count == count, !service.hasNarration else {
            print("FAIL cancelled screen playback must clear highlighting"); return false
        }
        highlights = []
        _ = try await begin()
        timing.emit(NarrationTimingEvent(error: "Recognizer unavailable")); await settle()
        guard service.hasNarration, highlights.contains(where: { $0 == NSRange(location: 0, length: 15) }) else {
            print("FAIL screen recognition failure must continue with passage highlighting"); return false
        }
        service.stopAll()
        print("PASS screen timing gates playback, follows source words, clears on stop, and falls back on recognition failure")
        return true
    } catch { print("FAIL screen playback timing: \(error)"); return false }
}


@MainActor
private func runScreenHighlightPauseTests() async -> Bool {
    var narrator: RecoveryTestWorker!, timing: TimingTestWorker!
    let service = NarrationService(isConfigured: { true }, makeWorker: {
        narrator = RecoveryTestWorker($0); return narrator
    }, makeTimingWorker: { timing = TimingTestWorker($0); return timing })
    defer { service.shutdown() }
    let text = "Structures (WODS), such as trees. Leaves read."
    let document = ScreenTextDocument(text: text, spans: [])
    let wods = (text as NSString).range(of: "WODS")
    let such = (text as NSString).range(of: "such")
    let leaves = (text as NSString).range(of: "Leaves")
    let read = (text as NSString).range(of: "read")
    var highlights: [NSRange?] = []
    service.onScreenProgress = { _, range in highlights.append(range) }
    func waitFor(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }
    func publishAudio(_ index: Int, id: String, seconds: Double) throws -> URL {
        let output = narrator.requests[index].path
        let count = AVAudioFrameCount(seconds * 24000)
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        buffer.floatChannelData![0].initialize(repeating: 0, count: Int(count))
        do {
            let file = try AVAudioFile(forWriting: output, settings: format.settings)
            try file.write(from: buffer)
        }
        narrator.emit(TTSWorkerEvent(event: "audio", id: id, path: output.path))
        return output
    }
    func word(_ range: NSRange, _ start: Double, _ end: Double) -> NarrationWordTiming {
        NarrationWordTiming(location: range.location, length: range.length, start: start, end: end)
    }
    do {
        let response = service.narrateSelection(SelectedTextResult(text: text, message: "", screenDocument: document))
        let json = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
        guard let id = json["id"] as? String, json["pieces"] as? Int == 2 else {
            print("FAIL pause fixture must contain two audio pieces"); return false
        }
        narrator.emit(TTSWorkerEvent(event: "ready"))
        guard await waitFor({ narrator.requests.count == 1 }) else { return false }
        let first = try publishAudio(0, id: id, seconds: 1)
        guard await waitFor({ timing?.requests.count == 1 }) else { return false }
        timing.emit(NarrationTimingEvent(id: id, chunk: 0, words: [word(wods, 0, 0.10), word(such, 0.45, 0.60)]))
        guard await waitFor({ highlights.last == wods }) else { return false }
        let start = highlights.count - 1
        try await Task.sleep(for: .milliseconds(250))
        guard highlights.last == wods, await waitFor({ highlights.last == such }),
              highlights[start...].allSatisfy({ $0 != nil }) else {
            print("FAIL highlight disappears during the WODS/such pause"); return false
        }
        // Delay the next WAV, its recognition, then its first word independently.
        guard await waitFor({ !FileManager.default.fileExists(atPath: first.path) }) else { return false }
        try await Task.sleep(for: .milliseconds(100))
        guard highlights.last == such, narrator.requests.count == 2 else {
            print("FAIL highlight disappears while waiting for the next audio piece"); return false
        }
        _ = try publishAudio(1, id: id, seconds: 1)
        guard await waitFor({ timing.requests.count == 2 }) else { return false }
        try await Task.sleep(for: .milliseconds(100))
        guard highlights.last == such else { return false }
        // A zero-duration last timestamp must still receive visible reading focus.
        timing.emit(NarrationTimingEvent(id: id, chunk: 1, words: [word(leaves, 0.3, 0.5), word(read, 0.7, 0.7)]))
        try await Task.sleep(for: .milliseconds(100))
        guard highlights.last == such, await waitFor({ highlights.last == leaves }),
              await waitFor({ highlights.last == read }),
              highlights[start...].allSatisfy({ $0 != nil }) else {
            print("FAIL highlight must bridge audio pieces and reach the final read"); return false
        }
        guard await waitFor({ !service.hasNarration }), highlights.last! == nil else {
            print("FAIL completed narration must clear highlighting"); return false
        }
        print("PASS highlight survives word gaps, audio and recognition delays, reaches a zero-duration final word, and clears on completion")
        return true
    } catch { print("FAIL highlight pause test: \(error)"); return false }
}
