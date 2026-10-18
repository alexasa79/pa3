import Foundation

// Opt-in end-to-end check in a side process: no HTTP listener or local playback.
@MainActor
func runNarrationTimingLiveTest() async -> Int32 {
    let service = NarrationService(token: "timing-test")
    defer { service.shutdown() }
    let text = "The cache stores recently requested documents. When another request arrives, the cache returns the saved result. This keeps the response fast and reduces repeated work."
    let response = service.submit(try! JSONSerialization.data(withJSONObject: ["text": text, "output": "stream", "timing": "words"]))
    func json(_ response: NarrationHTTPResponse) -> [String: Any] { (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:] }
    guard response.status == 202, let id = json(response)["id"] as? String else { print("FAIL live timing: \(String(decoding: response.body, as: UTF8.self))"); return 1 }
    let started = Date(), deadline = Date().addingTimeInterval(180)
    var received = 0, wordCount = 0
    while Date() < deadline {
        let status = json(service.handle(NarrationHTTPRequest(method: "GET", path: "/v1/narrations/" + id,
            headers: ["authorization": "Bearer timing-test"], body: Data())))
        if status["state"] as? String == "failed" { print("FAIL live timing: \(status)"); return 1 }
        guard let chunks = status["audio_chunks"] as? [[String: Any]] else { print("FAIL missing audio chunks"); return 1 }
        for index in received..<chunks.count {
            guard let words = chunks[index]["word_timings"] as? [[String: Any]],
                  let samples = chunks[index]["samples"] as? Int,
                  service.streamResponse(id, index: index).body.count == samples * 4 else { print("FAIL invalid live timed audio"); return 1 }
            wordCount += words.count
            print("Timed PCM chunk \(index): \(words.count) words, ready after \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        }
        received = chunks.count
        if status["state"] as? String == "completed" {
            guard received > 1, wordCount >= 22, status["pieces"] as? Int == 1 else { print("FAIL incomplete paragraph alignment: \(wordCount) words"); return 1 }
            print("PASS live paragraph generation and recognition: \(received) PCM chunks, \(wordCount) source words")
            return 0
        }
        try? await Task.sleep(for: .milliseconds(100))
    }
    print("FAIL live timing timed out")
    return 1
}

// Exercises the WAV path used by rectangle narration, including the real audio clock.
@MainActor
func runScreenNarrationTimingLiveTest() async -> Int32 {
    let text: String
    if let path = ProcessInfo.processInfo.environment["PA3_SCREEN_NARRATION_IMAGE"] {
        let result = await ScreenText.recognizeForNarration(URL(fileURLWithPath: path))
        guard let recognized = result.text else { print("FAIL screenshot narration: \(result.message)"); return 1 }
        text = recognized
        print("Screenshot text: \(text)")
        PaddleOCR.shared.stop()
    } else {
        text = ProcessInfo.processInfo.environment["PA3_SCREEN_NARRATION_TEXT"]
            ?? "The cache stores documents and returns the saved result."
    }
    let service = NarrationService(makeTimingWorker: { callback in
        NarrationTiming { workerID, event in
            for word in event.words ?? [] {
                let value = (text as NSString).substring(with: NSRange(location: word.location, length: word.length))
                print("Recognized \(value): \(word.start)...\(word.end)")
            }
            callback(workerID, event)
        }
    })
    defer { service.shutdown() }
    let lastWord = try! NarrationText.plan(NarrationInput(text: text)).last!.words.last!
    let finalRange = NSRange(location: lastWord.location, length: lastWord.length)
    let document = ScreenTextDocument(text: text, spans: [])
    var locations = Set<Int>()
    var highlightedFinalWord = false
    let expected = (ProcessInfo.processInfo.environment["PA3_SCREEN_NARRATION_EXPECT_WORDS"] ?? "")
        .split(separator: "|").map { (text as NSString).range(of: String($0)) }
    var observed = Set<NSRange>()
    var failed = false
    service.onScreenProgress = { _, range in
        if let range { locations.insert(range.location); observed.insert(range) }
        if range == finalRange { highlightedFinalWord = true }
    }
    service.onSelectionFailure = { message in print("FAIL screen narration: \(message)"); failed = true }
    let response = service.narrateSelection(SelectedTextResult(text: text, message: "", screenDocument: document))
    guard response.status == 202 else { print("FAIL screen narration acceptance"); return 1 }
    let deadline = Date().addingTimeInterval(180)
    while service.hasNarration && Date() < deadline && !failed { try? await Task.sleep(for: .milliseconds(50)) }
    guard !service.hasNarration, !failed, locations.count >= 7, highlightedFinalWord, expected.allSatisfy({ $0.location != NSNotFound && observed.contains($0) }) else {
        print("FAIL live screen narration: \(locations.count) highlighted source words; final word highlighted=\(highlightedFinalWord)"); return 1
    }
    print("PASS live screen WAV recognition and playback clock: \(locations.count) highlighted source words")
    return 0
}
