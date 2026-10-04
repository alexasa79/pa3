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
