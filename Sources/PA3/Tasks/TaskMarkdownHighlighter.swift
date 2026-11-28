import AppKit
import Foundation

enum MarkdownTokenKind: Equatable, Sendable {
    case codeFence
    case codeBlock
    case codeSyntax(CodeTokenKind)
    case heading(Int)
    case horizontalRule
    case blockquote
    case listMarker
    case tableBorder
    case bold
    case italic
    case boldItalic
    case strikethrough
    case inlineCode
    case linkText
    case linkURL
    case image
    case syntaxDelimiter
    case taskTag(TaskMetadata.TagKind)
}

struct MarkdownToken: Equatable, Sendable {
    let range: NSRange
    let kind: MarkdownTokenKind
}

/// Pure Markdown and task-tag syntax highlighter.
/// Presentation only: never mutates document text or undo history.
enum TaskMarkdownHighlighter {
    private struct Line {
        let start: Int
        let end: Int // excludes trailing \r / \n
    }

    private struct FenceState {
        let char: UInt16
        let length: Int
        let language: CodeLanguage?
        let openLineIndex: Int
    }

    private struct FencedBlock {
        let startLine: Int
        let endLine: Int // inclusive content line index
        let language: CodeLanguage
    }

    static func tokens(in text: String, highlightTaskTags: Bool = true) -> [MarkdownToken] {
        analyze(in: text, highlightTaskTags: highlightTaskTags).tokens
    }

    private static func analyze(in text: String, highlightTaskTags: Bool) -> (tokens: [MarkdownToken], highlightedCodeRanges: [NSRange]) {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return ([], []) }

        let lines = splitLines(units)
        var tokens: [MarkdownToken] = []
        var protectedForTags: [NSRange] = []

        // First pass: detect fenced code blocks (with language) and table separator rows.
        var inCodeBlock = Array(repeating: false, count: lines.count)
        var isCodeFenceLine = Array(repeating: false, count: lines.count)
        var isTableSeparator = Array(repeating: false, count: lines.count)
        var highlightedBlocks: [FencedBlock] = []
        var fence: FenceState?

        for (index, line) in lines.enumerated() {
            if let active = fence {
                if isClosingFence(units, line: line, fence: active) {
                    isCodeFenceLine[index] = true
                    if let language = active.language, active.openLineIndex + 1 <= index - 1 {
                        highlightedBlocks.append(FencedBlock(
                            startLine: active.openLineIndex + 1,
                            endLine: index - 1,
                            language: language
                        ))
                    }
                    fence = nil
                } else {
                    inCodeBlock[index] = true
                }
            } else if let opened = openingFence(units, line: line, lineIndex: index) {
                isCodeFenceLine[index] = true
                fence = opened
            } else if isTableSeparatorLine(units, line: line) {
                isTableSeparator[index] = true
            }
        }
        if let active = fence, let language = active.language, active.openLineIndex + 1 <= lines.count - 1 {
            highlightedBlocks.append(FencedBlock(
                startLine: active.openLineIndex + 1,
                endLine: lines.count - 1,
                language: language
            ))
        }

        // Pre-pass: detect multi-line links and multi-line emphasis within contiguous prose paragraphs.
        var isProseLine = Array(repeating: false, count: lines.count)
        var isEmphasisContinuationLine = Array(repeating: false, count: lines.count)
        for (index, line) in lines.enumerated() {
            if !isCodeFenceLine[index], !inCodeBlock[index], !isTableSeparator[index],
               line.start < line.end,
               matchHeading(units, line: line) == nil,
               !isHorizontalRule(units, line: line) {
                isProseLine[index] = true
                if matchBlockquote(units, line: line) == nil,
                   matchListMarker(units, start: line.start, end: line.end) == nil,
                   !isTableContentLine(units, line: line, adjacentToSeparator: false) {
                    isEmphasisContinuationLine[index] = true
                }
            }
        }
        let multiLineLinkRanges = scanMultiLineLinks(
            units, lines: lines, isProseLine: isProseLine,
            tokens: &tokens, protectedForTags: &protectedForTags
        )
        let multiLineEmphasisRanges = scanMultiLineEmphasis(
            units, lines: lines,
            isProseLine: isProseLine,
            isContinuationLine: isEmphasisContinuationLine,
            multiLineLinkRanges: multiLineLinkRanges,
            tokens: &tokens
        )

        // Second pass: emit block and inline tokens.
        for (index, line) in lines.enumerated() {
            let lineRange = NSRange(location: line.start, length: line.end - line.start)
            if isCodeFenceLine[index] {
                if lineRange.length > 0 {
                    tokens.append(MarkdownToken(range: lineRange, kind: .codeFence))
                    protectedForTags.append(lineRange)
                }
                continue
            }
            if inCodeBlock[index] {
                if lineRange.length > 0 {
                    tokens.append(MarkdownToken(range: lineRange, kind: .codeBlock))
                    protectedForTags.append(lineRange)
                }
                continue
            }
            guard line.start < line.end else { continue }

            if isTableSeparator[index] {
                let trimmed = trimmedRange(units, start: line.start, end: line.end)
                if trimmed.length > 0 {
                    tokens.append(MarkdownToken(range: trimmed, kind: .tableBorder))
                }
                continue
            }

            if let heading = matchHeading(units, line: line) {
                tokens.append(MarkdownToken(range: lineRange, kind: .heading(heading.level)))
                if heading.contentStart < line.end {
                    scanInline(units, start: heading.contentStart, end: line.end,
                               preProtected: [], tokens: &tokens, protectedForTags: &protectedForTags)
                }
                continue
            }

            if isHorizontalRule(units, line: line) {
                tokens.append(MarkdownToken(range: lineRange, kind: .horizontalRule))
                continue
            }

            let linePreProtected = multiLineLinkRanges.compactMap { range -> NSRange? in
                let hit = NSIntersectionRange(range, lineRange)
                return hit.length > 0 ? hit : nil
            }
            let lineEmphasisProtected = multiLineEmphasisRanges.compactMap { range -> NSRange? in
                let hit = NSIntersectionRange(range, lineRange)
                return hit.length > 0 ? hit : nil
            }

            if let quoteContentStart = matchBlockquote(units, line: line) {
                tokens.append(MarkdownToken(range: lineRange, kind: .blockquote))
                if quoteContentStart < line.end {
                    var contentStart = quoteContentStart
                    if let list = matchListMarker(units, start: contentStart, end: line.end) {
                        tokens.append(MarkdownToken(range: list.markerRange, kind: .listMarker))
                        if let checkbox = list.checkboxRange {
                            tokens.append(MarkdownToken(range: checkbox, kind: .listMarker))
                        }
                        contentStart = list.contentStart
                    }
                    if contentStart < line.end {
                        scanInline(units, start: contentStart, end: line.end,
                                   preProtected: linePreProtected, emphasisProtected: lineEmphasisProtected,
                                   tokens: &tokens, protectedForTags: &protectedForTags)
                    }
                }
                continue
            }

            let adjacentSeparator = (index > 0 && isTableSeparator[index - 1])
                || (index + 1 < lines.count && isTableSeparator[index + 1])
            if isTableContentLine(units, line: line, adjacentToSeparator: adjacentSeparator) {
                let protected = scanInline(units, start: line.start, end: line.end,
                                           preProtected: linePreProtected, emphasisProtected: lineEmphasisProtected,
                                           tokens: &tokens, protectedForTags: &protectedForTags)
                emitTableBorders(units, start: line.start, end: line.end, protected: protected, tokens: &tokens)
                continue
            }

            var contentStart = line.start
            if let list = matchListMarker(units, start: line.start, end: line.end) {
                tokens.append(MarkdownToken(range: list.markerRange, kind: .listMarker))
                if let checkbox = list.checkboxRange {
                    tokens.append(MarkdownToken(range: checkbox, kind: .listMarker))
                }
                contentStart = list.contentStart
            }
            if contentStart < line.end {
                scanInline(units, start: contentStart, end: line.end,
                           preProtected: linePreProtected, emphasisProtected: lineEmphasisProtected,
                           tokens: &tokens, protectedForTags: &protectedForTags)
            }
        }

        // Tokenize syntax inside language-labeled fenced code blocks.
        var highlightedCodeRanges: [NSRange] = []
        for block in highlightedBlocks {
            let blockStart = lines[block.startLine].start
            let blockEnd = lines[block.endLine].end
            guard blockStart < blockEnd else { continue }
            let blockRange = NSRange(location: blockStart, length: blockEnd - blockStart)
            highlightedCodeRanges.append(blockRange)
            for codeToken in TaskCodeHighlighter.tokenize(units, range: blockRange, language: block.language) {
                tokens.append(MarkdownToken(range: codeToken.range, kind: .codeSyntax(codeToken.kind)))
            }
        }

        if highlightTaskTags {
            for match in TaskMetadata.validTagMatches(in: text) {
                if !protectedForTags.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                    tokens.append(MarkdownToken(range: match.range, kind: .taskTag(match.kind)))
                }
            }
        }

        return (tokens, highlightedCodeRanges)
    }

    @MainActor
    static func apply(to textView: NSTextView, textGrid: TaskTextGrid, highlightTaskTags: Bool) {
        guard let storage = textView.textStorage else { return }
        let text = textView.string
        let source = text as NSString
        let full = NSRange(location: 0, length: source.length)
        let newline = source.rangeOfCharacter(from: .newlines)
        let subjectLength = newline.location == NSNotFound ? source.length : newline.location

        let regular = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 16, weight: .bold)
        let obliqueness: CGFloat = 0.16

        textGrid.update(body: text)
        let paragraph = textGrid.paragraphStyle
        textView.layoutManager?.delegate = textGrid
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 0, height: textGrid.rowHeight)
        textView.defaultParagraphStyle = paragraph

        let analysis = analyze(in: text, highlightTaskTags: highlightTaskTags)
        let tokens = analysis.tokens
        let highlightedCodeRanges = analysis.highlightedCodeRanges

        let history = textView.undoManager
        let registering = history?.isUndoRegistrationEnabled == true
        if registering { history?.disableUndoRegistration() }

        storage.beginEditing()
        if full.length > 0 {
            storage.removeAttribute(.backgroundColor, range: full)
            storage.removeAttribute(.underlineStyle, range: full)
            storage.removeAttribute(.strikethroughStyle, range: full)
            storage.removeAttribute(.obliqueness, range: full)
            storage.addAttributes([
                .font: regular,
                .foregroundColor: PaperTheme.ink,
                .paragraphStyle: paragraph
            ], range: full)
            if subjectLength > 0 {
                storage.addAttribute(.font, value: bold, range: NSRange(location: 0, length: subjectLength))
            }

            // Layer 1: block and structural tokens.
            for token in tokens {
                switch token.kind {
                case .codeFence:
                    storage.addAttributes([
                        .font: regular,
                        .foregroundColor: PaperTheme.Syntax.delimiter,
                        .backgroundColor: PaperTheme.Syntax.codeBackground
                    ], range: token.range)
                case .codeBlock:
                    let hasLanguage = highlightedCodeRanges.contains { NSIntersectionRange($0, token.range).length > 0 }
                    storage.addAttributes([
                        .font: regular,
                        .foregroundColor: hasLanguage ? PaperTheme.ink : PaperTheme.Syntax.code,
                        .backgroundColor: PaperTheme.Syntax.codeBackground
                    ], range: token.range)
                case .heading(let level):
                    storage.addAttributes([
                        .font: bold,
                        .foregroundColor: headingColor(for: level)
                    ], range: token.range)
                case .horizontalRule:
                    storage.addAttribute(.foregroundColor, value: PaperTheme.muted, range: token.range)
                case .blockquote:
                    storage.addAttributes([
                        .foregroundColor: PaperTheme.Syntax.blockquote,
                        .obliqueness: obliqueness
                    ], range: token.range)
                case .listMarker:
                    storage.addAttributes([
                        .font: bold,
                        .foregroundColor: PaperTheme.Syntax.listMarker
                    ], range: token.range)
                case .tableBorder:
                    storage.addAttribute(.foregroundColor, value: PaperTheme.muted, range: token.range)
                default:
                    break
                }
            }

            // Layer 2: inline emphasis and strikethrough.
            for token in tokens {
                switch token.kind {
                case .bold:
                    storage.addAttribute(.font, value: bold, range: token.range)
                case .italic:
                    storage.addAttribute(.obliqueness, value: obliqueness, range: token.range)
                case .boldItalic:
                    storage.addAttributes([
                        .font: bold,
                        .obliqueness: obliqueness
                    ], range: token.range)
                case .strikethrough:
                    storage.addAttributes([
                        .foregroundColor: PaperTheme.muted,
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue
                    ], range: token.range)
                default:
                    break
                }
            }

            // Layer 3: inline code, fenced code syntax, links, images, and syntax delimiters.
            for token in tokens {
                switch token.kind {
                case .codeSyntax(let codeKind):
                    var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: codeColor(for: codeKind)]
                    if codeKind == .comment {
                        attrs[.obliqueness] = obliqueness
                    } else if codeKind == .keyword {
                        attrs[.font] = bold
                    }
                    storage.addAttributes(attrs, range: token.range)
                case .inlineCode:
                    storage.removeAttribute(.obliqueness, range: token.range)
                    storage.addAttributes([
                        .foregroundColor: PaperTheme.Syntax.code,
                        .backgroundColor: PaperTheme.Syntax.codeBackground
                    ], range: token.range)
                case .linkText:
                    storage.addAttributes([
                        .foregroundColor: PaperTheme.Syntax.linkText,
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ], range: token.range)
                case .image:
                    storage.addAttribute(.foregroundColor, value: PaperTheme.Syntax.image, range: token.range)
                case .linkURL:
                    storage.addAttribute(.foregroundColor, value: PaperTheme.Syntax.linkURL, range: token.range)
                case .syntaxDelimiter:
                    storage.addAttribute(.foregroundColor, value: PaperTheme.Syntax.delimiter, range: token.range)
                default:
                    break
                }
            }

            // Layer 4: subtle task tags.
            for token in tokens {
                if case .taskTag(let tagKind) = token.kind {
                    storage.removeAttribute(.obliqueness, range: token.range)
                    storage.addAttributes([
                        .foregroundColor: tagColor(for: tagKind),
                        .backgroundColor: PaperTheme.Syntax.tagBackground
                    ], range: token.range)
                }
            }
        }
        storage.endEditing()

        if registering { history?.enableUndoRegistration() }

        let typingFont = textView.selectedRange().location <= subjectLength ? bold : regular
        textView.typingAttributes = [
            .font: typingFont,
            .foregroundColor: PaperTheme.ink,
            .paragraphStyle: paragraph
        ]
        textView.needsDisplay = true
    }

    private static func headingColor(for level: Int) -> NSColor {
        switch level {
        case 1: return PaperTheme.Syntax.heading1
        case 2: return PaperTheme.Syntax.heading2
        case 3: return PaperTheme.Syntax.heading3
        case 4: return PaperTheme.Syntax.heading4
        case 5: return PaperTheme.Syntax.heading5
        default: return PaperTheme.Syntax.heading6
        }
    }

    private static func tagColor(for kind: TaskMetadata.TagKind) -> NSColor {
        switch kind {
        case .due: return PaperTheme.Syntax.tagDue
        case .priority: return PaperTheme.Syntax.tagPriority
        case .done: return PaperTheme.Syntax.tagDone
        case .open: return PaperTheme.Syntax.tagOpen
        }
    }

    private static func codeColor(for kind: CodeTokenKind) -> NSColor {
        switch kind {
        case .keyword: return PaperTheme.Syntax.codeKeyword
        case .type: return PaperTheme.Syntax.codeType
        case .string: return PaperTheme.Syntax.codeString
        case .number: return PaperTheme.Syntax.codeNumber
        case .comment: return PaperTheme.Syntax.codeComment
        case .function: return PaperTheme.Syntax.codeFunction
        case .variable: return PaperTheme.Syntax.codeVariable
        case .constant: return PaperTheme.Syntax.codeConstant
        case .preprocessor: return PaperTheme.Syntax.codePreprocessor
        }
    }

    // MARK: - Line Splitting & Block Matchers

    private static let asciiSpace: UInt16 = 0x20
    private static let asciiTab: UInt16 = 0x09
    private static let asciiLF: UInt16 = 0x0A
    private static let asciiCR: UInt16 = 0x0D
    private static let asciiBacktick: UInt16 = 0x60
    private static let asciiTilde: UInt16 = 0x7E
    private static let asciiHash: UInt16 = 0x23
    private static let asciiDash: UInt16 = 0x2D
    private static let asciiStar: UInt16 = 0x2A
    private static let asciiUnderscore: UInt16 = 0x5F
    private static let asciiPlus: UInt16 = 0x2B
    private static let asciiDot: UInt16 = 0x2E
    private static let asciiGT: UInt16 = 0x3E
    private static let asciiPipe: UInt16 = 0x7C
    private static let asciiColon: UInt16 = 0x3A
    private static let asciiBackslash: UInt16 = 0x5C
    private static let asciiBang: UInt16 = 0x21
    private static let asciiLBracket: UInt16 = 0x5B
    private static let asciiRBracket: UInt16 = 0x5D
    private static let asciiLParen: UInt16 = 0x28
    private static let asciiRParen: UInt16 = 0x29

    private static func splitLines(_ units: [UInt16]) -> [Line] {
        var lines: [Line] = []
        var start = 0
        var i = 0
        while i < units.count {
            if units[i] == asciiLF {
                let end = (i > start && units[i - 1] == asciiCR) ? i - 1 : i
                lines.append(Line(start: start, end: end))
                start = i + 1
            }
            i += 1
        }
        if start <= units.count {
            let end = (units.count > start && units[units.count - 1] == asciiCR) ? units.count - 1 : units.count
            lines.append(Line(start: start, end: end))
        }
        return lines
    }

    private static func skipUpToThreeSpaces(_ units: [UInt16], from start: Int, end: Int) -> Int {
        var i = start
        let limit = min(end, start + 3)
        while i < limit && units[i] == asciiSpace { i += 1 }
        return i
    }

    private static func openingFence(_ units: [UInt16], line: Line, lineIndex: Int) -> FenceState? {
        let i = skipUpToThreeSpaces(units, from: line.start, end: line.end)
        guard i < line.end else { return nil }
        let ch = units[i]
        guard ch == asciiBacktick || ch == asciiTilde else { return nil }
        var j = i
        while j < line.end && units[j] == ch { j += 1 }
        let count = j - i
        guard count >= 3 else { return nil }
        if ch == asciiBacktick {
            for k in j..<line.end where units[k] == asciiBacktick {
                return nil
            }
        }
        let info = j < line.end ? String(utf16CodeUnits: Array(units[j..<line.end]), count: line.end - j) : ""
        let language = CodeLanguage.forFenceLabel(info)
        return FenceState(char: ch, length: count, language: language, openLineIndex: lineIndex)
    }

    private static func isClosingFence(_ units: [UInt16], line: Line, fence: FenceState) -> Bool {
        let i = skipUpToThreeSpaces(units, from: line.start, end: line.end)
        var j = i
        while j < line.end && units[j] == fence.char { j += 1 }
        guard j - i >= fence.length else { return false }
        while j < line.end {
            if units[j] != asciiSpace && units[j] != asciiTab { return false }
            j += 1
        }
        return true
    }

    private static func matchHeading(_ units: [UInt16], line: Line) -> (level: Int, contentStart: Int)? {
        let i = skipUpToThreeSpaces(units, from: line.start, end: line.end)
        var j = i
        while j < line.end && units[j] == asciiHash { j += 1 }
        let level = j - i
        guard level >= 1 && level <= 6 else { return nil }
        if j < line.end && units[j] != asciiSpace && units[j] != asciiTab { return nil }
        while j < line.end && (units[j] == asciiSpace || units[j] == asciiTab) { j += 1 }
        return (level, j)
    }

    private static func isHorizontalRule(_ units: [UInt16], line: Line) -> Bool {
        let i = skipUpToThreeSpaces(units, from: line.start, end: line.end)
        guard i < line.end else { return false }
        let marker = units[i]
        guard marker == asciiDash || marker == asciiStar || marker == asciiUnderscore else { return false }
        var count = 0
        for j in i..<line.end {
            let u = units[j]
            if u == marker { count += 1 }
            else if u != asciiSpace && u != asciiTab { return false }
        }
        return count >= 3
    }

    private static func matchBlockquote(_ units: [UInt16], line: Line) -> Int? {
        var i = skipUpToThreeSpaces(units, from: line.start, end: line.end)
        guard i < line.end, units[i] == asciiGT else { return nil }
        while i < line.end && units[i] == asciiGT {
            i += 1
            if i < line.end && (units[i] == asciiSpace || units[i] == asciiTab) { i += 1 }
            let next = skipUpToThreeSpaces(units, from: i, end: line.end)
            if next < line.end && units[next] == asciiGT { i = next } else { break }
        }
        return i
    }

    private struct ListMatch {
        let markerRange: NSRange
        let checkboxRange: NSRange?
        let contentStart: Int
    }

    private static func matchListMarker(_ units: [UInt16], start: Int, end: Int) -> ListMatch? {
        var i = start
        while i < end && (units[i] == asciiSpace || units[i] == asciiTab) { i += 1 }
        guard i < end else { return nil }

        let markerStart = i
        var markerEnd = i

        if units[i] == asciiDash || units[i] == asciiStar || units[i] == asciiPlus {
            markerEnd = i + 1
        } else if units[i] >= 0x30 && units[i] <= 0x39 {
            var j = i
            while j < end && units[j] >= 0x30 && units[j] <= 0x39 && j - i < 9 { j += 1 }
            guard j < end && (units[j] == asciiDot || units[j] == asciiRParen) else { return nil }
            markerEnd = j + 1
        } else {
            return nil
        }

        guard markerEnd < end && (units[markerEnd] == asciiSpace || units[markerEnd] == asciiTab) else { return nil }
        var contentStart = markerEnd + 1
        while contentStart < end && (units[contentStart] == asciiSpace || units[contentStart] == asciiTab) {
            contentStart += 1
        }

        var checkboxRange: NSRange?
        if contentStart + 2 < end,
           units[contentStart] == asciiLBracket,
           units[contentStart + 2] == asciiRBracket,
           (units[contentStart + 1] == asciiSpace || units[contentStart + 1] == 0x78 || units[contentStart + 1] == 0x58) {
            let afterBox = contentStart + 3
            if afterBox == end || units[afterBox] == asciiSpace || units[afterBox] == asciiTab {
                checkboxRange = NSRange(location: contentStart, length: 3)
                contentStart = afterBox
                while contentStart < end && (units[contentStart] == asciiSpace || units[contentStart] == asciiTab) {
                    contentStart += 1
                }
            }
        }

        return ListMatch(
            markerRange: NSRange(location: markerStart, length: markerEnd - markerStart),
            checkboxRange: checkboxRange,
            contentStart: contentStart
        )
    }

    private static func isTableSeparatorLine(_ units: [UInt16], line: Line) -> Bool {
        var hasPipe = false
        var hasDash = false
        for i in line.start..<line.end {
            let u = units[i]
            if u == asciiPipe { hasPipe = true }
            else if u == asciiDash { hasDash = true }
            else if u != asciiColon && u != asciiSpace && u != asciiTab { return false }
        }
        return hasPipe && hasDash
    }

    private static func isTableContentLine(_ units: [UInt16], line: Line, adjacentToSeparator: Bool) -> Bool {
        var pipeCount = 0
        var i = line.start
        while i < line.end {
            if units[i] == asciiBackslash && i + 1 < line.end { i += 2; continue }
            if units[i] == asciiPipe { pipeCount += 1 }
            i += 1
        }
        return pipeCount >= 2 || (pipeCount >= 1 && adjacentToSeparator)
    }

    private static func emitTableBorders(_ units: [UInt16], start: Int, end: Int,
                                         protected: [NSRange], tokens: inout [MarkdownToken]) {
        var i = start
        while i < end {
            if units[i] == asciiBackslash && i + 1 < end { i += 2; continue }
            if units[i] == asciiPipe,
               !protected.contains(where: { i >= $0.location && i < NSMaxRange($0) }) {
                tokens.append(MarkdownToken(range: NSRange(location: i, length: 1), kind: .tableBorder))
            }
            i += 1
        }
    }

    private static func trimmedRange(_ units: [UInt16], start: Int, end: Int) -> NSRange {
        var lo = start
        var hi = end
        while lo < hi && (units[lo] == asciiSpace || units[lo] == asciiTab) { lo += 1 }
        while hi > lo && (units[hi - 1] == asciiSpace || units[hi - 1] == asciiTab) { hi -= 1 }
        return NSRange(location: lo, length: hi - lo)
    }

    // MARK: - Inline Scanner

    private static func scanMultiLineLinks(_ units: [UInt16], lines: [Line], isProseLine: [Bool],
                                           tokens: inout [MarkdownToken],
                                           protectedForTags: inout [NSRange]) -> [NSRange] {
        var ranges: [NSRange] = []
        var lineIndex = 0
        while lineIndex < lines.count {
            guard isProseLine[lineIndex] else { lineIndex += 1; continue }
            var paraLast = lineIndex
            while paraLast + 1 < lines.count && isProseLine[paraLast + 1] { paraLast += 1 }
            if paraLast > lineIndex {
                let paraStart = lines[lineIndex].start
                let paraEnd = lines[paraLast].end
                var i = paraStart
                while i < paraEnd {
                    let u = units[i]
                    if u == asciiBackslash, i + 1 < paraEnd, isASCIIPunctuation(units[i + 1]) {
                        i += 2
                        continue
                    }
                    if u == asciiBacktick {
                        var runEnd = i
                        while runEnd < paraEnd && units[runEnd] == asciiBacktick { runEnd += 1 }
                        let runLen = runEnd - i
                        if let close = findClosingBackticks(units, from: runEnd, end: paraEnd, length: runLen) {
                            i = close + runLen
                            continue
                        }
                        i = runEnd
                        continue
                    }
                    let isImage = u == asciiBang && i + 1 < paraEnd && units[i + 1] == asciiLBracket
                    let openBracket = isImage ? i + 1 : i
                    if isImage || u == asciiLBracket,
                       let link = matchMarkdownLink(units, openBracket: openBracket, end: paraEnd, allowNewlinesInLabel: true) {
                        var spansNewline = false
                        for k in link.labelStart..<link.labelEnd where units[k] == asciiLF {
                            spansNewline = true
                            break
                        }
                        if spansNewline {
                            let full = NSRange(location: i, length: link.end - i)
                            tokens.append(MarkdownToken(range: NSRange(location: i, length: isImage ? 2 : 1), kind: .syntaxDelimiter))
                            emitLinkLabelSegments(units, start: link.labelStart, end: link.labelEnd,
                                                  kind: isImage ? .image : .linkText, tokens: &tokens)
                            tokens.append(MarkdownToken(range: NSRange(location: link.labelEnd, length: 2), kind: .syntaxDelimiter))
                            if link.urlEnd > link.urlStart {
                                let urlRange = NSRange(location: link.urlStart, length: link.urlEnd - link.urlStart)
                                tokens.append(MarkdownToken(range: urlRange, kind: .linkURL))
                                protectedForTags.append(urlRange)
                            }
                            tokens.append(MarkdownToken(range: NSRange(location: link.urlEnd, length: 1), kind: .syntaxDelimiter))
                            ranges.append(full)
                        }
                        i = link.end
                        continue
                    }
                    i += 1
                }
            }
            lineIndex = paraLast + 1
        }
        return ranges
    }

    private static func emitLinkLabelSegments(_ units: [UInt16], start: Int, end: Int,
                                              kind: MarkdownTokenKind, tokens: inout [MarkdownToken]) {
        var segStart = start
        var i = start
        while i < end {
            if units[i] == asciiLF || units[i] == asciiCR {
                if i > segStart {
                    tokens.append(MarkdownToken(range: NSRange(location: segStart, length: i - segStart), kind: kind))
                }
                i += 1
                while i < end && (units[i] == asciiLF || units[i] == asciiCR || units[i] == asciiSpace || units[i] == asciiTab) {
                    i += 1
                }
                segStart = i
            } else {
                i += 1
            }
        }
        if end > segStart {
            tokens.append(MarkdownToken(range: NSRange(location: segStart, length: end - segStart), kind: kind))
        }
    }

    private static func scanMultiLineEmphasis(_ units: [UInt16], lines: [Line],
                                              isProseLine: [Bool], isContinuationLine: [Bool],
                                              multiLineLinkRanges: [NSRange],
                                              tokens: inout [MarkdownToken]) -> [NSRange] {
        var multiRanges: [NSRange] = []
        var lineIndex = 0
        while lineIndex < lines.count {
            guard isProseLine[lineIndex] else { lineIndex += 1; continue }
            var paraLast = lineIndex
            while paraLast + 1 < lines.count && isContinuationLine[paraLast + 1] { paraLast += 1 }
            if paraLast > lineIndex {
                let firstLine = lines[lineIndex]
                var paraStart = firstLine.start
                if let quoteStart = matchBlockquote(units, line: firstLine) {
                    paraStart = quoteStart
                }
                if let list = matchListMarker(units, start: paraStart, end: firstLine.end) {
                    paraStart = list.contentStart
                }
                let paraEnd = lines[paraLast].end
                if paraStart < paraEnd {
                    let paraRange = NSRange(location: paraStart, length: paraEnd - paraStart)
                    var protected = multiLineLinkRanges.filter { NSIntersectionRange($0, paraRange).length > 0 }
                    // Collect inline code spans and single-line links/URLs across this paragraph so emphasis skips them.
                    var p = paraStart
                    while p < paraEnd {
                        if let skip = protected.first(where: { p >= $0.location && p < NSMaxRange($0) }) {
                            p = NSMaxRange(skip)
                            continue
                        }
                        let u = units[p]
                        if u == asciiBackslash, p + 1 < paraEnd, isASCIIPunctuation(units[p + 1]) {
                            protected.append(NSRange(location: p, length: 2))
                            p += 2
                            continue
                        }
                        if u == asciiBacktick {
                            var runEnd = p
                            while runEnd < paraEnd && units[runEnd] == asciiBacktick { runEnd += 1 }
                            let runLen = runEnd - p
                            if let close = findClosingBackticks(units, from: runEnd, end: paraEnd, length: runLen) {
                                protected.append(NSRange(location: p, length: (close + runLen) - p))
                                p = close + runLen
                                continue
                            }
                            p = runEnd
                            continue
                        }
                        if u == asciiBang, p + 1 < paraEnd, units[p + 1] == asciiLBracket,
                           let link = matchMarkdownLink(units, openBracket: p + 1, end: paraEnd, allowNewlinesInLabel: false) {
                            protected.append(NSRange(location: p, length: link.end - p))
                            p = link.end
                            continue
                        }
                        if u == asciiLBracket,
                           let link = matchMarkdownLink(units, openBracket: p, end: paraEnd, allowNewlinesInLabel: false) {
                            protected.append(NSRange(location: p, length: link.end - p))
                            p = link.end
                            continue
                        }
                        if (u == 0x68 || u == 0x48), let urlEnd = matchBareURL(units, start: p, lineStart: paraStart, end: paraEnd) {
                            protected.append(NSRange(location: p, length: urlEnd - p))
                            p = urlEnd
                            continue
                        }
                        p += 1
                    }

                    var candidateTokens: [MarkdownToken] = []
                    scanEmphasisAndStrikethrough(units, start: paraStart, end: paraEnd,
                                                 protected: protected, tokens: &candidateTokens)
                    var multiContainers: [NSRange] = []
                    for tok in candidateTokens {
                        let start = tok.range.location
                        let end = NSMaxRange(tok.range)
                        var spansNewline = false
                        for k in start..<end where units[k] == asciiLF {
                            spansNewline = true
                            break
                        }
                        if spansNewline {
                            emitEmphasisSegments(units, start: start, end: end, kind: tok.kind, tokens: &tokens)
                            multiContainers.append(tok.range)
                            multiRanges.append(tok.range)
                        } else if multiContainers.contains(where: { tok.range.location >= $0.location && NSMaxRange(tok.range) <= NSMaxRange($0) }) {
                            tokens.append(tok)
                        }
                    }
                }
            }
            lineIndex = paraLast + 1
        }
        return multiRanges
    }

    private static func emitEmphasisSegments(_ units: [UInt16], start: Int, end: Int,
                                             kind: MarkdownTokenKind, tokens: inout [MarkdownToken]) {
        var segStart = start
        var i = start
        while i < end {
            if units[i] == asciiLF || units[i] == asciiCR {
                if i > segStart {
                    tokens.append(MarkdownToken(range: NSRange(location: segStart, length: i - segStart), kind: kind))
                }
                i += 1
                while i < end && (units[i] == asciiLF || units[i] == asciiCR) { i += 1 }
                segStart = i
            } else {
                i += 1
            }
        }
        if end > segStart {
            tokens.append(MarkdownToken(range: NSRange(location: segStart, length: end - segStart), kind: kind))
        }
    }

    @discardableResult
    private static func scanInline(_ units: [UInt16], start: Int, end: Int,
                                   preProtected: [NSRange] = [],
                                   emphasisProtected: [NSRange] = [],
                                   tokens: inout [MarkdownToken],
                                   protectedForTags: inout [NSRange]) -> [NSRange] {
        var protected = preProtected

        // Phase A: inline code spans, links/images, and bare URLs.
        var i = start
        while i < end {
            if let existing = preProtected.first(where: { i >= $0.location && i < NSMaxRange($0) }) {
                i = NSMaxRange(existing)
                continue
            }
            let u = units[i]
            if u == asciiBackslash, i + 1 < end, isASCIIPunctuation(units[i + 1]) {
                protected.append(NSRange(location: i, length: 2))
                i += 2
                continue
            }

            if u == asciiBacktick {
                var runEnd = i
                while runEnd < end && units[runEnd] == asciiBacktick { runEnd += 1 }
                let runLength = runEnd - i
                if let closeStart = findClosingBackticks(units, from: runEnd, end: end, length: runLength) {
                    let span = NSRange(location: i, length: (closeStart + runLength) - i)
                    tokens.append(MarkdownToken(range: span, kind: .inlineCode))
                    protected.append(span)
                    protectedForTags.append(span)
                    i = closeStart + runLength
                    continue
                }
                i = runEnd
                continue
            }

            if u == asciiBang, i + 1 < end, units[i + 1] == asciiLBracket,
               let link = matchMarkdownLink(units, openBracket: i + 1, end: end) {
                let full = NSRange(location: i, length: link.end - i)
                tokens.append(MarkdownToken(range: NSRange(location: i, length: 2), kind: .syntaxDelimiter))
                if link.labelEnd > link.labelStart {
                    tokens.append(MarkdownToken(range: NSRange(location: link.labelStart, length: link.labelEnd - link.labelStart), kind: .image))
                }
                tokens.append(MarkdownToken(range: NSRange(location: link.labelEnd, length: 2), kind: .syntaxDelimiter))
                if link.urlEnd > link.urlStart {
                    let urlRange = NSRange(location: link.urlStart, length: link.urlEnd - link.urlStart)
                    tokens.append(MarkdownToken(range: urlRange, kind: .linkURL))
                    protectedForTags.append(urlRange)
                }
                tokens.append(MarkdownToken(range: NSRange(location: link.urlEnd, length: 1), kind: .syntaxDelimiter))
                protected.append(full)
                i = link.end
                continue
            }

            if u == asciiLBracket, let link = matchMarkdownLink(units, openBracket: i, end: end) {
                let full = NSRange(location: i, length: link.end - i)
                tokens.append(MarkdownToken(range: NSRange(location: i, length: 1), kind: .syntaxDelimiter))
                if link.labelEnd > link.labelStart {
                    tokens.append(MarkdownToken(range: NSRange(location: link.labelStart, length: link.labelEnd - link.labelStart), kind: .linkText))
                }
                tokens.append(MarkdownToken(range: NSRange(location: link.labelEnd, length: 2), kind: .syntaxDelimiter))
                if link.urlEnd > link.urlStart {
                    let urlRange = NSRange(location: link.urlStart, length: link.urlEnd - link.urlStart)
                    tokens.append(MarkdownToken(range: urlRange, kind: .linkURL))
                    protectedForTags.append(urlRange)
                }
                tokens.append(MarkdownToken(range: NSRange(location: link.urlEnd, length: 1), kind: .syntaxDelimiter))
                protected.append(full)
                i = link.end
                continue
            }

            if (u == 0x68 || u == 0x48), let urlEnd = matchBareURL(units, start: i, lineStart: start, end: end) {
                let urlRange = NSRange(location: i, length: urlEnd - i)
                tokens.append(MarkdownToken(range: urlRange, kind: .linkURL))
                protected.append(urlRange)
                protectedForTags.append(urlRange)
                i = urlEnd
                continue
            }

            i += 1
        }

        // Phase B: strikethrough and emphasis, skipping protected spans (and already-matched multi-line emphasis).
        scanEmphasisAndStrikethrough(units, start: start, end: end,
                                     protected: protected + emphasisProtected, tokens: &tokens)
        return protected
    }

    private static func findClosingBackticks(_ units: [UInt16], from start: Int, end: Int, length: Int) -> Int? {
        var i = start
        while i < end {
            if units[i] == asciiBacktick {
                var j = i
                while j < end && units[j] == asciiBacktick { j += 1 }
                if j - i == length { return i }
                i = j
            } else {
                i += 1
            }
        }
        return nil
    }

    private struct LinkMatch {
        let labelStart: Int
        let labelEnd: Int
        let urlStart: Int
        let urlEnd: Int
        let end: Int
    }

    private static func matchMarkdownLink(_ units: [UInt16], openBracket: Int, end: Int,
                                          allowNewlinesInLabel: Bool = false) -> LinkMatch? {
        var i = openBracket + 1
        var bracketDepth = 0
        var closeBracket: Int?
        while i < end {
            let u = units[i]
            if !allowNewlinesInLabel && (u == asciiLF || u == asciiCR) { return nil }
            if u == asciiBackslash && i + 1 < end { i += 2; continue }
            if u == asciiBacktick {
                var runEnd = i
                while runEnd < end && units[runEnd] == asciiBacktick { runEnd += 1 }
                if let close = findClosingBackticks(units, from: runEnd, end: end, length: runEnd - i) {
                    i = close + (runEnd - i)
                    continue
                }
                i = runEnd
                continue
            }
            if u == asciiLBracket { bracketDepth += 1 }
            else if u == asciiRBracket {
                if bracketDepth == 0 { closeBracket = i; break }
                bracketDepth -= 1
            }
            i += 1
        }
        guard let labelEnd = closeBracket, labelEnd + 1 < end, units[labelEnd + 1] == asciiLParen else { return nil }

        let urlStart = labelEnd + 2
        var j = urlStart
        var parenDepth = 0
        while j < end {
            let u = units[j]
            if u == asciiLF || u == asciiCR { return nil }
            if u == asciiBackslash && j + 1 < end { j += 2; continue }
            if u == asciiLParen { parenDepth += 1 }
            else if u == asciiRParen {
                if parenDepth == 0 {
                    return LinkMatch(labelStart: openBracket + 1, labelEnd: labelEnd,
                                     urlStart: urlStart, urlEnd: j, end: j + 1)
                }
                parenDepth -= 1
            }
            j += 1
        }
        return nil
    }

    private static func matchBareURL(_ units: [UInt16], start: Int, lineStart: Int, end: Int) -> Int? {
        if start > lineStart {
            let prev = units[start - 1]
            let validBoundary = prev == asciiSpace || prev == asciiTab
                || prev == asciiLParen || prev == 0x3C || prev == asciiLBracket
            if !validBoundary { return nil }
        }
        let schemeLen: Int
        if hasASCIIPrefix(units, at: start, end: end, "https://") { schemeLen = 8 }
        else if hasASCIIPrefix(units, at: start, end: end, "http://") { schemeLen = 7 }
        else { return nil }

        var j = start + schemeLen
        var openParens = 0
        while j < end {
            let u = units[j]
            if u == asciiSpace || u == asciiTab || u == 0x3C || u == 0x3E || u == 0x22 || u == 0x27 { break }
            if u == asciiLParen { openParens += 1 }
            else if u == asciiRParen {
                if openParens == 0 { break }
                openParens -= 1
            }
            j += 1
        }
        while j > start + schemeLen {
            let last = units[j - 1]
            if last == asciiDot || last == 0x2C || last == 0x3B || last == asciiColon
                || last == asciiBang || last == 0x3F || last == asciiRBracket || last == 0x7D {
                j -= 1
            } else {
                break
            }
        }
        return j > start + schemeLen ? j : nil
    }

    private static func hasASCIIPrefix(_ units: [UInt16], at start: Int, end: Int, _ target: String) -> Bool {
        let targetUnits = Array(target.utf16)
        guard start + targetUnits.count <= end else { return false }
        for offset in 0..<targetUnits.count {
            var u = units[start + offset]
            if u >= 0x41 && u <= 0x5A { u += 32 } // ASCII lowercase
            if u != targetUnits[offset] { return false }
        }
        return true
    }

    private static func scanEmphasisAndStrikethrough(_ units: [UInt16], start: Int, end: Int,
                                                     protected: [NSRange], tokens: inout [MarkdownToken],
                                                     excludedKind: MarkdownTokenKind? = nil,
                                                     depth: Int = 0) {
        func protectedEnd(at pos: Int) -> Int? {
            for range in protected where pos >= range.location && pos < NSMaxRange(range) {
                return NSMaxRange(range)
            }
            return nil
        }

        var i = start
        while i < end {
            if let skip = protectedEnd(at: i) { i = skip; continue }
            let u = units[i]

            // Strikethrough ~~text~~
            if excludedKind != .strikethrough, u == asciiTilde, i + 1 < end, units[i + 1] == asciiTilde {
                let runEnd = delimiterRunEnd(units, from: i, end: end, char: asciiTilde)
                if runEnd - i == 2, runEnd < end, !isWhitespace(units, at: runEnd) {
                    if let close = findClosingTildes(units, from: runEnd, end: end, protected: protected) {
                        tokens.append(MarkdownToken(range: NSRange(location: i, length: (close + 2) - i), kind: .strikethrough))
                        if depth < 2 && close > runEnd {
                            scanEmphasisAndStrikethrough(units, start: runEnd, end: close,
                                                         protected: protected, tokens: &tokens,
                                                         excludedKind: .strikethrough, depth: depth + 1)
                        }
                        i = close + 2
                        continue
                    }
                }
                i = runEnd
                continue
            }

            // Emphasis: *, **, ***, _, __, ___
            if u == asciiStar || u == asciiUnderscore {
                let runEnd = delimiterRunEnd(units, from: i, end: end, char: u)
                let runLen = runEnd - i
                let kind: MarkdownTokenKind = runLen == 3 ? .boldItalic : (runLen == 2 ? .bold : .italic)
                if runLen >= 1 && runLen <= 3, kind != excludedKind,
                   canOpenEmphasis(units, openStart: i, openEnd: runEnd, delimiter: u, lineStart: start, lineEnd: end),
                   let closeStart = findClosingEmphasis(units, from: runEnd, end: end, delimiter: u, length: runLen,
                                                        lineStart: start, protected: protected) {
                    tokens.append(MarkdownToken(range: NSRange(location: i, length: (closeStart + runLen) - i), kind: kind))
                    if depth < 2 && kind != .boldItalic && closeStart > runEnd {
                        scanEmphasisAndStrikethrough(units, start: runEnd, end: closeStart,
                                                     protected: protected, tokens: &tokens,
                                                     excludedKind: kind, depth: depth + 1)
                    }
                    i = closeStart + runLen
                    continue
                }
                i = runEnd
                continue
            }

            i += 1
        }
    }

    private static func delimiterRunEnd(_ units: [UInt16], from start: Int, end: Int, char: UInt16) -> Int {
        var j = start
        while j < end && units[j] == char { j += 1 }
        return j
    }

    private static func findClosingTildes(_ units: [UInt16], from start: Int, end: Int, protected: [NSRange]) -> Int? {
        var i = start
        while i < end {
            if let range = protected.first(where: { i >= $0.location && i < NSMaxRange($0) }) {
                i = NSMaxRange(range)
                continue
            }
            if units[i] == asciiTilde {
                let runEnd = delimiterRunEnd(units, from: i, end: end, char: asciiTilde)
                if runEnd - i == 2, i > start, !isWhitespace(units, at: i - 1) {
                    return i
                }
                i = runEnd
            } else {
                i += 1
            }
        }
        return nil
    }

    private static func findClosingEmphasis(_ units: [UInt16], from start: Int, end: Int,
                                            delimiter: UInt16, length: Int, lineStart: Int,
                                            protected: [NSRange]) -> Int? {
        var i = start
        while i < end {
            if let range = protected.first(where: { i >= $0.location && i < NSMaxRange($0) }) {
                i = NSMaxRange(range)
                continue
            }
            if units[i] == delimiter {
                let runEnd = delimiterRunEnd(units, from: i, end: end, char: delimiter)
                let avail = runEnd - i
                if i > start,
                   canCloseEmphasis(units, closeStart: i, closeEnd: runEnd, delimiter: delimiter,
                                    lineStart: lineStart, lineEnd: end) {
                    if avail == length {
                        return i
                    }
                    // Allow splitting an adjacent boundary like **[a](x)****[b](y)**
                    // when the remaining delimiter characters can immediately open the next span.
                    if avail > length,
                       canOpenEmphasis(units, openStart: i + length, openEnd: runEnd, delimiter: delimiter,
                                       lineStart: lineStart, lineEnd: end) {
                        return i
                    }
                }
                i = runEnd
            } else {
                i += 1
            }
        }
        return nil
    }

    // CommonMark flanking rules matching Veda's markdown_emphasis.go.
    private static func flanking(_ units: [UInt16], start: Int, end: Int, lineStart: Int, lineEnd: Int)
        -> (left: Bool, right: Bool, beforePunct: Bool, afterPunct: Bool) {
        let before = scalarBefore(units, at: start, minIndex: lineStart)
        let after = scalarAfter(units, at: end, maxIndex: lineEnd)
        let beforeWS = before.map(isUnicodeWhitespace) ?? true
        let afterWS = after.map(isUnicodeWhitespace) ?? true
        let beforePunct = before.map(isUnicodePunctuation) ?? false
        let afterPunct = after.map(isUnicodePunctuation) ?? false
        let left = !afterWS && (!afterPunct || beforeWS || beforePunct)
        let right = !beforeWS && (!beforePunct || afterWS || afterPunct)
        return (left, right, beforePunct, afterPunct)
    }

    private static func canOpenEmphasis(_ units: [UInt16], openStart: Int, openEnd: Int,
                                        delimiter: UInt16, lineStart: Int, lineEnd: Int) -> Bool {
        let f = flanking(units, start: openStart, end: openEnd, lineStart: lineStart, lineEnd: lineEnd)
        if delimiter == asciiStar { return f.left }
        return f.left && (!f.right || f.beforePunct)
    }

    private static func canCloseEmphasis(_ units: [UInt16], closeStart: Int, closeEnd: Int,
                                         delimiter: UInt16, lineStart: Int, lineEnd: Int) -> Bool {
        let f = flanking(units, start: closeStart, end: closeEnd, lineStart: lineStart, lineEnd: lineEnd)
        if delimiter == asciiStar { return f.right }
        return f.right && (!f.left || f.afterPunct)
    }

    private static func scalarBefore(_ units: [UInt16], at index: Int, minIndex: Int) -> UnicodeScalar? {
        guard index > minIndex else { return nil }
        let low = units[index - 1]
        if UTF16.isTrailSurrogate(low), index - 2 >= minIndex, UTF16.isLeadSurrogate(units[index - 2]) {
            return UTF16.decode(UTF16.EncodedScalar([units[index - 2], low]))
        }
        return UnicodeScalar(low)
    }

    private static func scalarAfter(_ units: [UInt16], at index: Int, maxIndex: Int) -> UnicodeScalar? {
        guard index < maxIndex else { return nil }
        let high = units[index]
        if UTF16.isLeadSurrogate(high), index + 1 < maxIndex, UTF16.isTrailSurrogate(units[index + 1]) {
            return UTF16.decode(UTF16.EncodedScalar([high, units[index + 1]]))
        }
        return UnicodeScalar(high)
    }

    private static func isWhitespace(_ units: [UInt16], at index: Int) -> Bool {
        guard let scalar = UnicodeScalar(units[index]) else { return false }
        return isUnicodeWhitespace(scalar)
    }

    private static func isUnicodeWhitespace(_ scalar: UnicodeScalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
            || scalar == "\u{000C}" || scalar.properties.generalCategory == .spaceSeparator
    }

    private static func isUnicodePunctuation(_ scalar: UnicodeScalar) -> Bool {
        let cat = scalar.properties.generalCategory
        switch cat {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }

    private static func isASCIIPunctuation(_ unit: UInt16) -> Bool {
        (unit >= 0x21 && unit <= 0x2F) || (unit >= 0x3A && unit <= 0x40)
            || (unit >= 0x5B && unit <= 0x60) || (unit >= 0x7B && unit <= 0x7E)
    }
}
