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
