import Foundation
import Darwin

// Exercises the running app. Plays short phrases and cancels outstanding jobs.
struct TestFailure: Error { let message: String }
func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw TestFailure(message: message) }
}
let tokenURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PA3/narration-token")
let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
let port = ProcessInfo.processInfo.environment["PA3_NARRATION_PORT"] ?? "65462"

func call(_ method: String, _ path: String, _ body: [String: Any]? = nil, auth: Bool = true) async throws -> (Int, [String: Any]) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    request.timeoutInterval = 10
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if auth { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
    let (data, response) = try await URLSession.shared.data(for: request)
    return ((response as! HTTPURLResponse).statusCode, try JSONSerialization.jsonObject(with: data) as! [String: Any])
}
func submit(_ text: String, mode: String = "enqueue") async throws -> String {
    let (status, job) = try await call("POST", "/v1/narrations", ["text": text, "mode": mode, "pronunciations": ["PA3": "P A three"]])
    try check(status == 202 && job["voice"] as? String == "vctk-p311", "Submission failed: \(job)")
    return job["id"] as! String
}
func job(_ id: String) async throws -> [String: Any] {
    let (status, value) = try await call("GET", "/v1/narrations/" + id)
    try check(status == 200, "Could not read job")
    return value
}
func wait(_ id: String, for states: Set<String>) async throws -> [String: Any] {
    let deadline = Date().addingTimeInterval(120)
    while Date() < deadline {
        let value = try await job(id)
        let state = value["state"] as! String
        if states.contains(state) { return value }
        try check(!["failed", "cancelled", "completed"].contains(state), "Unexpected job result: \(value)")
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    throw TestFailure(message: "Timed out waiting for \(id)")
}

Task {
    do {
        let (status, health) = try await call("GET", "/health", auth: false)
        try check(status == 200 && health["configured"] as? Bool == true && health["dictation_busy"] as? Bool == false,
                  "Stop dictation and configure speech tools before testing: \(health)")
        try check(health["runtime"] as? String == "libllama" && health["model_residency"] as? String == "persistent", "Wrong narration runtime")
        let unauthenticated = try await call("POST", "/v1/narrations", ["text": "test"], auth: false)
        try check(unauthenticated.0 == 401, "Authentication bypass")
        for invalid: [String: Any] in [["text": " "], ["text": "test", "voice": "Ryan"], ["text": "test", "language": "Auto"],
                                      ["text": "test", "instruct": "Excited"], ["text": "test", "mode": "invalid"]] {
            let result = try await call("POST", "/v1/narrations", invalid)
            try check(result.0 == 422, "Invalid input accepted: \(invalid)")
        }
        print("PASS native runtime, authentication, and validation")

        var ids = [try await submit(String(repeating: "The service validates each request. ", count: 10))]
        for _ in 0..<10 { ids.append(try await submit("Queued test.")) }
        let overflow = try await call("POST", "/v1/narrations", ["text": "overflow"])
        try check(overflow.0 == 429, "Queue capacity not enforced")
        _ = try await call("DELETE", "/v1/narrations/" + ids.last!)
        _ = try await call("POST", "/v1/narrations/stop", [:])
        for id in ids {
            let value = try await job(id)
            try check(value["state"] as? String == "cancelled", "Cancelled generation survived")
        }
        print("PASS queue capacity and cancellation during generation")

        let first = try await submit("PA3 narration is ready. The native speech test has passed.")
        let second = try await submit("Second job.")
        let queued = try await job(second)
        try check(queued["state"] as? String == "queued", "FIFO order changed")
        let completed = try await wait(first, for: ["completed"])
        try check(completed["pieces_played"] as? Int == 2 && completed["pieces"] as? Int == 2, "Not all pieces played")
        _ = try await wait(second, for: ["completed"])
        print("PASS p311, pronunciation, two-piece playback, and FIFO")

        let regression = try await submit("Done. The reader is now compact, opens in the top-right corner, and stays above other windows when you switch apps.\n\nTests passed; PA3 is rebuilt and restarted.")
        let regressionResult = try await wait(regression, for: ["completed"])
        try check(regressionResult["pieces"] as? Int == 3 && regressionResult["pieces_played"] as? Int == 3,
                  "Reader response stopped after Done: \(regressionResult)")
        print("PASS full reader response after a one-word opening sentence")

        let list = try await submit("1. Validate the request.\n2. Start the server.\n3. Check the response.")
        let listResult = try await wait(list, for: ["completed"])
        try check(listResult["pieces"] as? Int == 3 && listResult["pieces_played"] as? Int == 3, "List markers split away from their items")
        let resident = try await call("GET", "/health", auth: false)
        try check(resident.1["model_loaded"] as? Bool == true, "Worker did not retain the model")
        print("PASS numbered list playback and resident model")

        let paragraphs = try await submit("Follow these steps:\n• Validate the request.\n• Start the worker.\nThe list has finished.\n\nThe next paragraph begins.")
        let paragraphResult = try await wait(paragraphs, for: ["completed"])
        try check(paragraphResult["pieces"] as? Int == 5 && paragraphResult["pieces_played"] as? Int == 5, "List introduction or conclusion merged into an item")
        print("PASS colon introduction, bullet list, list conclusion, and paragraph playback")

        let active = try await submit("This narration will be stopped during playback before the sentence finishes.")
        _ = try await wait(active, for: ["playing"])
        let cancelled = try await call("DELETE", "/v1/narrations/" + active)
        try check(cancelled.1["state"] as? String == "cancelled", "Playback cancellation failed")
        let replaced = try await submit("This job should be replaced before it finishes.")
        let replacement = try await submit("Replacement succeeded.", mode: "replace")
        let old = try await job(replaced)
        try check(old["state"] as? String == "cancelled", "Replace did not cancel active generation")
        _ = try await wait(replacement, for: ["completed"])
        print("PASS playback cancellation and replacement recovery")
        exit(0)
    } catch {
        fputs("FAIL: \(error)\n", stderr)
        exit(1)
    }
}
dispatchMain()
