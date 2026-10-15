import Foundation

/// Unit tests for the pure segmentation pieces. Run through `pa3 --whisper-text-test`.
func runSegmentationTests() -> [String] {
    var failures: [String] = []
    func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if !condition {
            let extra = detail()
            failures.append(extra.isEmpty ? name : "\(name): \(extra)")
        }
    }
    let config = SegmentationConfig.default
    let rate = 16_000

    // A continuation retains contextual casing without lowercasing proper nouns.
    do {
        check("restore lowercase continuation", continuationOpening("Turning", contextual: "turning") == "turning")
        for word in ["I", "Whisper", "PA3", "Chakri", "Москва"] {
            check("preserve contextual spelling \(word)", continuationOpening(word.lowercased(), contextual: word) == word)
        }
        check("changed recognition is not rewritten", continuationOpening("Inside", contextual: "in") == "Inside")
        check("sentence opening has no casing override", continuationOpening("Turning", contextual: nil) == "Turning")
        let tokens = [TimedToken(text: "sentence.", start: 0, end: 0.8),
                      TimedToken(text: "in", start: 1, end: 1.2),
                      TimedToken(text: "the", start: 1.2, end: 1.4),
                      TimedToken(text: "middle", start: 1.4, end: 1.6),
                      TimedToken(text: "of", start: 1.6, end: 1.8)]
        let candidate = SegmentCut(time: 1.1, committed: [], pending: [], reason: "sentence")
        check("sentence verification rejects shifted mid-sentence ownership",
              confirmRetainedCut(candidate, tokens: tokens, retainedWords: ["the", "middle", "of"], headIsQuiet: false) == nil)
        check("sentence verification accepts actual sentence ownership",
              confirmRetainedCut(candidate, tokens: tokens, retainedWords: ["In", "the", "middle"], headIsQuiet: false)?.committed == ["sentence."])
    }

    // timedTokens
    do {
        let transcription = WhisperTranscription(task: nil, language: nil, duration: nil, text: "", segments: [
            WhisperSegment(id: nil, text: "", start: 0, end: 0, words: [
                WhisperWord(word: " Hello", start: 0.1, end: 0.5, probability: nil),
                WhisperWord(word: " wor", start: 0.5, end: 0.7, probability: nil),
                WhisperWord(word: "ld", start: 0.7, end: 0.9, probability: nil),
                WhisperWord(word: ".", start: 0.9, end: 1.0, probability: nil)
            ]),
            WhisperSegment(id: nil, text: "", start: 0, end: 0, words: [
                WhisperWord(word: " Again", start: 1.5, end: 2.0, probability: nil)
            ])
        ])
        let tokens = timedTokens(transcription, offset: 0.1)
        let expected = [
            TimedToken(text: "Hello", start: 0.0, end: 0.4),
            TimedToken(text: "world.", start: 0.4, end: 0.9),
            TimedToken(text: "Again", start: 1.4, end: 1.9)
        ]
        check("timedTokens joins pieces and keeps the last end time", approxEqual(tokens, expected), "got \(tokens)")
        let overlap = timedTokens(transcription, offset: -5.9)
        check("local overlap timestamps map back to the full buffer", abs(overlap[0].start - 6.0) < 0.0001 && abs(overlap[1].end - 6.9) < 0.0001)
    }

    // quietRuns on a synthetic signal: tone, gap, tone, with light noise everywhere.
    do {
        let samples = synthesize(rate: rate, parts: [(0.8, true), (0.4, false), (0.8, true)])
        let runs = quietRuns(samples: samples, sampleRate: rate, config: config)
        check("quietRuns finds the gap", runs.count == 1, "got \(runs)")
        if let run = runs.first {
            check("quietRuns gap starts near 0.8", abs(run.start - 0.8) < 0.03, "got \(run)")
            check("quietRuns gap ends near 1.2", abs(run.end - 1.2) < 0.03, "got \(run)")
        }
        check("containsSpeech is true with tone", containsSpeech(samples: samples, sampleRate: rate, config: config))
        let silence = synthesize(rate: rate, parts: [(1.5, false)])
        check("containsSpeech is false on noise only", !containsSpeech(samples: silence, sampleRate: rate, config: config))
    }

    // trustedSentenceEnds
    do {
        let tokens = [
            TimedToken(text: "One.", start: 0.6, end: 1.0),
            TimedToken(text: "Two", start: 1.6, end: 2.0),
            TimedToken(text: "three.", start: 2.6, end: 3.0)
        ]
        check("period on the last token is not trusted", trustedSentenceEnds(tokens) == [0], "got \(trustedSentenceEnds(tokens))")
        let trailingPunctuation = tokens + [TimedToken(text: "...", start: 2.8, end: 3.2)]
        check("trailing punctuation does not make the last sentence trusted", trustedSentenceEnds(trailingPunctuation) == [0])
    }

    // chooseCut: sentence with a pause nearby
    do {
        let tokens = [
            TimedToken(text: "Hello", start: 0.1, end: 0.5),
            TimedToken(text: "world.", start: 0.6, end: 1.0),
            TimedToken(text: "How", start: 1.4, end: 1.8),
            TimedToken(text: "are", start: 1.6, end: 2.0)
        ]
        let quiet = [QuietRun(start: 1.1, end: 1.5)]
        var limited = config
        limited.trimAfterSeconds = 2.0
        let cut = chooseCut(tokens: tokens, quiet: quiet, duration: 2.2, config: limited)
        check("sentence cut lands inside the pause", cut != nil && cut!.time > 1.1 && cut!.time < 1.5, "got \(String(describing: cut))")
        check("sentence cut commits the sentence", cut?.committed == ["Hello", "world."], "got \(String(describing: cut))")
        check("sentence cut keeps the rest pending", cut?.pending == ["How", "are"], "got \(String(describing: cut))")
        check("sentence cut reason", cut?.reason == "sentence")
    }

    // Interior pauses do not outrank complete sentences; keep later candidates
    // available when the first sentence's acoustic verification fails.
    do {
        let tokens = [TimedToken(text: "word", start: 0.1, end: 0.4),
                      TimedToken(text: "continues.", start: 2, end: 2.5),
                      TimedToken(text: "Next", start: 3, end: 3.5),
                      TimedToken(text: "sentence.", start: 4, end: 4.5),
                      TimedToken(text: "More", start: 5, end: 5.3)]
        let quiet = [QuietRun(start: 0.5, end: 1.8), QuietRun(start: 2.6, end: 2.9), QuietRun(start: 4.6, end: 4.9)]
        let candidates = sentenceCuts(tokens: tokens, quiet: quiet, minimumCut: 0.5, duration: 6, config: config)
        check("all sentence boundaries precede pause fallback", candidates.map(\.committed) == [["word", "continues."], ["word", "continues.", "Next", "sentence."]])
    }

    // chooseCut: two pauses near the sentence end, the right one ends where the next word starts
    do {
        let tokens = [
            TimedToken(text: "that", start: 0.1, end: 0.5),
            TimedToken(text: "key.", start: 0.6, end: 1.2),
            TimedToken(text: "Passing", start: 1.2, end: 1.5),
            TimedToken(text: "a", start: 1.5, end: 1.6),
            TimedToken(text: "type", start: 2.1, end: 2.4)
        ]
        let quiet = [QuietRun(start: 0.95, end: 1.15), QuietRun(start: 1.6, end: 2.1)]
        var limited = config
        limited.trimAfterSeconds = 2.0
        let cut = chooseCut(tokens: tokens, quiet: quiet, duration: 2.6, config: limited)
        check("sentence cut picks the pause before the next word, not the longest", cut != nil && cut!.time > 0.95 && cut!.time < 1.15, "got \(String(describing: cut))")
    }

    // wordIndexForRunes with split-off punctuation
    do {
        let text = joinText("It works. Yes, key.", "type like tuple")
        let words = splitWords(text.text)
        let index = wordIndexForRunes(words: words, stableRunes: text.stableRunes)
        check("pending starts at the first pending word despite punctuation words", words.indices.contains(index) && words[index] == "type", "got \(index) in \(words)")
    }

    // chooseCut: sentence but no pause near it
    do {
        let tokens = [
            TimedToken(text: "Hello", start: 0.1, end: 0.5),
            TimedToken(text: "world.", start: 0.6, end: 1.0),
            TimedToken(text: "How", start: 1.4, end: 1.8)
        ]
        let quiet = [QuietRun(start: 2.0, end: 2.2)]
        var limited = config
        limited.trimAfterSeconds = 2.0
        let cut = chooseCut(tokens: tokens, quiet: quiet, duration: 2.3, config: limited)
        check("without a sentence pause retain the full recording", cut == nil, "got \(String(describing: cut))")
    }

    // chooseCut: period on the last token only
    do {
        let tokens = [
            TimedToken(text: "Hello", start: 0.1, end: 0.5),
            TimedToken(text: "world.", start: 0.6, end: 1.0)
        ]
        let quiet = [QuietRun(start: 1.0, end: 1.4)]
        let cut = chooseCut(tokens: tokens, quiet: quiet, duration: 1.4, config: config)
        check("no cut on the end-of-audio period", cut == nil, "got \(String(describing: cut))")
    }

    // isQuiet
    do {
        let loud = synthesize(rate: rate, parts: [(0.3, true)])
        let soft = synthesize(rate: rate, parts: [(0.3, false)])
        check("isQuiet is false on tone", !isQuiet(loud[...], threshold: 0.01))
        check("isQuiet is true on noise", isQuiet(soft[...], threshold: 0.01))
    }

    // The duration threshold never forces a cut inside an unfinished sentence.
    do {
        let tokens = (0..<70).map { TimedToken(text: "w\($0)", start: Double($0) + 0.3, end: Double($0) + 0.9) }
        let quiet = [QuietRun(start: 10, end: 10.2), QuietRun(start: 20, end: 20.4)]
        for duration in [28.0, 29.5, 45, 70] {
            check("unfinished sentence survives \(duration)s even with pauses", chooseCut(tokens: tokens, quiet: quiet, duration: duration, config: config) == nil)
            check("continuous sentence survives \(duration)s", chooseCut(tokens: tokens, quiet: [], duration: duration, config: config) == nil)
        }
        let complete = [TimedToken(text: "Finished.", start: 0.3, end: 44),
                        TimedToken(text: "Next", start: 45, end: 45.3),
                        TimedToken(text: "sentence", start: 45.5, end: 46)]
        let pause = [QuietRun(start: 44.2, end: 44.8)]
        check("long sentence can finish after the old ceiling", chooseCut(tokens: complete, quiet: pause, duration: 47, config: config)?.committed == ["Finished."])
    }

    // Three-sentence regression: commit only the first sentence at the duration limit.
    do {
        let tokens = [
            TimedToken(text: "First.", start: 0.5, end: 8.0),
            TimedToken(text: "Second?", start: 8.6, end: 20.0),
            TimedToken(text: "Third?", start: 20.6, end: 27.9)
        ]
        let quiet = [QuietRun(start: 8.1, end: 8.5), QuietRun(start: 20.1, end: 20.5)]
        check("no sentence cut below duration limit", chooseCut(tokens: tokens, quiet: quiet, duration: 27.9, config: config) == nil)
        check("sentence eligible exactly at lower threshold", chooseCut(tokens: tokens, quiet: quiet, duration: 28.0, config: config)?.committed == ["First."])
        let cut = chooseCut(tokens: tokens, quiet: quiet, duration: 28.03, config: config)
        check("commit only the first complete sentence", cut?.committed == ["First."] && cut?.pending == ["Second?", "Third?"], "got \(String(describing: cut))")
        check("cut is in first sentence pause", cut != nil && cut!.time > 8.1 && cut!.time < 8.5)
        let oversized = chooseCut(tokens: tokens, quiet: quiet, duration: 40.0, config: config)
        check("longer input retains the earliest complete sentence boundary", oversized?.committed == ["First."] && oversized?.pending == ["Second?", "Third?"], "got \(String(describing: oversized))")
        var shorter = config
        shorter.trimAfterSeconds = 10
        let adjusted = chooseCut(tokens: tokens, quiet: quiet, duration: 28.03, config: shorter)
        check("threshold changes eligibility, not sentence ownership", adjusted?.committed == ["First."])
        let many = (0..<12).map { TimedToken(text: "Sentence\($0).", start: Double($0), end: Double($0) + 0.5) }
        check("sentence count alone never triggers trimming", chooseCut(tokens: many, quiet: quiet, duration: 12.0, config: config) == nil)
    }

    // Resampler: a 440 Hz tone at 24 kHz comes out as the same tone at 16 kHz, whatever the chunking
    do {
        let resampler = Resampler(outputRate: 16_000)
        let inputRate = 24_000.0
        var output: [Float] = []
        var index = 0
        for chunkSize in [240, 480, 100, 7, 1000, 480, 480] {
            let chunk = (index..<(index + chunkSize)).map { Float(sin(2 * Double.pi * 440 * Double($0) / inputRate)) }
            output.append(contentsOf: resampler.process(chunk, inputRate: inputRate))
            index += chunkSize
        }
        let expectedCount = Int(Double(index) * 16_000 / inputRate)
        check("resampler keeps the duration", abs(output.count - expectedCount) <= 2, "got \(output.count), expected about \(expectedCount)")
        var worst: Float = 0
        for (i, sample) in output.enumerated() {
            let expected = Float(sin(2 * Double.pi * 440 * Double(i) / 16_000))
            worst = max(worst, abs(sample - expected))
        }
        check("resampler keeps the waveform", worst < 0.02, "worst error \(worst)")
        let passthrough = resampler.process([0.5, 0.25], inputRate: 16_000)
        check("resampler passes matching rate through after a rate change", passthrough == [0.5, 0.25], "got \(passthrough)")
    }

    // Actual retained audio decides the word division, even when timestamps disagree.
    do {
        let tokens = [TimedToken(text: "schedule.", start: 0.5, end: 1.1),
                      TimedToken(text: "The", start: 1.6, end: 2.3),
                      TimedToken(text: "slowdown", start: 2.5, end: 2.9),
                      TimedToken(text: "is", start: 3.0, end: 3.2),
                      TimedToken(text: "gone", start: 3.3, end: 3.6)]
        let boundary = SegmentCut(time: 2, committed: [], pending: [], reason: "sentence")
        let retained = confirmRetainedCut(boundary, tokens: tokens, retainedWords: ["The", "slowdown", "is", "gone"], headIsQuiet: false)
        check("The stays with actual retained audio", retained?.committed == ["schedule."] && retained?.pending == ["The", "slowdown", "is", "gone"])
        check("reject invented retained words", confirmRetainedCut(boundary, tokens: tokens, retainedWords: ["Thank", "you", "everyone"], headIsQuiet: false) == nil)
        check("reject too short retained recognition", confirmRetainedCut(boundary, tokens: tokens, retainedWords: ["The", "slowdown"], headIsQuiet: false) == nil)
        check("quiet head cannot commit speech", confirmRetainedCut(boundary, tokens: tokens, retainedWords: ["The", "slowdown", "is"], headIsQuiet: true) == nil)
        let repeated = [TimedToken(text: "very", start: 0.5, end: 0.9),
                        TimedToken(text: "very", start: 2.2, end: 2.5),
                        TimedToken(text: "good", start: 2.6, end: 2.9),
                        TimedToken(text: "indeed", start: 3, end: 3.3)]
        let repetitionBoundary = SegmentCut(time: 2, committed: [], pending: [], reason: "alternate pause", timeBased: true)
        let repetition = confirmRetainedCut(repetitionBoundary, tokens: repeated, retainedWords: ["very", "good", "indeed"], headIsQuiet: false)
        check("preserve genuine repetition across boundary", repetition?.committed == ["very"] && repetition?.pending == ["very", "good", "indeed"])
        let ambiguous = (0..<6).map { TimedToken(text: "yes", start: 1.5 + Double($0) * 0.1, end: 2.2) }
        check("reject ambiguous repeated anchor", confirmRetainedCut(boundary, tokens: ambiguous, retainedWords: ["yes", "yes", "yes"], headIsQuiet: false) == nil)
        let thanks = [TimedToken(text: "Thank", start: 0.5, end: 0.7), TimedToken(text: "you.", start: 0.8, end: 1.1)] + Array(tokens.dropFirst(1))
        let spoken = confirmRetainedCut(boundary, tokens: thanks, retainedWords: ["The", "slowdown", "is"], headIsQuiet: false)
        check("preserve genuinely spoken Thank you", spoken?.committed == ["Thank", "you."])
    }

    // A valid retained anchor must not make an invented dictionary prefix permanent.
    do {
        let tail = [TimedToken(text: "How", start: 1.8, end: 2.0),
                    TimedToken(text: "does", start: 2.1, end: 2.2),
                    TimedToken(text: "your", start: 2.3, end: 2.4),
                    TimedToken(text: "memory", start: 2.5, end: 2.8),
                    TimedToken(text: "work?", start: 2.9, end: 3.2)]
        let opening = [TimedToken(text: "REDTRC,", start: 0, end: 0),
                       TimedToken(text: "BDL,", start: 0, end: 0),
                       TimedToken(text: "R.C.:", start: 0, end: 0),
                       TimedToken(text: "Interesting.", start: 0.3, end: 1.2)]
        let proposal = SegmentCut(time: 1.565, committed: [], pending: [], reason: "sentence")
        let retained = confirmRetainedCut(proposal, tokens: opening + tail, retainedWords: tail.map(\.text), headIsQuiet: false)
        check("retained anchor alone accepts contaminated opening", retained != nil)
        if let retained {
            check("head rejects dictionary prefix absent from audio", confirmCommittedCut(retained, headWords: ["Interesting."]) == nil)
            check("head preserves genuinely spoken dictionary words", confirmCommittedCut(retained, headWords: opening.map(\.text))?.committed == opening.map(\.text))
        }
        let clean = confirmRetainedCut(proposal, tokens: [opening.last!] + tail, retainedWords: tail.map(\.text), headIsQuiet: false)
        check("clean retry passes both sides", clean.flatMap { confirmCommittedCut($0, headWords: ["interesting"]) }?.pending == tail.map(\.text))
        let repeated = SegmentCut(time: 2, committed: ["very", "very", "good."], pending: ["Next"], reason: "continuous speech", timeBased: true)
        check("head check keeps genuine repetitions", confirmCommittedCut(repeated, headWords: ["Very", "very", "good"])?.committed == repeated.committed)
        check("head check rejects missing real words", confirmCommittedCut(repeated, headWords: ["very", "good"]) == nil)
        check("head check rejects extra words", confirmCommittedCut(repeated, headWords: ["very", "very", "good", "Next"]) == nil)
        check("head check rejects empty decode of speech", confirmCommittedCut(repeated, headWords: []) == nil)
    }

    // A long pause before an incomplete next word must not stall a capped window.
    do {
        let tokens = [TimedToken(text: "Call", start: 0.1, end: 0.4), TimedToken(text: "the", start: 0.5, end: 0.7), TimedToken(text: "bank.", start: 0.8, end: 1.2)]
        let boundary = SegmentCut(time: 2, committed: [], pending: [], reason: "long pause")
        check("verify complete head before long pause", confirmPauseHead(boundary, tokens: tokens, headWords: ["Call", "the", "bank."])?.committed == tokens.map(\.text))
        check("reject invented standalone head text", confirmPauseHead(boundary, tokens: tokens, headWords: ["Thank", "you."]) == nil)
        check("reject head text beyond the known prefix", confirmPauseHead(boundary, tokens: tokens, headWords: ["Call", "the", "bank", "again"]) == nil)
    }

    // Startup impulses do not open the gate; brief real words and chunk boundaries do.
    do {
        var transient = synthesize(rate: rate, parts: [(0.45, false), (0.01, true), (1.5, false)])
        var activity = SpeechActivityGate()
        activity.append(transient, sampleRate: rate, threshold: config.minThreshold)
        check("one loud frame is not speech", activity.speechEnd == nil)
        check("startup impulse produces no recognition window", recognitionWindow(samples: transient, sampleRate: rate, config: config).samples.isEmpty)
        transient = synthesize(rate: rate, parts: [(0.45, false), (0.12, true), (1.5, false)])
        var chunked = SpeechActivityGate()
        for start in stride(from: 0, to: transient.count, by: 171) {
            chunked.append(Array(transient[start..<min(transient.count, start + 171)]), sampleRate: rate, threshold: config.minThreshold)
        }
        check("short utterance survives arbitrary capture chunks", chunked.speechEnd != nil)
        check("pre-roll can preserve the first phoneme", abs(Double(chunked.firstSpeechStart ?? 0) / Double(rate) - 0.45) < 0.02)
        check("a completed short word becomes ready", chunked.readyForRecognition(sampleRate: rate))
        var beginning = SpeechActivityGate()
        beginning.append(synthesize(rate: rate, parts: [(0.12, true)]), sampleRate: rate, threshold: config.minThreshold)
        check("partial opening speech waits for context", !beginning.readyForRecognition(sampleRate: rate))
        let quietContinuous = synthesize(rate: rate, parts: [(2, true)]).map { $0 * 0.02 }
        check("quiet continuous activity is not discarded by a higher adaptive cut threshold", !recognitionWindow(samples: quietContinuous, sampleRate: rate, config: config).samples.isEmpty)
    }

    // Long speech remains available to recognition; trailing silence is excluded without changing source offsets.
    do {
        let samples = synthesize(rate: rate, parts: [(2, true), (65, false)])
        let window = recognitionWindow(samples: samples, sampleRate: rate, config: config)
        check("trim quiet tail from request", window.samples.count <= Int(2.21 * Double(rate)))
        check("speech end remains in source coordinates", abs(Double(window.speechEnd) / Double(rate) - 2) < 0.02)
        let speech = synthesize(rate: rate, parts: [(70, true)])
        for seconds in [5, 10, 28] {
            var capped = config
            capped.trimAfterSeconds = Double(seconds)
            let bounded = recognitionWindow(samples: speech, sampleRate: rate, config: capped)
            check("70-second sentence is not capped by \(seconds)s trimming threshold", bounded.samples.count == speech.count)
        }
        let silence = recognitionWindow(samples: synthesize(rate: rate, parts: [(65, false)]), sampleRate: rate, config: config)
        check("silence produces no recognition input", silence.samples.isEmpty && silence.speechEnd == 0)
    }

    return failures
}

private func approxEqual(_ left: [TimedToken], _ right: [TimedToken]) -> Bool {
    guard left.count == right.count else { return false }
    for (a, b) in zip(left, right) where a.text != b.text || abs(a.end - b.end) > 0.0001 {
        return false
    }
    return true
}

/// Builds a signal from (seconds, loud) parts. Loud parts carry a tone, every part carries faint noise.
private func synthesize(rate: Int, parts: [(Double, Bool)]) -> [Float] {
    var result: [Float] = []
    var seed: UInt32 = 12345
    func noise() -> Float {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.002
    }
    for (seconds, loud) in parts {
        let count = Int(seconds * Double(rate))
        for i in 0..<count {
            let tone = loud ? Float(sin(Double(i) * 2 * Double.pi * 220 / Double(rate))) * 0.3 : 0
            result.append(tone + noise())
        }
    }
    return result
}
