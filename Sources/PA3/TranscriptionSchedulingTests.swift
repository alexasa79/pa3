import Foundation

/// Deterministic regression for live text waiting behind repeated boundary checks.
/// The fake recognizer charges 0.75 simulated seconds per request, without sleeping.
/// Main-queue barriers measure publication order, not operating-system scheduling.
func runTranscriptionSchedulingTests() -> [String] {
    precondition(Thread.isMainThread)
    final class Scenario: @unchecked Sendable {
        let lock = NSLock()
        var requests = 0
        var prompts: [String] = []
        var completedRequests = 0
        var firstPreviewCost: Double?
        var firstBoundaryHadPreview = false
        var completed = false
        var trim = -1
        var recognized = false
        var repeatWasBounded = true
        var previews: [String] = []

        func requestNumber(prompt: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            requests += 1
            prompts.append(prompt)
            return requests
        }
        func completeRequest(_ number: Int) {
            lock.lock()
            defer { lock.unlock() }
            completedRequests = number
        }
        func observeBoundary() {
            lock.lock()
            defer { lock.unlock() }
            if requests == 2 { firstBoundaryHadPreview = firstPreviewCost != nil }
        }
        func publish(_ text: String) {
            lock.lock()
            defer { lock.unlock() }
            if firstPreviewCost == nil { firstPreviewCost = Double(completedRequests) * 0.75 }
            previews.append(text)
        }
        func finish(trim: Int, recognized: Bool) {
            lock.lock()
            defer { lock.unlock() }
            self.trim = trim
            self.recognized = recognized
            completed = true
        }
        var done: Bool {
            lock.lock()
            defer { lock.unlock() }
            return completed
        }
    }
    func response(_ words: [(String, Float)]) -> WhisperTranscription {
        let text = words.map { $0.0 }.joined(separator: " ")
        return WhisperTranscription(task: "transcribe", language: "en", duration: nil, text: text,
            segments: [WhisperSegment(id: 0, text: text, start: 0, end: 28,
                words: words.map { WhisperWord(word: " " + $0.0, start: $0.1 + 0.1, end: $0.1 + 0.3, probability: 0.9) })])
    }
    let full = response([("First", 0.3), ("sentence.", 0.7), ("How", 2), ("does", 2.3),
                         ("this", 2.6), ("work", 3), ("Further", 6), ("speech", 6.4), ("continues.", 6.8)])
    let retained = response([("How", 0), ("does", 0.3), ("this", 0.6), ("work?", 1)])
    let disagreeingHead = response([("Different", 0.3), ("opening.", 0.7)])
    let rate = TranscriberService.defaultSampleRate
    let samples: [Float] = (0..<(28 * rate)).map { i in
        let t = Double(i) / Double(rate)
        if (1.3..<1.9).contains(t) || (5.2..<5.8).contains(t) { return 0 }
        return Float(sin(t * 2 * Double.pi * 220)) * 0.3
    }
    var failures: [String] = []
    for (needsCut, useDictionary) in [(false, false), (true, false), (false, true)] {
        let scenario = Scenario()
        let transcriber = TranscriberService()
        if useDictionary { transcriber.setVocabulary(["REDTRC", "BDL"]) }
        transcriber.transcriptionRequestForTesting = { _, prompt in
            let request = scenario.requestNumber(prompt: prompt)
            defer { scenario.completeRequest(request) }
            if request > 1 {
                DispatchQueue.main.sync { scenario.observeBoundary() }
            }
            // Initial full decode, retained anchor, disagreeing head, clean retry,
            // repeated retained anchor and disagreement. Further candidates fail.
            switch request {
            case 1, 4: return full
            case 2, 5: return retained
            case 3, 6: return disagreeingHead
            default: return nil
            }
        }
        let worker = Thread {
            let result = transcriber.debugTranscribeSlice(samples: samples, needsCut: needsCut) { update in
                scenario.publish(update.text)
            }
            // An unchanged rejected head must not trigger another verification chain.
            if needsCut {
                let before = scenario.requests
                _ = transcriber.debugTranscribeSlice(samples: samples, needsCut: true) { update in
                    scenario.publish(update.text)
                }
                DispatchQueue.main.sync {
                    if scenario.requests != before + 1 { scenario.repeatWasBounded = false }
                }
            }
            DispatchQueue.main.sync { scenario.finish(trim: result.trim, recognized: result.recognized) }
        }
        worker.start()
        let deadline = Date().addingTimeInterval(5)
        while !scenario.done && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
        }
        guard scenario.done else {
            failures.append("scheduling fixture did not finish")
            continue
        }
        let name = needsCut ? "disagreeing boundary" : (useDictionary ? "dictionary live update" : "ordinary live update")
        if useDictionary && scenario.prompts != ["REDTRC, BDL."] {
            failures.append("dictionary live update must make exactly one glossary-guided request and no unprompted request")
        }
        if scenario.firstPreviewCost != 0.75 {
            failures.append("\(name): first preview waited \(scenario.firstPreviewCost ?? -1) simulated seconds; expected 0.75")
        }
        if needsCut && !scenario.firstBoundaryHadPreview {
            failures.append("validated preview must be delivered before boundary verification starts")
        }
        if needsCut && scenario.requests > 4 {
            failures.append("one live round must use at most one main decode and two boundary checks")
        }
        if needsCut && scenario.requests < 2 {
            failures.append("fixture did not exercise boundary verification")
        }
        if !scenario.repeatWasBounded {
            failures.append("unchanged disputed boundary must not repeat verification")
        }
        if !scenario.recognized || scenario.trim != 0 || transcriber.currentText().stable != "" {
            failures.append("disagreement must preserve uncommitted speech without an unsafe cut")
        }
        if scenario.previews.last != full.text {
            failures.append("live preview must preserve all recognized words")
        }
        print("\(name): requests=\(scenario.requests) first-preview=\(scenario.firstPreviewCost ?? -1)s (simulated)")
    }
    return failures
}
