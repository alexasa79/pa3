import Foundation

struct NarrationPiece: Sendable {
    let text: String
    let sourceRange: NSRange
    var pauseAfter: Double
}

enum NarrationText {
    struct Invalid: Error { let message: String; init(_ message: String) { self.message = message } }

    // Keep original UTF-16 positions through pronunciation, path, and list-label substitutions.
    // Highlighting must address the source document, not the normalized spoken text.
    private struct MappedText {
        var text: String
        var origins: [NSRange]
        init(_ text: String, offset: Int) {
            self.text = text
            origins = (0..<text.utf16.count).map { NSRange(location: offset + $0, length: 1) }
        }
        func sourceRange(_ range: NSRange) -> NSRange {
            let covered = origins[range.location..<NSMaxRange(range)]
            let lower = covered.map(\.location).min() ?? 0
            let upper = covered.map(NSMaxRange).max() ?? lower
            return NSRange(location: lower, length: upper - lower)
        }
        func slice(_ range: NSRange) -> MappedText {
            var result = self
            result.text = (text as NSString).substring(with: range)
            result.origins = Array(origins[range.location..<NSMaxRange(range)])
            return result
        }
        mutating func replace(_ regex: NSRegularExpression, with replacement: (NSTextCheckingResult, NSString) -> String) throws {
            let source = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
            var result = "", mapping: [NSRange] = [], cursor = 0
            for match in matches {
                result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                mapping.append(contentsOf: origins[cursor..<match.range.location])
                let value = replacement(match, source)
                result += value
                if value == source.substring(with: match.range) {
                    mapping.append(contentsOf: origins[match.range.location..<NSMaxRange(match.range)])
                } else {
                    mapping.append(contentsOf: repeatElement(sourceRange(match.range), count: value.utf16.count))
                }
                guard mapping.count <= 400_000 else { throw Invalid("Expanded pronunciation text is too large") }
                cursor = NSMaxRange(match.range)
            }
            result += source.substring(from: cursor)
            mapping.append(contentsOf: origins[cursor...])
            text = result
            origins = mapping
        }
    }

    private struct Block {
        var range: NSRange
        let isList: Bool
        let blankBefore: Bool
        var needsBody: Bool
        var lastLine: String
    }

    private static func hasSentenceEnding(_ text: String) -> Bool {
        var ending = text[...]
        while let last = ending.last, last.isWhitespace || "\"'”’»›)]}*_".contains(last) { ending.removeLast() }
        // A wrapped two-dot range continues on the next line; an ellipsis can end a sentence.
        if ending.hasSuffix(".."), !ending.hasSuffix("...") { return false }
        return ending.last.map { ".!?。！？".contains($0) } == true
    }

    // Streaming budgets are targets: never cut a phrase just to meet a character count.
    private static func clauseCut(_ text: String, start: String.Index, end: String.Index,
                                  target: String.Index, minimum: Int) -> String.Index {
        var before: String.Index?
        var index = start
        while index < end {
            let punctuation = text[index]
            if ",;:，；：、—".contains(punctuation) {
                var cut = text.index(after: index)
                while cut < end, "\"'”’)]}".contains(text[cut]) { cut = text.index(after: cut) }
                // Avoid punctuation inside numbers, URLs, and identifiers.
                if cut == end || text[cut].isWhitespace || "，；：、—".contains(punctuation) {
                    if cut >= target { return before ?? cut }
                    if text.distance(from: start, to: cut) >= minimum { before = cut }
                }
            }
            index = text.index(after: index)
        }
        return before ?? end
    }

    static func prepare(_ input: NarrationInput) throws -> [String] { try plan(input).map(\.text) }

    static func plan(_ input: NarrationInput) throws -> [NarrationPiece] {
        let original = input.text
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Invalid("Text is empty") }
        guard original.count <= 100_000 else { throw Invalid("Text exceeds 100,000 characters") }
        let aliases = input.pronunciations ?? [:]
        guard aliases.count <= 100, aliases.allSatisfy({ !$0.key.isEmpty && !$0.value.isEmpty && $0.key.count <= 128 && $0.value.count <= 256 }) else {
            throw Invalid("Use at most 100 nonempty pronunciation entries, with keys up to 128 and values up to 256 characters")
        }
        let keys = aliases.keys.sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
        let aliasRegex = keys.isEmpty ? nil : try NSRegularExpression(pattern:
            "(?<![\\p{L}\\p{N}_])(?:" + keys.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")(?![\\p{L}\\p{N}_])")
        let marker = try NSRegularExpression(pattern: #"^[ \t]*(?:(\d+)[.)]|[-*+•◦▪‣●○■□⁃–—])(?:[ \t]+|$)"#)
        let newlines = try NSRegularExpression(pattern: #"[\r\n\x{2028}\x{2029}]+[ \t]*"#)
        let rangeOperator = try NSRegularExpression(pattern: #"(?<=[\p{L}\p{N}_)\]}])[ \t]*\.\.[ \t]*(?=[+\-−]?[\p{L}\p{N}_(\[{])"#)
        let pathToken = try NarrationPath.tokenRegex()
        var blocks: [Block] = [], current: Block?, blankBefore = false
        let source = original as NSString
        // Treat CRLF as one terminator; keep empty lines and AX paragraph separators.
        let lineRegex = try NSRegularExpression(pattern: #"[^\r\n\x{2028}\x{2029}]*(?:\r\n|[\r\n\x{2028}\x{2029}]|$)"#)
        for lineMatch in lineRegex.matches(in: original, range: NSRange(location: 0, length: source.length)) where lineMatch.range.length > 0 {
            let raw = source.substring(with: lineMatch.range)
            let line = raw.trimmingCharacters(in: .newlines)
            let range = NSRange(location: lineMatch.range.location, length: line.utf16.count)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if let block = current { blocks.append(block); current = nil }
                blankBefore = true
                continue
            }
            let match = marker.firstMatch(in: line, range: NSRange(location: 0, length: range.length))
            let isList = match != nil
            let indented = line.first?.isWhitespace == true
            // Indented lines and unfinished sentences continue the item. An unindented
            // sentence after a finished item returns to prose, even without a blank line.
            let finishedLine = current.map { hasSentenceEnding($0.lastLine) } ?? false
            let newProseAfterList = current?.isList == true && trimmed.first?.isUppercase == true
            let startsParagraph = !isList && !indented && current?.needsBody == false && (finishedLine || newProseAfterList)
            if isList || startsParagraph {
                if let block = current { blocks.append(block); current = nil }
            }
            if current == nil {
                current = Block(range: range, isList: isList, blankBefore: blankBefore,
                                needsBody: match.map { NSMaxRange($0.range) == range.length } ?? false, lastLine: trimmed)
                blankBefore = false
            } else {
                let start = current!.range.location
                current?.range.length = NSMaxRange(range) - start
                current?.needsBody = false
                current?.lastLine = trimmed
            }
            if raw.hasSuffix("\u{2029}"), let block = current {
                blocks.append(block); current = nil; blankBefore = true
            }
        }
        if let current { blocks.append(current) }
        var pieces: [NarrationPiece] = []
        var expandedCount = 0
        for (blockIndex, block) in blocks.enumerated() {
            var mapped = MappedText(source.substring(with: block.range), offset: block.range.location)
            try mapped.replace(newlines) { _, _ in " " }
            if block.isList {
                try mapped.replace(marker) { match, value in
                    match.range(at: 1).location != NSNotFound ? value.substring(with: match.range(at: 1)) + ", " : ""
                }
            }
            if let aliasRegex { try mapped.replace(aliasRegex) { match, value in aliases[value.substring(with: match.range)]! } }
            expandedCount += mapped.text.count
            guard expandedCount <= 200_000 else { throw Invalid("Expanded pronunciation text is too large") }
            let boundaryText = mapped.text
            let firstPiece = pieces.count
            // Foundation can split A..B after the dots. Protect range operators only
            // in the segmentation copy, preserving UTF-16 offsets and spoken text.
            let protected = NSMutableString(string: boundaryText)
            for match in rangeOperator.matches(in: boundaryText, range: NSRange(location: 0, length: protected.length)).reversed() {
                protected.replaceCharacters(in: match.range, with: String(repeating: "x", count: match.range.length))
            }
            let segmentationText = protected as String
            var sentenceRanges: [NSRange] = []
            segmentationText.enumerateSubstrings(in: segmentationText.startIndex..<segmentationText.endIndex, options: [.bySentences, .localized]) { _, range, _, _ in
                sentenceRanges.append(NSRange(range, in: segmentationText))
            }
            for range in sentenceRanges {
                guard Range(range, in: boundaryText) != nil else { throw Invalid("Invalid sentence range") }
                var sentence = mapped.slice(range)
                let originalCount = sentence.text.count
                // Detect boundaries before spelling extensions: "C P P." can look
                // like someone's initials to Foundation and swallow the next sentence.
                try sentence.replace(pathToken) { match, value in NarrationPath.pronounce(value.substring(with: match.range)) }
                expandedCount += sentence.text.count - originalCount
                guard expandedCount <= 200_000 else { throw Invalid("Expanded pronunciation text is too large") }
                let text = sentence.text
                var start = text.startIndex
                let end = text.endIndex
                while start < end {
                    while start < end, text[start].isWhitespace { start = text.index(after: start) }
                    guard start < end else { break }
                    let streaming = input.output == "pieces"
                    let budget = streaming ? (pieces.isEmpty ? 64 : 96) : (pieces.isEmpty ? 160 : 300)
                    let limit = input.output == "stream" ? end : (text.index(start, offsetBy: budget, limitedBy: end) ?? end)
                    var cut = limit
                    if limit < end {
                        if streaming {
                            cut = clauseCut(text, start: start, end: end, target: limit, minimum: budget / 2)
                            // Keep a short sentence ending with its preceding clause.
                            if text[cut..<end].trimmingCharacters(in: .whitespacesAndNewlines).count <= 40 {
                                cut = end
                            }
                        } else {
                            let clause = text[start..<limit].lastIndex(where: { ",;:".contains($0) })
                            if let clause, text.distance(from: start, to: clause) >= 60 { cut = text.index(after: clause) }
                            else if let space = text[start..<limit].lastIndex(where: { $0.isWhitespace }), space > start { cut = space }
                        }
                    }
                    var spokenEnd = cut
                    while spokenEnd > start, text[text.index(before: spokenEnd)].isWhitespace { spokenEnd = text.index(before: spokenEnd) }
                    let spoken = String(text[start..<spokenEnd])
                    if !spoken.isEmpty {
                        pieces.append(NarrationPiece(text: spoken, sourceRange: sentence.sourceRange(NSRange(start..<spokenEnd, in: text)),
                                                     pauseAfter: hasSentenceEnding(spoken) ? 0.20 : 0.12))
                    }
                    start = cut
                }
            }
            if pieces.count > firstPiece, blockIndex + 1 < blocks.count {
                let next = blocks[blockIndex + 1]
                pieces[pieces.count - 1].pauseAfter = block.isList && next.isList && !next.blankBefore ? 0.40 : 0.65
            }
        }
        guard !pieces.isEmpty else { throw Invalid("No speakable text") }
        return pieces
    }
}
