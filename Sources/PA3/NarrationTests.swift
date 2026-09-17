import Foundation

func runNarrationTests() -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ name: String) { if !condition { failures.append("narration: " + name) } }
    check(SelectedText.substring("A🙂 café", range: CFRange(location: 1, length: 2)) == "🙂", "AX selection uses UTF-16 offsets")
    check(SelectedText.substring("hello", range: CFRange(location: 0, length: 0)) == nil, "empty selection must not read the whole field")
    check(SelectedText.substring("hello", range: CFRange(location: Int.max, length: Int.max)) == nil, "invalid AX range must not overflow")
    check(SelectedText.substring("hello", range: CFRange(location: -1, length: 2)) == nil, "negative AX range must be rejected")
    check(NarrationVoice.resolve(nil) == "senior-engineer-american", "omitted voice must select sample 4")
    check(NarrationVoice.resolve("4") == NarrationVoice.resolve(nil), "sample number must select the default voice")
    check(NarrationVoice.resolve("04-senior-engineer-american") == NarrationVoice.resolve(nil), "sample filename alias must select the default voice")
    check(NarrationVoice.resolve("aiden") == nil, "unsupported preset must be rejected")
    check(NarrationVoice.resolve("unknown") == nil, "unknown voice accepted")
    func parsedStatus(_ raw: String) -> Int {
        switch NarrationHTTPRequest.parse(Data(raw.utf8)) {
        case .incomplete: return 0
        case .request: return 200
        case .rejected(let response): return response.status
        }
    }
    let body = Data("{\"text\":\"Привет 🌍\"}".utf8)
    var request = Data("POST /v1/narrations HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
    request.append(body)
    for length in 0..<request.count {
        if case .incomplete = NarrationHTTPRequest.parse(Data(request.prefix(length))) {} else {
            failures.append("narration: fragmented request rejected at byte \(length)")
            break
        }
    }
    if case .request(let parsed) = NarrationHTTPRequest.parse(request) {
        check(parsed.body == body && parsed.method == "POST" && parsed.path == "/v1/narrations", "UTF-8 HTTP body was altered")
    } else { failures.append("narration: complete request rejected") }
    check(parsedStatus("POST / HTTP/1.1\r\nContent-Length: 0\r\ncontent-length: 5\r\n\r\n") == 400, "duplicate lengths accepted")
    check(parsedStatus("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n") == 400, "chunked request accepted")
    check(parsedStatus("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n") == 400, "negative length accepted")
    check(parsedStatus("POST / HTTP/1.1\r\nContent-Length: 9999999999999999999999999\r\n\r\n") == 400, "overflowing length accepted")
    check(parsedStatus("POST / HTTP/1.1\r\nContent-Length: 512001\r\n\r\n") == 413, "oversized body accepted")
    check(parsedStatus(String(repeating: "x", count: 16_385)) == 413, "oversized header accepted")
    check(parsedStatus("GET /health HTTP/1.1\r\n\r\nGET /health HTTP/1.1\r\n\r\n") == 400, "pipelined requests accepted")
    do {
        let input = NarrationInput(text: "SQL SQLAlchemy PA3 PA30. New York York.", pronunciations: ["SQL": "sequel", "PA3": "P A three", "New York": "York", "York": "Y"])
        let result = try NarrationText.prepare(input).joined(separator: " ")
        check(result == "sequel SQLAlchemy P A three PA30. York Y.", "word boundaries or nonrecursive longest match failed")
        let unicode = "Привет, мир. " + String(repeating: "🙂", count: 901) + " Final sentence."
        let chunks = try NarrationText.prepare(NarrationInput(text: unicode))
        check(chunks.allSatisfy { $0.count <= 300 }, "chunk limit exceeded")
        check(chunks.joined().filter { !$0.isWhitespace } == unicode.filter { !$0.isWhitespace }, "Unicode chunking lost text")
        let streamed = try NarrationText.plan(NarrationInput(text: unicode, output: "pieces"))
        check(streamed.contains { $0.text.contains(String(repeating: "🙂", count: 901)) }, "unpunctuated streaming text stays intact")
        let paragraph = "The day we discovered we had been designated a global terrorist organization, we promised that we would try to resist as long as this was possible, that we would not back down as long as we could see options to stand our ground."
        let clauses = try NarrationText.plan(NarrationInput(text: paragraph, output: "pieces"))
        check(clauses.map(\.text) == [
            "The day we discovered we had been designated a global terrorist organization,",
            "we promised that we would try to resist as long as this was possible,",
            "that we would not back down as long as we could see options to stand our ground."
        ], "streaming keeps terrorist organization together and splits at commas")
        check(clauses.allSatisfy { (paragraph as NSString).substring(with: $0.sourceRange) == $0.text }, "clause source ranges preserve highlighting")
        let unpunctuated = String(repeating: "keep these words together ", count: 8).trimmingCharacters(in: .whitespaces) + "."
        check(try NarrationText.prepare(NarrationInput(text: unpunctuated, output: "pieces")) == [unpunctuated], "no arbitrary word splits without clause punctuation")
        let longOpening = "The narration should keep this sufficiently long opening clause together"
        for punctuation in [",", ";"] {
            let sentence = longOpening + punctuation + " even now."
            let pieces = try NarrationText.plan(NarrationInput(text: sentence, output: "pieces"))
            check(pieces.map(\.text) == [sentence], "short ending stays attached after " + punctuation)
            check(pieces.first?.sourceRange == NSRange(location: 0, length: sentence.utf16.count), "merged ending source range")
        }
        for length in [40, 41] {
            let sentence = longOpening + ", " + String(repeating: "x", count: length - 1) + "."
            let pieces = try NarrationText.prepare(NarrationInput(text: sentence, output: "pieces"))
            check(pieces.count == (length == 40 ? 1 : 2), "short ending threshold at \(length) characters")
        }
        let numeric = "The processing system expects a total of exactly 1,000 entries at https://example.org/path before completing this operation."
        check(try NarrationText.prepare(NarrationInput(text: numeric, output: "pieces")) == [numeric], "number and URL punctuation are not clause boundaries")
        for punctuation in [";", ":", "—", "，", "；", "："] {
            let opening = "This opening clause has enough words to exceed the startup target" + punctuation
            let source = opening + " " + unpunctuated
            let parts = try NarrationText.plan(NarrationInput(text: source, output: "pieces"))
            check(parts.first?.text == opening, "streaming clause boundary at " + punctuation)
        }
        check(streamed.map(\.text).joined().filter { !$0.isWhitespace } == unicode.filter { !$0.isWhitespace }, "streaming Unicode chunks preserve all text")
        check(streamed.allSatisfy { (unicode as NSString).substring(with: $0.sourceRange) == $0.text }, "streaming source ranges match every piece")
        let list = try NarrationText.prepare(NarrationInput(text: "Introduction.\n1. Check the server. It should be ready.\n2) Start the client.\n10. Verify version 3.14 is installed."))
        check(list.contains("1, Check the server."), "list number must stay with its sentence")
        check(list.contains("2, Start the client."), "parenthesized list label")
        check(list.contains("10, Verify version 3.14 is installed."), "multi-digit label must preserve decimal values")
        check(list.first == "Introduction." && !list.contains("1."), "list marker must not join preceding sentence or stand alone")
        let wrappedList = try NarrationText.prepare(NarrationInput(text: "1.\nCheck the\nserver.\n2)\nStart the client."))
        check(wrappedList == ["1, Check the server.", "2, Start the client."], "AX line breaks must not separate list markers or wrapped item text")
        let boundaries = try NarrationText.plan(NarrationInput(text: "Follow these steps:\n1. Check the server.\n2. Start the client.\nThe list is finished.\n\nThis is another paragraph. It has another sentence."))
        check(boundaries.map(\.pauseAfter) == [0.65, 0.40, 0.65, 0.65, 0.20, 0.20], "intro, list items, list end, paragraph, and sentence pauses")
        let bulletSource = "Before the list:\n• First item.\n- Second item.\nAfter the list."
        let bullets = try NarrationText.plan(NarrationInput(text: bulletSource))
        check(bullets.map(\.text) == ["Before the list:", "First item.", "Second item.", "After the list."], "bullet markers must not be spoken or merge with prose")
        check(bullets.map(\.pauseAfter) == [0.65, 0.40, 0.65, 0.20], "bullet list boundaries")
        let mappedSource = "🙂 SQL first.\n\n2. SQL again."
        let mapped = try NarrationText.plan(NarrationInput(text: mappedSource, pronunciations: ["SQL": "structured query language"]))
        check(mapped.map { (mappedSource as NSString).substring(with: $0.sourceRange) } == ["🙂 SQL first.", "2. SQL again."], "source ranges survive Unicode, aliases, and list normalization")
        let crlf = try NarrationText.plan(NarrationInput(text: "Steps:\r\n1. Check the\r\nserver.\r\n2. Start it.\r\n\r\nAfterward."))
        check(crlf.map(\.text) == ["Steps:", "1, Check the server.", "2, Start it.", "Afterward."], "CRLF list and wrapped line handling")
        check(crlf.map(\.pauseAfter) == [0.65, 0.40, 0.65, 0.20], "CRLF paragraph pauses")
        let paragraphs = try NarrationText.plan(NarrationInput(text: "First paragraph.\nSecond paragraph.\u{2029}Third paragraph."))
        check(paragraphs.map(\.pauseAfter) == [0.65, 0.65, 0.20], "single-newline and AX paragraph boundaries")
        for range in ["A..B", "1..10", "A .. B", "-5..-1", "α..ω", "items[0]..items[n]", "A..\nB"] {
            let first = "Use \(range) to select the complete range."
            let second = "The following sentence describes the result."
            for output in ["playback", "pieces", "stream"] {
                let parts = try NarrationText.plan(NarrationInput(text: first + " " + second, output: output))
                check(parts.map(\.text) == [first.replacingOccurrences(of: "\n", with: " "), second], "two-dot range stays in its sentence: \(range), \(output)")
                check(parts.map(\.pauseAfter) == [0.20, 0.20], "range introduces no extra pauses: \(range), \(output)")
            }
        }
        for first in ["The allowed range is A..B.", "Wait...", "The value is 3.14.", "The label is \"ready\"."] {
            let second = "The following sentence describes the result."
            let parts = try NarrationText.plan(NarrationInput(text: first + " " + second, output: "stream"))
            check(parts.map(\.text) == [first, second], "real sentence boundary after range, decimal, quote, or ellipsis: \(first)")
        }
        for (opening, closing) in [("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’"), ("«", "»"), ("(\"", "\")")] {
            for punctuation in [".", "?", "!", "?!"] {
                let first = "The editor said \(opening)This article is ready\(punctuation)\(closing)"
                let second = "The next paragraph explains the details."
                let parts = try NarrationText.plan(NarrationInput(text: first + " " + second, output: "stream"))
                check(parts.map(\.text) == [first, second], "closing quote stays with sentence: \(closing), \(punctuation)")
                check(parts.map(\.pauseAfter) == [0.20, 0.20], "quoted ending receives a sentence pause: \(closing), \(punctuation)")
            }
        }
        let quotedRanges = "🙂 The editor said \"Use A..B and 1..10 for these ranges.\" “Continue with α .. ω.”"
        let quotedParts = try NarrationText.plan(NarrationInput(text: quotedRanges, output: "stream"))
        check(quotedParts.map(\.text) == ["🙂 The editor said \"Use A..B and 1..10 for these ranges.\"", "“Continue with α .. ω.”"], "Unicode ranges inside quoted sentences")
        check(quotedParts.allSatisfy { (quotedRanges as NSString).substring(with: $0.sourceRange) == $0.text }, "range protection preserves original Unicode source offsets and punctuation")
        let noPeriods = try NarrationText.plan(NarrationInput(text: "Options:\n● Faster startup\n● Lower memory\nThe next paragraph begins."))
        check(noPeriods.map(\.text) == ["Options:", "Faster startup", "Lower memory", "The next paragraph begins."], "unpunctuated bullet list followed by prose")
        check(noPeriods.map(\.pauseAfter) == [0.65, 0.40, 0.65, 0.20], "unpunctuated list boundary pauses")
        check((chunks.first?.count ?? 0) <= 160, "opening piece should start promptly")
    } catch { failures.append("narration: unexpected text preparation error \(error)") }
    let rate = 1000.0
    let signal = [Float](repeating: 0, count: 500) + [Float](repeating: 0.1, count: 200)
        + [Float](repeating: 0, count: 600) + [Float](repeating: 0.1, count: 200) + [Float](repeating: 0, count: 1000)
    check(NarrationAudio.speechRange(signal, rate: rate) == 460..<1580, "trim edges while preserving interior silence and speech padding")
    check(NarrationAudio.speechRange([Float](repeating: 0, count: 100), rate: rate) == nil, "silent output must be rejected")
    for invalid in [NarrationInput(text: " \n"), NarrationInput(text: String(repeating: "x", count: 100_001)),
                    NarrationInput(text: "test", pronunciations: ["": "empty"]),
                    NarrationInput(text: String(repeating: "x ", count: 49_999), pronunciations: ["x": String(repeating: "y", count: 256)])] {
        do { _ = try NarrationText.prepare(invalid); failures.append("narration: invalid text input accepted") }
        catch {}
    }
    return failures
}
