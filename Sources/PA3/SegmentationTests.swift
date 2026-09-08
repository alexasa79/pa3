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
    // Most cut tests look at a single sentence boundary, so they run without context sentences.
    var config = SegmentationConfig.default
    config.keepSentences = 0
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
        let cut = chooseCut(tokens: tokens, quiet: quiet, duration: 2.2, config: config)
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
        let cut = chooseCut(tokens: tokens, quiet: quiet, duration: 2.6, config: config)
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
        let cut = chooseCut(tokens: tokens, quiet: quiet, duration: 2.3, config: config)
        check("no cut without a pause near the sentence end", cut == nil, "got \(String(describing: cut))")
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
        check("window cap cuts at the latest clear pause", cut?.reason == "window cap" && cut != nil && abs(cut!.time - 20.2) < 0.001, "got \(String(describing: cut))")
        check("window cap commits words before the pause", cut?.committed.count == 20, "got \(String(describing: cut?.committed.count))")
        let noPause = chooseCut(tokens: tokens, quiet: [], duration: 29.5, config: config)
        check("window cap without pause still cuts", noPause != nil && noPause!.time > 0, "got \(String(describing: noPause))")
        let under = chooseCut(tokens: Array(tokens.prefix(10)), quiet: [QuietRun(start: 5.0, end: 5.2)], duration: 10.0, config: config)
        check("no cap cut under the limit", under == nil, "got \(String(describing: under))")
    }

    // chooseCut: context sentences stay in the buffer
    do {
        let tokens = [
            TimedToken(text: "One.", start: 0.5, end: 0.9),
            TimedToken(text: "Two.", start: 1.5, end: 1.9),
            TimedToken(text: "Three.", start: 2.5, end: 2.9),
            TimedToken(text: "Four.", start: 3.5, end: 3.9),
            TimedToken(text: "tail", start: 4.5, end: 4.8)
        ]
        let quiet = [QuietRun(start: 1.0, end: 1.4), QuietRun(start: 2.0, end: 2.4), QuietRun(start: 3.0, end: 3.4), QuietRun(start: 4.0, end: 4.4)]
        var keepTwo = config
        keepTwo.keepSentences = 2
        let cut = chooseCut(tokens: tokens, quiet: quiet, duration: 5.0, config: keepTwo)
        check("keep two leaves two sentences behind the cut", cut?.committed == ["One.", "Two."] && cut?.pending == ["Three.", "Four.", "tail"], "got \(String(describing: cut))")
        check("keep two cuts in the pause after the committed sentence", cut != nil && cut!.time > 2.0 && cut!.time < 2.4, "got \(String(describing: cut))")
        var keepFour = config
        keepFour.keepSentences = 4
        check("no cut while fewer sentences than the context wants", chooseCut(tokens: tokens, quiet: quiet, duration: 5.0, config: keepFour) == nil)
        var capped = keepFour
        capped.maxBuffer = 4.0
        let overCap = chooseCut(tokens: tokens, quiet: quiet, duration: 5.0, config: capped)
        check("over the cap the context is given up before cutting by time", overCap?.reason == "sentence, no context" && overCap?.committed.count == 4, "got \(String(describing: overCap))")
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
