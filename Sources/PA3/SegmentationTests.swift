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
        limited.maxBuffer = 2.0
        let cut = chooseCut(tokens: tokens, quiet: quiet, duration: 2.2, config: limited)
        check("sentence cut lands inside the pause", cut != nil && cut!.time > 1.1 && cut!.time < 1.5, "got \(String(describing: cut))")
        check("sentence cut commits the sentence", cut?.committed == ["Hello", "world."], "got \(String(describing: cut))")
        check("sentence cut keeps the rest pending", cut?.pending == ["How", "are"], "got \(String(describing: cut))")
        check("sentence cut reason", cut?.reason == "sentence")
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
        limited.maxBuffer = 2.0
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
        limited.maxBuffer = 2.0
        let cut = chooseCut(tokens: tokens, quiet: quiet, duration: 2.3, config: limited)
        check("without a pause near the sentence use a time-based pause cut", cut?.reason == "window cap" && cut?.timeBased == true, "got \(String(describing: cut))")
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

    // chooseCut: window cap
    do {
        var tokens: [TimedToken] = []
        for i in 0..<30 {
            tokens.append(TimedToken(text: "w\(i)", start: Double(i) + 0.3, end: Double(i) + 0.9))
        }
        let quiet = [QuietRun(start: 10.0, end: 10.2), QuietRun(start: 20.0, end: 20.4)]
        let cut = chooseCut(tokens: tokens, quiet: quiet, duration: 29.5, config: config)
        check("window cap cuts at the earliest sufficient pause", cut?.reason == "window cap" && cut != nil && abs(cut!.time - 10.1) < 0.001, "got \(String(describing: cut))")
        check("window cap commits words before the pause", cut?.committed.count == 10, "got \(String(describing: cut?.committed.count))")
        let noPause = chooseCut(tokens: tokens, quiet: [], duration: 29.5, config: config)
        check("without a pause retain almost the full duration limit", noPause != nil && abs((29.5 - noPause!.time) - 27.99) < 0.001, "got \(String(describing: noPause))")
        let spanning = chooseCut(tokens: tokens, quiet: [QuietRun(start: 1.0, end: 2.0)], duration: 29.5, config: config)
        check("a pause spanning the required cut is usable", spanning != nil && spanning!.time > 1.5 && spanning!.time < 2.0)
        let oldPause = chooseCut(tokens: tokens, quiet: [QuietRun(start: 0.2, end: 0.4)], duration: 29.5, config: config)
        check("a pause that removes too little audio is skipped", oldPause?.reason == "window cap, no pause" && oldPause != nil && 29.5 - oldPause!.time < 28)
        let unsorted = chooseCut(tokens: tokens, quiet: Array(quiet.reversed()), duration: 29.5, config: config)
        check("pause order cannot cause excess trimming", unsorted == cut)
        let under = chooseCut(tokens: Array(tokens.prefix(10)), quiet: [QuietRun(start: 5.0, end: 5.2)], duration: 10.0, config: config)
        check("no cap cut under the limit", under == nil, "got \(String(describing: under))")
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
        check("no sentence cut exactly at duration limit", chooseCut(tokens: tokens, quiet: quiet, duration: 28.0, config: config) == nil)
        let cut = chooseCut(tokens: tokens, quiet: quiet, duration: 28.03, config: config)
        check("first sentence is enough to get below limit", cut?.committed == ["First."] && cut?.pending == ["Second?", "Third?"], "got \(String(describing: cut))")
        check("cut is in first sentence pause", cut != nil && cut!.time > 8.1 && cut!.time < 8.5)
        check("confirmed first sentence preserves the remaining sentences", cut != nil && confirmCut(cut!, headTokens: ["First."], allTokens: tokens.map(\.text)) == cut)
        let oversized = chooseCut(tokens: tokens, quiet: quiet, duration: 40.0, config: config)
        check("skip an early boundary if it removes too little", oversized?.committed == ["First.", "Second?"] && oversized?.pending == ["Third?"], "got \(String(describing: oversized))")
        var shorter = config
        shorter.maxBuffer = 10
        let adjusted = chooseCut(tokens: tokens, quiet: quiet, duration: 28.03, config: shorter)
        check("changing seconds changes the required cut", adjusted?.committed == ["First.", "Second?"])
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

    // confirmCut
    do {
        let sentence = SegmentCut(time: 1.3, committed: ["How", "does", "it", "work?"], pending: ["What", "does"], reason: "sentence")
        check("confirmCut accepts a matching head", confirmCut(sentence, headTokens: ["How", "does", "it", "work?"], allTokens: []) == sentence)
        check("confirmCut tolerates one changed word", confirmCut(sentence, headTokens: ["How", "does", "it", "walk?"], allTokens: [])?.committed == sentence.committed)
        check("confirmCut rejects a short head", confirmCut(sentence, headTokens: ["How", "does"], allTokens: []) == nil)
        check("confirmCut rejects different words", confirmCut(sentence, headTokens: ["Walk", "me", "through", "it."], allTokens: []) == nil)
        let all = ["How", "does", "it", "work?", "What", "does", "it", "do?", "Et", "cetera."]
        let extended = confirmCut(sentence, headTokens: ["How", "does", "it", "work?", "What", "does", "it", "do?"], allTokens: all)
        check("confirmCut extends over later sentences", extended?.committed == Array(all.prefix(8)) && extended?.pending == ["Et", "cetera."], "got \(String(describing: extended))")
        let timed = SegmentCut(time: 2.0, committed: ["the", "new"], pending: ["and"], reason: "window cap", timeBased: true)
        check("confirmCut takes the head for time based cuts", confirmCut(timed, headTokens: ["the", "new", "card."], allTokens: [])?.committed == ["the", "new", "card."])
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
