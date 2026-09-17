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
        for (path, spoken) in [
            ("a/b/c/something.cpp", "a slash b slash c slash something dot C P P"),
            ("src/rte/red_app_spdk.cpp", "src slash rte slash red underscore app underscore spdk dot C P P"),
            ("/usr/local/bin/tool", "slash usr slash local slash bin slash tool"),
            ("./src/main.cpp", "dot slash src slash main dot C P P"),
            ("../include/main.hpp", "dot dot slash include slash main dot H P P"),
            ("~/code/my-project/main.CPP", "tilde slash code slash my dash project slash main dot C P P"),
            ("src/.config/settings.json", "src slash dot config slash settings dot json"),
            ("src/version1.2/main.cpp", "src slash version1 dot 2 slash main dot C P P"),
            ("build/archive.tar.gz", "build slash archive dot tar dot G Z"),
            ("/Users/山田/main.swift", "slash Users slash 山田 slash main dot swift"),
            ("src/assets/", "src slash assets slash"),
            ("something.cpp", "something dot C P P"),
            ("a_b_c.cpp", "a underscore b underscore c dot C P P"),
            ("a__b.cpp", "a underscore underscore b dot C P P"),
            ("a/b/c", "a slash b slash c"),
            ("setup.bash", "setup dot bash"),
            ("setup.zsh", "setup dot Z S H"),
            ("setup.ps1", "setup dot P S one"),
            ("main.c++", "main dot C plus plus"),
            ("include/main.h++", "include slash main dot H plus plus"),
            ("app.py", "app dot P Y"),
            ("analysis.ipynb", "analysis dot I P Y N B"),
            ("main.go", "main dot go"),
            ("go.mod", "go dot mod"),
            ("types.d.ts", "types dot D dot T S"),
            ("bundle.min.mjs", "bundle dot min dot M J S"),
            ("Main.java", "Main dot java"),
            ("main.rs", "main dot R S"),
            ("project.csproj", "project dot C S P R O J"),
            ("report.DOCX", "report dot D O C X"),
            ("report.docm", "report dot D O C M"),
            ("template.dotx", "template dot D O T X"),
            ("budget.xls", "budget dot X L S"),
            ("budget.xlsx", "budget dot X L S X"),
            ("budget.xlsm", "budget dot X L S M"),
            ("budget.xlsb", "budget dot X L S B"),
            ("slides.pptx", "slides dot P P T X"),
            ("slides.ppsm", "slides dot P P S M"),
            ("contacts.accdb", "contacts dot A C C D B"),
            ("diagram.vsdx", "diagram dot V S D X"),
            ("notes.one", "notes dot one"),
            ("report.odt", "report dot O D T"),
            ("book.epub", "book dot epub"),
            ("photo.heic", "photo dot heic"),
            ("clip.mp3", "clip dot M P three"),
            ("clip.mp4", "clip dot M P four"),
            ("backup.7z", "backup dot seven Z"),
            ("build/backup.7z", "build slash backup dot seven Z"),
            ("archive.tar.bz2", "archive dot tar dot B Z two"),
            ("data.parquet", "data dot parquet"),
            ("application.dmg", "application dot D M G"),
            ("font.woff2", "font dot W O F F two"),
            ("certificate.p12", "certificate dot P one two"),
            ("src/custom.unlisted", "src slash custom dot unlisted")
        ] {
            for output in ["playback", "pieces", "stream"] {
                let original = "Open \(path)."
                let parts = try NarrationText.plan(NarrationInput(text: original, output: output))
                check(parts.map(\.text) == ["Open \(spoken)."], "explicit path pronunciation: \(path), \(output)")
                check(parts.first?.sourceRange == NSRange(location: 0, length: original.utf16.count), "path expansion preserves source offsets: \(path)")
                let repeated = try NarrationText.prepare(NarrationInput(text: parts.map(\.text).joined(separator: " "), output: output))
                check(repeated == parts.map(\.text), "Reedah's prepared path is not expanded twice: \(path)")
            }
        }
        let pathToken = try NarrationPath.tokenRegex()
        for original in [
            "Use and/or, read/write, I/O, and TCP/IP.", "On 2026/09/17 use 1/2 of 3.14.",
            "A..B and A..c are ranges. Wait... Then continue.", "Use ASP.NET and version 3.14.",
            "Visit https://example.org/src/main.cpp?x=a/b/c and https://example.org/a,b.cpp.",
            "Visit (https://example.org/a,b.cpp).", "See www.example.org/src/main.cpp or example.org/src/main.cpp.",
            "See file:///Users/me/main.cpp and ssh://host/a/b/c.", "Email user@example.org.",
            "Visit https://example.org/report.docx and www.example.org/backup.7z.",
            "Unknown custom.unlisted and version 3.7 stay unchanged."
        ] {
            let source = original as NSString
            check(pathToken.matches(in: original, range: NSRange(location: 0, length: source.length)).allSatisfy {
                let token = source.substring(with: $0.range)
                return NarrationPath.pronounce(token) == token
            }, "non-path tokens remain unchanged: \(original)")
        }
        let pathSource = "🙂 Open \"src/main.cpp\" now. Then inspect include/main.hpp carefully."
        let pathParts = try NarrationText.plan(NarrationInput(text: pathSource, output: "stream"))
        check(pathParts.map(\.text) == ["🙂 Open \"src slash main dot C P P\" now.", "Then inspect include slash main dot H P P carefully."], "quoted paths retain sentence punctuation")
        check(pathParts.map { (pathSource as NSString).substring(with: $0.sourceRange) } == ["🙂 Open \"src/main.cpp\" now.", "Then inspect include/main.hpp carefully."], "path expansion maps back to original sentences")
        let pathOverride = try NarrationText.prepare(NarrationInput(text: "Open src/main.cpp.", pronunciations: ["src/main.cpp": "the main source file"], output: "stream"))
        check(pathOverride == ["Open the main source file."], "custom path pronunciations take precedence")
        for path in ["src/main.cpp", "src/main.c", "src/Main.CPP", "../include/main.hpp", "a/B/C.cpp"] {
            let first = "Open \(path)."
            let second = "The next sentence describes the implementation."
            let parts = try NarrationText.plan(NarrationInput(text: first + " " + second, output: "stream"))
            check(parts.map(\.text) == ["Open \(NarrationPath.pronounce(path)).", second], "spelled extension does not swallow the next sentence: \(path)")
            check(parts.map(\.pauseAfter) == [0.20, 0.20], "path at sentence end retains a sentence pause: \(path)")
        }
        for (original, spoken) in [
            ("a_b.cpp:888", "a underscore b dot C P P, line 888,"),
            ("Open src/a_b.cpp:888 next.", "Open src slash a underscore b dot C P P, line 888, next."),
            ("Open a_b.cpp:888.", "Open a underscore b dot C P P, line 888."),
            ("a_b.cpp:888, then continue.", "a underscore b dot C P P, line 888, then continue."),
            ("a_b.cpp:888: error", "a underscore b dot C P P, line 888: error"),
            ("Read \"a_b.cpp:888\".", "Read \"a underscore b dot C P P, line 888\"."),
            ("See (a_b.cpp:888).", "See (a underscore b dot C P P, line 888)."),
            ("Read `a_b.cpp:888` next.", "Read `a underscore b dot C P P, line 888` next."),
            ("../src/a_b.cpp:888:12", "dot dot slash src slash a underscore b dot C P P, line 888, column 12,"),
            ("/tmp/Makefile:12", "slash tmp slash Makefile, line 12,"),
            ("a_b.cpp:888!", "a underscore b dot C P P, line 888!"),
            ("a_b.cpp:888; next", "a underscore b dot C P P, line 888; next"),
            ("file.c:100-200", "file dot C, lines 100 to 200,"),
            ("Check file.c:100-200.", "Check file dot C, lines 100 to 200."),
            ("src/a_b.cpp:100-200 next.", "src slash a underscore b dot C P P, lines 100 to 200, next."),
            ("file.c:100-200, then continue.", "file dot C, lines 100 to 200, then continue."),
            ("file.c:100-200: note", "file dot C, lines 100 to 200: note"),
            ("Read \"file.c:100-200\".", "Read \"file dot C, lines 100 to 200\"."),
            ("See (file.c:100-200).", "See (file dot C, lines 100 to 200)."),
            ("Read `file.c:100-200` next.", "Read `file dot C, lines 100 to 200` next."),
            ("../src/file.c:100-200", "dot dot slash src slash file dot C, lines 100 to 200,"),
            ("/tmp/Makefile:100-200", "slash tmp slash Makefile, lines 100 to 200,"),
            ("file-100-200.c", "file dash 100 dash 200 dot C")
        ] {
            for output in ["playback", "pieces", "stream"] {
                let parts = try NarrationText.plan(NarrationInput(text: original, output: output))
                check(parts.map(\.text) == [spoken], "line reference pronunciation and punctuation: \(original), \(output)")
                check(parts.first?.sourceRange == NSRange(location: 0, length: original.utf16.count), "line reference source mapping: \(original)")
                check(try NarrationText.prepare(NarrationInput(text: spoken, output: output)) == [spoken], "prepared line reference is not expanded twice: \(original)")
            }
        }
        for token in ["https://host:888/src/a_b.cpp:22", "example.org/a_b.cpp:888", "12:34", "3.14:5", "ratio:888",
                      "a_b.cpp:eight", "a_b.cpp:-8", "a_b.cpp:8:column", "a_b.cpp:8:12:34",
                      "https://host/src/file.c:100-200", "example.org/file.c:100-200", "100-200", "12:34-56",
                      "file.c:100-", "file.c:-200", "file.c:100--200", "file.c:100-200-300", "file.c:100-two",
                      "file.c:100-200:3", "file.c:100:2-200:3"] {
            check(NarrationPath.pronounce(token) == token, "non-file or malformed line references stay unchanged: \(token)")
        }
        let referenceSource = "🙂 Check a_b.cpp:888 before editing. Then inspect src/c_d.hpp:12."
        let referenceParts = try NarrationText.plan(NarrationInput(text: referenceSource, output: "stream"))
        check(referenceParts.map(\.text) == ["🙂 Check a underscore b dot C P P, line 888, before editing.", "Then inspect src slash c underscore d dot H P P, line 12."], "line references keep separate sentences")
        check(referenceParts.map { (referenceSource as NSString).substring(with: $0.sourceRange) } == ["🙂 Check a_b.cpp:888 before editing.", "Then inspect src/c_d.hpp:12."], "line reference expansion retains original UTF-16 offsets")
        let referenceOverride = try NarrationText.prepare(NarrationInput(text: "Check a_b.cpp:888.", pronunciations: ["a_b.cpp:888": "the failing line"], output: "stream"))
        check(referenceOverride == ["Check the failing line."], "custom line-reference pronunciation takes precedence")
        let rangeSource = "🙂 Check file.c:100-200 before editing. Then inspect src/a_b.cpp:300-400."
        let rangeParts = try NarrationText.plan(NarrationInput(text: rangeSource, output: "stream"))
        check(rangeParts.map(\.text) == ["🙂 Check file dot C, lines 100 to 200, before editing.", "Then inspect src slash a underscore b dot C P P, lines 300 to 400."], "line ranges keep separate sentences")
        check(rangeParts.map { (rangeSource as NSString).substring(with: $0.sourceRange) } == ["🙂 Check file.c:100-200 before editing.", "Then inspect src/a_b.cpp:300-400."], "line ranges retain original UTF-16 sentence offsets")
        let rangeOverride = try NarrationText.prepare(NarrationInput(text: "Check file.c:100-200.", pronunciations: ["file.c:100-200": "the affected lines"], output: "stream"))
        check(rangeOverride == ["Check the affected lines."], "custom line-range pronunciation takes precedence")
        for (name, spoken) in [
            ("type_name_t", "type underscore name underscore tee"),
            ("uint32_t", "uint32 underscore tee"),
            ("get_type_name()", "get underscore type underscore name()"),
            ("get_type_name(type_name_t)", "get underscore type underscore name(type underscore name underscore tee)"),
            ("ns::get_name_t()", "ns::get underscore name underscore tee()"),
            ("x_y_t", "ex underscore why underscore tee"),
            ("TYPE_NAME_T", "TYPE underscore NAME underscore tee"),
            ("_private_t", "underscore private underscore tee"),
            ("__init__", "underscore underscore init underscore underscore"),
            ("type__t", "type underscore underscore tee"),
            ("type_name_", "type underscore name underscore"),
            ("value_1", "value underscore 1"),
            ("naïve_type_t", "naïve underscore type underscore tee"),
            ("cafe\u{0301}_type_t", "cafe\u{0301} underscore type underscore tee"),
            ("constructor_t", "constructor underscore tee"),
            ("__proto__", "underscore underscore proto underscore underscore"),
            ("\"type_name_t\"", "\"type underscore name underscore tee\""),
            ("`type_name_t`; (get_name_t())", "`type underscore name underscore tee`; (get underscore name underscore tee())"),
            ("type_name_t*", "type underscore name underscore tee*"),
            ("type_name_t,other_type_t", "type underscore name underscore tee,other underscore type underscore tee")
        ] {
            let original = "Use \(name)."
            for output in ["playback", "pieces", "stream"] {
                let parts = try NarrationText.plan(NarrationInput(text: original, output: output))
                check(parts.map(\.text) == ["Use \(spoken)."], "identifier pronunciation: \(name), \(output)")
                check(parts.first?.sourceRange == NSRange(location: 0, length: original.utf16.count), "identifier source mapping: \(name)")
                check(try NarrationText.prepare(NarrationInput(text: "Use \(spoken).", output: output)) == ["Use \(spoken)."], "prepared identifiers stay unchanged: \(name)")
            }
        }
        let identifiers = try NarrationIdentifier()
        for text in ["A normal sentence about t and tea.", "1_000 1_name_t _123 ____",
                     "src/type_name_t.cpp:100-200", "type_name_t.cpp", "type_name_t.unknown", "./type_name_t",
                     "https://example.org/type_name_t?next=get_name_t", "www.example.org/type_name_t",
                     "example.org/type_name_t", "user_name@example.org", ".hidden_name", "pkg.type_name_t"] {
            check(identifiers.pronounce(text) == text, "identifier normalization preserves non-identifiers: \(text)")
        }
        let identifierSource = "🙂 Use type_name_t here. Then call get_type_name()."
        let identifierParts = try NarrationText.plan(NarrationInput(text: identifierSource, output: "stream"))
        check(identifierParts.map(\.text) == ["🙂 Use type underscore name underscore tee here.", "Then call get underscore type underscore name()."], "identifiers preserve sentence boundaries")
        check(identifierParts.map { (identifierSource as NSString).substring(with: $0.sourceRange) } == ["🙂 Use type_name_t here.", "Then call get_type_name()."], "identifier expansion retains original UTF-16 sentence offsets")
        let identifierOverride = try NarrationText.prepare(NarrationInput(text: identifierSource, pronunciations: ["type_name_t": "the type name", "get_type_name": "the lookup function"], output: "stream"))
        check(identifierOverride == ["🙂 Use the type name here.", "Then call the lookup function()."], "custom identifier pronunciation takes precedence")
        let mixedSource = "Check type_name_t in src/type_name_t.cpp:100-200."
        let mixedParts = try NarrationText.plan(NarrationInput(text: mixedSource, output: "stream"))
        check(mixedParts.map(\.text) == ["Check type underscore name underscore tee in src slash type underscore name underscore t dot C P P, lines 100 to 200."], "standalone identifiers coexist with paths and line ranges")
        check(mixedParts.first?.sourceRange == NSRange(location: 0, length: mixedSource.utf16.count), "mixed identifier/path source mapping")
        check((chunks.first?.count ?? 0) <= 160, "opening piece should start promptly")
    } catch { failures.append("narration: unexpected text preparation error \(error)") }
    let rate = 1000.0
    let signal = [Float](repeating: 0, count: 500) + [Float](repeating: 0.1, count: 200)
        + [Float](repeating: 0, count: 600) + [Float](repeating: 0.1, count: 200) + [Float](repeating: 0, count: 1000)
    check(NarrationAudio.speechRange(signal, rate: rate) == 460..<1580, "trim edges while preserving interior silence and speech padding")
    check(NarrationAudio.speechRange([Float](repeating: 0, count: 100), rate: rate) == nil, "silent output must be rejected")
        for invalid in [NarrationInput(text: " \n"), NarrationInput(text: String(repeating: "x", count: 100_001)),
                    NarrationInput(text: String(repeating: "type_t ", count: 12_000)),
                    NarrationInput(text: "test", pronunciations: ["": "empty"]),
                    NarrationInput(text: String(repeating: "a/b/c.cpp ", count: 9_999)),
                    NarrationInput(text: String(repeating: "x ", count: 49_999), pronunciations: ["x": String(repeating: "y", count: 256)])] {
        do { _ = try NarrationText.prepare(invalid); failures.append("narration: invalid text input accepted") }
        catch {}
    }
    return failures
}
