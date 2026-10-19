import Foundation

func runNarrationCaptureRetentionTests() -> Bool {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pa3-capture-retention-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let capture = NarrationCapture(directory: directory, maxJobs: 2, maxBytes: 4096)
    do {
        for id in ["one", "two", "three"] {
            capture.begin(id, request: Data("{}".utf8), plan: [])
            capture.flush()
            Thread.sleep(forTimeInterval: 0.01)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard Set(names) == Set(["two", "three"]) else { return false }
        capture.append("three", pcm: Data(repeating: 0, count: 8192))
        capture.flush()
        guard try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else { return false }
        print("PASS narration capture bounds job count and disk usage")
        return true
    } catch { print("FAIL narration capture retention: \(error)"); return false }
}
