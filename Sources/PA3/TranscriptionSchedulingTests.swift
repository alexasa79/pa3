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
    @Sendable func response(_ words: [(String, Float)]) -> WhisperTranscription {
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
    // The real worker must trim the recorded long-pause shape, and a failed
    // retained anchor must yield to the next sentence on the following update.
    for (longPause, seconds) in [(true, 28), (true, 99), (false, 28)] {
        let scenario = Scenario()
        let transcriber = TranscriberService()
        let full = longPause
            ? response([("First", 0.3), ("sentence.", 16.7), ("Look,", 20.9),
                        ("this", 21.2), ("bench", 21.5)])
            : response([("First", 0.3), ("sentence.", 0.7), ("How", 2), ("does", 2.3),
                        ("this", 2.6), ("work?", 3), ("Further", 6), ("speech", 6.4), ("continues.", 6.8)])
        let samples: [Float] = (0..<(seconds * rate)).map { i in
            let t = Double(i) / Double(rate)
            let quiet = longPause ? (16.1..<20.92).contains(t)
                : (1.3..<1.9).contains(t) || (5.2..<5.8).contains(t)
            return quiet ? 0 : Float(sin(t * 2 * Double.pi * 220)) * 0.3
        }
        transcriber.transcriptionRequestForTesting = { _, prompt in
            let request = scenario.requestNumber(prompt: prompt)
            defer { scenario.completeRequest(request) }
            if request > 1 { DispatchQueue.main.sync { scenario.observeBoundary() } }
            if longPause {
                switch request {
                case 1: return full
                case 2: return response([("Look,", 0.2), ("this", 0.5), ("bench", 0.8)])
                case 3: return response([("First", 0.3), ("sentence.", 16.7)])
                default: return nil
                }
            }
            switch request {
            case 1, 3: return full
            case 2: return response([("Unrelated", 0), ("retained", 0.3), ("words", 0.6)])
            case 4: return response([("Further", 0.2), ("speech", 0.6), ("continues.", 1)])
            case 5: return response([("First", 0.3), ("sentence.", 0.7), ("How", 2),
                                    ("does", 2.3), ("this", 2.6), ("work?", 3)])
            default: return nil
            }
        }
        let worker = Thread {
            let first = transcriber.debugTranscribeSlice(samples: samples, needsCut: true) { scenario.publish($0.text) }
            var result = first
            if !longPause {
                if first.trim != 0 || transcriber.currentText().stable != "" {
                    scenario.repeatWasBounded = false
                }
                result = transcriber.debugTranscribeSlice(samples: samples, needsCut: true) { scenario.publish($0.text) }
            }
            DispatchQueue.main.sync { scenario.finish(trim: result.trim, recognized: result.recognized) }
        }
        worker.start()
        let deadline = Date().addingTimeInterval(5)
        while !scenario.done && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
        }
        let name = longPause ? "recorded long pause at \(seconds)s" : "rejected retained anchor advances to later sentence"
        guard scenario.done else { failures.append("\(name): fixture did not finish"); continue }
        let expectedStable = longPause ? "First sentence." : "First sentence. How does this work?"
        if scenario.trim <= 0 || transcriber.currentText().stable != expectedStable {
            failures.append("\(name): failed to commit the verified sentence")
        }
        if scenario.requests != (longPause ? 3 : 5) || !scenario.repeatWasBounded {
            failures.append("\(name): failed verification repeated or exceeded request budget")
        }
        if !scenario.firstBoundaryHadPreview || scenario.previews.first != full.text {
            failures.append("\(name): full live text must publish before verification")
        }
        print("\(name): requests=\(scenario.requests) trim=\(scenario.trim)")
    }
    return failures
}
