import Foundation

enum CodeTokenKind: Equatable, Sendable {
    case keyword
    case type
    case string
    case number
    case comment
    case function
    case variable
    case constant
    case preprocessor
}

struct CodeToken: Equatable, Sendable {
    let range: NSRange
    let kind: CodeTokenKind
}

enum CodeLanguage: String, CaseIterable, Equatable, Sendable {
    case swift
    case go
    case c
    case cpp
    case rust
    case python
    case javascript
    case typescript
    case bash
    case json
    case yaml
    case sql
    case make

    /// Resolves a Markdown fence info string to a supported language.
    /// Rejects empty, unknown, or multi-word labels (matching Veda's fence rules).
    static func forFenceLabel(_ raw: String) -> CodeLanguage? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains(where: { $0 == " " || $0 == "\t" || $0 == "`" }) { return nil }
        switch trimmed.lowercased() {
        case "swift": return .swift
        case "go", "golang": return .go
        case "c", "h": return .c
        case "cpp", "c++", "cc", "cxx", "hpp", "hh", "objc", "objective-c", "mm": return .cpp
        case "rust", "rs": return .rust
        case "python", "py", "python3": return .python
        case "javascript", "js", "jsx", "mjs", "cjs": return .javascript
        case "typescript", "ts", "tsx", "mts", "cts": return .typescript
        case "bash", "sh", "shell", "zsh", "fish": return .bash
        case "json", "jsonc": return .json
        case "yaml", "yml": return .yaml
        case "sql", "sqlite", "postgres", "postgresql", "mysql": return .sql
        case "make", "makefile", "mk": return .make
        default: return nil
        }
    }
}

/// Zero-dependency, UTF-16 range-exact lexer for fenced code blocks.
enum TaskCodeHighlighter {
    private struct Spec {
        let keywords: Set<String>
        let types: Set<String>
        let constants: Set<String>
        let caseInsensitive: Bool
        let slashSlashComments: Bool
        let slashStarComments: Bool
        let nestedBlockComments: Bool
        let hashComments: Bool
        let dashDashComments: Bool
        let singleQuotedStrings: Bool
        let singleQuoteDoubledEscape: Bool
        let backtickRawStrings: Bool
        let backtickTemplateStrings: Bool
        let tripleDoubleStrings: Bool
        let tripleSingleStrings: Bool
        let stringPrefixes: Set<UInt16>
        let cPreprocessor: Bool
        let atAttributes: Bool
        let rustAttributesAndLifetimes: Bool
        let shellSyntax: Bool
        let jsonMode: Bool
        let yamlMode: Bool
        let makeMode: Bool
        let pascalCaseTypes: Bool
    }

    static func tokenize(_ units: [UInt16], range: NSRange, language: CodeLanguage) -> [CodeToken] {
        let start = max(0, range.location)
        let end = min(units.count, NSMaxRange(range))
        guard start < end else { return [] }

        let spec = spec(for: language)
        if spec.yamlMode {
            return tokenizeYAML(units, start: start, end: end)
        }
        if spec.makeMode {
            return tokenizeMake(units, start: start, end: end)
        }

        var tokens: [CodeToken] = []
        var i = start

        while i < end {
            let u = units[i]

            // Skip whitespace
            if u == 0x20 || u == 0x09 || u == 0x0A || u == 0x0D {
                i += 1
                continue
            }

            // Line comments: // ...
            if spec.slashSlashComments, u == 0x2F, i + 1 < end, units[i + 1] == 0x2F {
                let commentEnd = scanToLineEnd(units, from: i + 2, end: end)
                tokens.append(CodeToken(range: NSRange(location: i, length: commentEnd - i), kind: .comment))
                i = commentEnd
                continue
            }

            // Block comments: /* ... */
            if spec.slashStarComments, u == 0x2F, i + 1 < end, units[i + 1] == 0x2A {
                let commentEnd = scanBlockComment(units, from: i + 2, end: end, nested: spec.nestedBlockComments)
                emitPerLine(units, start: i, end: commentEnd, kind: .comment, tokens: &tokens)
                i = commentEnd
                continue
            }

            // Line comments: # ...
            if spec.hashComments, u == 0x23,
               (!spec.shellSyntax || i == start || isShellCommentBoundary(units[i - 1])) {
                let commentEnd = scanToLineEnd(units, from: i + 1, end: end)
                tokens.append(CodeToken(range: NSRange(location: i, length: commentEnd - i), kind: .comment))
                i = commentEnd
                continue
            }

            // Line comments: -- ... (SQL)
            if spec.dashDashComments, u == 0x2D, i + 1 < end, units[i + 1] == 0x2D {
                let commentEnd = scanToLineEnd(units, from: i + 2, end: end)
                tokens.append(CodeToken(range: NSRange(location: i, length: commentEnd - i), kind: .comment))
                i = commentEnd
                continue
            }

            // C/C++ preprocessor directives at start of line (#include, #define, ...)
            if spec.cPreprocessor, u == 0x23, isLineLeading(units, at: i, minStart: start) {
                var j = i + 1
                while j < end && (units[j] == 0x20 || units[j] == 0x09) { j += 1 }
                let wordStart = j
                while j < end && isIdentContinue(units[j]) { j += 1 }
                if j > wordStart {
                    tokens.append(CodeToken(range: NSRange(location: i, length: j - i), kind: .preprocessor))
                    // Highlight <header.h> after #include as string
                    let directive = asciiString(units, start: wordStart, end: j)
                    if directive == "include" || directive == "import" {
                        var k = j
                        while k < end && (units[k] == 0x20 || units[k] == 0x09) { k += 1 }
                        if k < end && units[k] == 0x3C { // <
                            var close = k + 1
                            while close < end && units[close] != 0x3E && units[close] != 0x0A && units[close] != 0x0D {
                                close += 1
                            }
                            if close < end && units[close] == 0x3E {
                                tokens.append(CodeToken(range: NSRange(location: k, length: (close + 1) - k), kind: .string))
                                i = close + 1
                                continue
                            }
                        }
                    }
                    i = j
                    continue
                }
            }

            // Rust attributes #[...] / #![...]
            if spec.rustAttributesAndLifetimes, u == 0x23 {
                var j = i + 1
                if j < end && units[j] == 0x21 { j += 1 }
                if j < end && units[j] == 0x5B { // [
                    var depth = 1
                    j += 1
                    while j < end && depth > 0 {
                        if units[j] == 0x5B { depth += 1 }
                        else if units[j] == 0x5D { depth -= 1 }
                        j += 1
                    }
                    emitPerLine(units, start: i, end: j, kind: .preprocessor, tokens: &tokens)
                    i = j
                    continue
                }
            }

            // @decorator / @attribute (Swift, Python, TypeScript)
            if spec.atAttributes, u == 0x40, i + 1 < end, isIdentStart(units[i + 1]) {
                var j = i + 2
                while j < end && (isIdentContinue(units[j]) || units[j] == 0x2E) { j += 1 }
                tokens.append(CodeToken(range: NSRange(location: i, length: j - i), kind: .preprocessor))
                i = j
                continue
            }

            // Python / Rust prefixed strings (f"...", r"...", b"...", etc.)
            if !spec.stringPrefixes.isEmpty, isIdentStart(u) {
                var pEnd = i
                while pEnd < end && pEnd - i < 2 && spec.stringPrefixes.contains(units[pEnd]) {
                    pEnd += 1
                }
                if pEnd > i && pEnd < end {
                    let quote = units[pEnd]
                    if quote == 0x22 || (spec.singleQuotedStrings && quote == 0x27) {
                        // Make sure we weren't in the middle of an identifier (we aren't since we consume full idents)
                        if quote == 0x22, spec.tripleDoubleStrings, hasTriple(units, at: pEnd, end: end, quote: 0x22) {
                            let strEnd = scanTripleString(units, from: pEnd + 3, end: end, quote: 0x22)
                            emitPerLine(units, start: i, end: strEnd, kind: .string, tokens: &tokens)
                            i = strEnd
                            continue
                        }
                        if quote == 0x27, spec.tripleSingleStrings, hasTriple(units, at: pEnd, end: end, quote: 0x27) {
                            let strEnd = scanTripleString(units, from: pEnd + 3, end: end, quote: 0x27)
                            emitPerLine(units, start: i, end: strEnd, kind: .string, tokens: &tokens)
                            i = strEnd
                            continue
                        }
                        let strEnd = scanQuotedString(units, from: pEnd + 1, end: end, quote: quote,
                                                      allowBackslash: true, doubledEscape: false, allowNewline: false)
                        tokens.append(CodeToken(range: NSRange(location: i, length: strEnd - i), kind: .string))
                        i = strEnd
                        continue
                    }
                }
            }

            // Triple double-quoted strings """..."""
            if spec.tripleDoubleStrings, u == 0x22, hasTriple(units, at: i, end: end, quote: 0x22) {
                let strEnd = scanTripleString(units, from: i + 3, end: end, quote: 0x22)
                emitPerLine(units, start: i, end: strEnd, kind: .string, tokens: &tokens)
                i = strEnd
                continue
            }

            // Triple single-quoted strings '''...'''
            if spec.tripleSingleStrings, u == 0x27, hasTriple(units, at: i, end: end, quote: 0x27) {
                let strEnd = scanTripleString(units, from: i + 3, end: end, quote: 0x27)
                emitPerLine(units, start: i, end: strEnd, kind: .string, tokens: &tokens)
                i = strEnd
                continue
            }

            // Double-quoted strings "..."
            if u == 0x22 {
                let strEnd = scanQuotedString(units, from: i + 1, end: end, quote: 0x22,
                                              allowBackslash: true, doubledEscape: false, allowNewline: false)
                if spec.jsonMode, isFollowedByColon(units, after: strEnd, end: end) {
                    tokens.append(CodeToken(range: NSRange(location: i, length: strEnd - i), kind: .variable))
                } else if spec.shellSyntax {
                    emitShellDoubleQuotedString(units, start: i, end: strEnd, tokens: &tokens)
                } else {
                    tokens.append(CodeToken(range: NSRange(location: i, length: strEnd - i), kind: .string))
                }
                i = strEnd
                continue
            }

            // Single-quoted strings / chars / Rust lifetimes
            if spec.singleQuotedStrings, u == 0x27 {
                if spec.rustAttributesAndLifetimes {
                    // Check char literal first ('x', '\n', '\x7f', '\u{...}') vs lifetime ('a, 'static)
                    if let charEnd = matchRustCharLiteral(units, start: i, end: end) {
                        tokens.append(CodeToken(range: NSRange(location: i, length: charEnd - i), kind: .string))
                        i = charEnd
                        continue
                    }
                    if i + 1 < end && isIdentStart(units[i + 1]) {
                        var j = i + 2
                        while j < end && isIdentContinue(units[j]) { j += 1 }
                        tokens.append(CodeToken(range: NSRange(location: i, length: j - i), kind: .type))
                        i = j
                        continue
                    }
                    i += 1
                    continue
                }
                let allowBackslash = !spec.singleQuoteDoubledEscape && !spec.shellSyntax
                let strEnd = scanQuotedString(units, from: i + 1, end: end, quote: 0x27,
                                              allowBackslash: allowBackslash,
                                              doubledEscape: spec.singleQuoteDoubledEscape,
                                              allowNewline: false)
                tokens.append(CodeToken(range: NSRange(location: i, length: strEnd - i), kind: .string))
                i = strEnd
                continue
            }

            // Backtick strings (Go raw strings or JS/TS template literals)
            if (spec.backtickRawStrings || spec.backtickTemplateStrings), u == 0x60 {
                let strEnd = scanQuotedString(units, from: i + 1, end: end, quote: 0x60,
                                              allowBackslash: spec.backtickTemplateStrings,
                                              doubledEscape: false, allowNewline: true)
                emitPerLine(units, start: i, end: strEnd, kind: .string, tokens: &tokens)
                i = strEnd
                continue
            }

            // Shell variables ($VAR, ${VAR}, $1, $?, $@, $*)
            if spec.shellSyntax, u == 0x24 {
                if let varEnd = matchShellVariable(units, start: i, end: end) {
                    tokens.append(CodeToken(range: NSRange(location: i, length: varEnd - i), kind: .variable))
                    i = varEnd
                    continue
                }
            }

            // Numbers (integers, floats, hex, binary, octal, underscores)
            if isDigit(u) || (u == 0x2D && spec.jsonMode && i + 1 < end && isDigit(units[i + 1])) {
                let numStart = i
                var j = (u == 0x2D) ? i + 1 : i
                j = scanNumber(units, from: j, end: end)
                let shellStandalone = !spec.shellSyntax || (
                    (numStart == start || isShellNumberBoundary(units[numStart - 1]))
                    && (j == end || isShellNumberBoundary(units[j]))
                )
                if shellStandalone {
                    tokens.append(CodeToken(range: NSRange(location: numStart, length: j - numStart), kind: .number))
                }
                i = j
                continue
            }

            // Identifiers, keywords, types, constants, functions, shell assignments
            if isIdentStart(u) {
                var j = i + 1
                while j < end && isIdentContinue(units[j]) { j += 1 }
                let rawWord = asciiString(units, start: i, end: j)
                let word = spec.caseInsensitive ? rawWord.lowercased() : rawWord
                let tokRange = NSRange(location: i, length: j - i)

                if spec.shellSyntax, j < end, units[j] == 0x3D,
                   (j + 1 >= end || units[j + 1] != 0x3D) {
                    // Shell variable assignment: TOKEN=...
                    tokens.append(CodeToken(range: tokRange, kind: .variable))
                } else if spec.keywords.contains(word) {
                    tokens.append(CodeToken(range: tokRange, kind: .keyword))
                } else if spec.constants.contains(word) {
                    tokens.append(CodeToken(range: tokRange, kind: .constant))
                } else if spec.types.contains(word) {
                    tokens.append(CodeToken(range: tokRange, kind: .type))
                } else if isFollowedByOpenParen(units, after: j, end: end) {
                    tokens.append(CodeToken(range: tokRange, kind: .function))
                } else if spec.pascalCaseTypes, isPascalCaseIdentifier(units, start: i, end: j) {
                    tokens.append(CodeToken(range: tokRange, kind: .type))
                }
                i = j
                continue
            }

            i += 1
        }

        return tokens
    }

    // MARK: - YAML & Make Specialized Tokenizers

    private static func tokenizeYAML(_ units: [UInt16], start: Int, end: Int) -> [CodeToken] {
        var tokens: [CodeToken] = []
        var i = start
        while i < end {
            let lineStart = i
            let lineEnd = scanToLineEnd(units, from: i, end: end)
            var p = lineStart
            while p < lineEnd && (units[p] == 0x20 || units[p] == 0x09) { p += 1 }

            if p < lineEnd {
                if units[p] == 0x23 { // # comment
                    tokens.append(CodeToken(range: NSRange(location: p, length: lineEnd - p), kind: .comment))
                } else {
                    // Optional YAML sequence bullet `- `
                    if units[p] == 0x2D && (p + 1 == lineEnd || units[p + 1] == 0x20 || units[p + 1] == 0x09) {
                        p += 1
                        while p < lineEnd && (units[p] == 0x20 || units[p] == 0x09) { p += 1 }
                    }
                    // Check key: value
                    var scanStart = p
                    if let colon = findYAMLKeyColon(units, from: p, end: lineEnd) {
                        tokens.append(CodeToken(range: NSRange(location: p, length: colon - p), kind: .variable))
                        scanStart = colon + 1
                    }
                    tokenizeYAMLValue(units, start: scanStart, end: lineEnd, tokens: &tokens)
                }
            }
            i = lineEnd
            if i < end && units[i] == 0x0D { i += 1 }
            if i < end && units[i] == 0x0A { i += 1 }
        }
        return tokens
    }

    private static func findYAMLKeyColon(_ units: [UInt16], from start: Int, end: Int) -> Int? {
        guard start < end, units[start] != 0x22, units[start] != 0x27, units[start] != 0x23 else { return nil }
        var i = start
        while i < end {
            let u = units[i]
            if u == 0x3A { // :
                if i > start && (i + 1 == end || units[i + 1] == 0x20 || units[i + 1] == 0x09) {
                    return i
                }
            }
            if u == 0x23 && i > start && units[i - 1] == 0x20 { return nil }
            i += 1
        }
        return nil
    }

    private static func tokenizeYAMLValue(_ units: [UInt16], start: Int, end: Int, tokens: inout [CodeToken]) {
        var i = start
        while i < end {
            let u = units[i]
            if u == 0x20 || u == 0x09 { i += 1; continue }
            if u == 0x23 && (i == start || units[i - 1] == 0x20 || units[i - 1] == 0x09) {
                tokens.append(CodeToken(range: NSRange(location: i, length: end - i), kind: .comment))
                return
            }
            if u == 0x22 || u == 0x27 {
                let strEnd = scanQuotedString(units, from: i + 1, end: end, quote: u,
                                              allowBackslash: u == 0x22, doubledEscape: u == 0x27, allowNewline: false)
                tokens.append(CodeToken(range: NSRange(location: i, length: strEnd - i), kind: .string))
                i = strEnd
                continue
            }
            if isDigit(u) || (u == 0x2D && i + 1 < end && isDigit(units[i + 1])) {
                let numStart = i
                var j = (u == 0x2D) ? i + 1 : i
                j = scanNumber(units, from: j, end: end)
                if j == end || units[j] == 0x20 || units[j] == 0x09 || units[j] == 0x2C || units[j] == 0x5D || units[j] == 0x7D {
                    tokens.append(CodeToken(range: NSRange(location: numStart, length: j - numStart), kind: .number))
                    i = j
                    continue
                }
            }
            if isIdentStart(u) {
                var j = i + 1
                while j < end && isIdentContinue(units[j]) { j += 1 }
                let word = asciiString(units, start: i, end: j).lowercased()
                if (word == "true" || word == "false" || word == "null" || word == "yes" || word == "no") &&
                    (j == end || units[j] == 0x20 || units[j] == 0x09 || units[j] == 0x2C || units[j] == 0x5D || units[j] == 0x7D) {
                    tokens.append(CodeToken(range: NSRange(location: i, length: j - i), kind: .constant))
                }
                i = j
                continue
            }
            i += 1
        }
    }

    private static func tokenizeMake(_ units: [UInt16], start: Int, end: Int) -> [CodeToken] {
        var tokens: [CodeToken] = []
        var i = start
        while i < end {
            let lineStart = i
            let lineEnd = scanToLineEnd(units, from: i, end: end)
            var p = lineStart
            let isRecipe = p < lineEnd && units[p] == 0x09
            while p < lineEnd && (units[p] == 0x20 || units[p] == 0x09) { p += 1 }

            if p < lineEnd {
                if units[p] == 0x23 {
                    tokens.append(CodeToken(range: NSRange(location: p, length: lineEnd - p), kind: .comment))
                } else {
                    var scanFrom = p
                    if !isRecipe {
                        // Target `all:` or variable assignment `CC = clang`
                        var j = p
                        while j < lineEnd && units[j] != 0x3A && units[j] != 0x3D && units[j] != 0x23 { j += 1 }
                        if j < lineEnd && units[j] == 0x3A && (j + 1 >= lineEnd || units[j + 1] != 0x3D) {
                            var targetEnd = j
                            while targetEnd > p && units[targetEnd - 1] == 0x20 { targetEnd -= 1 }
                            if targetEnd > p {
                                tokens.append(CodeToken(range: NSRange(location: p, length: targetEnd - p), kind: .constant))
                            }
                            scanFrom = j + 1
                        } else if j < lineEnd && (units[j] == 0x3D || (units[j] == 0x3A && j + 1 < lineEnd && units[j + 1] == 0x3D)) {
                            var varEnd = j
                            while varEnd > p && (units[varEnd - 1] == 0x20 || units[varEnd - 1] == 0x3F || units[varEnd - 1] == 0x2B) {
                                varEnd -= 1
                            }
                            if varEnd > p {
                                tokens.append(CodeToken(range: NSRange(location: p, length: varEnd - p), kind: .variable))
                            }
                            scanFrom = j + 1
                        }
                    }
                    // Scan $(VAR), strings, and # comments on remainder of line
                    var k = scanFrom
                    while k < lineEnd {
                        let u = units[k]
                        if u == 0x23 {
                            tokens.append(CodeToken(range: NSRange(location: k, length: lineEnd - k), kind: .comment))
                            break
                        }
                        if u == 0x24, k + 1 < lineEnd, (units[k + 1] == 0x28 || units[k + 1] == 0x7B) {
                            let closeChar: UInt16 = units[k + 1] == 0x28 ? 0x29 : 0x7D
                            var m = k + 2
                            while m < lineEnd && units[m] != closeChar { m += 1 }
                            let endPos = m < lineEnd ? m + 1 : m
                            tokens.append(CodeToken(range: NSRange(location: k, length: endPos - k), kind: .variable))
                            k = endPos
                            continue
                        }
                        if u == 0x22 || u == 0x27 {
                            let strEnd = scanQuotedString(units, from: k + 1, end: lineEnd, quote: u,
                                                          allowBackslash: u == 0x22, doubledEscape: false, allowNewline: false)
                            tokens.append(CodeToken(range: NSRange(location: k, length: strEnd - k), kind: .string))
                            k = strEnd
                            continue
                        }
                        k += 1
                    }
                }
            }

            i = lineEnd
            if i < end && units[i] == 0x0D { i += 1 }
            if i < end && units[i] == 0x0A { i += 1 }
        }
        return tokens
    }

    // MARK: - Lexer Primitives

    private static func scanToLineEnd(_ units: [UInt16], from start: Int, end: Int) -> Int {
        var i = start
        while i < end && units[i] != 0x0A && units[i] != 0x0D { i += 1 }
        return i
    }

    private static func scanBlockComment(_ units: [UInt16], from start: Int, end: Int, nested: Bool) -> Int {
        var i = start
        var depth = 1
        while i < end && depth > 0 {
            if nested, units[i] == 0x2F, i + 1 < end, units[i + 1] == 0x2A {
                depth += 1
                i += 2
                continue
            }
            if units[i] == 0x2A, i + 1 < end, units[i + 1] == 0x2F {
                depth -= 1
                i += 2
                continue
            }
            i += 1
        }
        return i
    }

    private static func hasTriple(_ units: [UInt16], at index: Int, end: Int, quote: UInt16) -> Bool {
        index + 2 < end && units[index] == quote && units[index + 1] == quote && units[index + 2] == quote
    }

    private static func scanTripleString(_ units: [UInt16], from start: Int, end: Int, quote: UInt16) -> Int {
        var i = start
        while i < end {
            if units[i] == 0x5C && i + 1 < end { i += 2; continue }
            if hasTriple(units, at: i, end: end, quote: quote) { return i + 3 }
            i += 1
        }
        return end
    }

    private static func scanQuotedString(_ units: [UInt16], from start: Int, end: Int, quote: UInt16,
                                         allowBackslash: Bool, doubledEscape: Bool, allowNewline: Bool) -> Int {
        var i = start
        while i < end {
            let u = units[i]
            if !allowNewline && (u == 0x0A || u == 0x0D) { return i }
            if allowBackslash && u == 0x5C && i + 1 < end {
                i += 2
                continue
            }
            if u == quote {
                if doubledEscape && i + 1 < end && units[i + 1] == quote {
                    i += 2
                    continue
                }
                return i + 1
            }
            i += 1
        }
        return end
    }

    private static func matchRustCharLiteral(_ units: [UInt16], start: Int, end: Int) -> Int? {
        guard start + 2 < end, units[start] == 0x27 else { return nil }
        if units[start + 1] == 0x5C {
            // Escape sequence: '\n', '\'', '\x7f', '\u{1F600}'
            var j = start + 2
            while j < end && j < start + 14 && units[j] != 0x27 && units[j] != 0x0A && units[j] != 0x0D {
                j += 1
            }
            return (j < end && units[j] == 0x27) ? j + 1 : nil
        }
        // Single char (or UTF-16 surrogate pair) followed by closing '
        if units[start + 1] != 0x27 && units[start + 1] != 0x0A && units[start + 1] != 0x0D {
            if UTF16.isLeadSurrogate(units[start + 1]), start + 3 < end, units[start + 3] == 0x27 {
                return start + 4
            }
            if units[start + 2] == 0x27 {
                return start + 3
            }
        }
        return nil
    }

    private static func matchShellVariable(_ units: [UInt16], start: Int, end: Int) -> Int? {
        guard start + 1 < end, units[start] == 0x24 else { return nil }
        let next = units[start + 1]
        if next == 0x7B { // ${...}
            var j = start + 2
            while j < end && units[j] != 0x7D && units[j] != 0x0A && units[j] != 0x0D { j += 1 }
            return j < end && units[j] == 0x7D ? j + 1 : nil
        }
        if isIdentStart(next) {
            var j = start + 2
            while j < end && isIdentContinue(units[j]) { j += 1 }
            return j
        }
        // Special shell parameters: $0..$9, $?, $$, $!, $@, $*, $#
        if isDigit(next) || next == 0x3F || next == 0x24 || next == 0x21
            || next == 0x40 || next == 0x2A || next == 0x23 {
            return start + 2
        }
        return nil
    }

    private static func emitShellDoubleQuotedString(_ units: [UInt16], start: Int, end: Int, tokens: inout [CodeToken]) {
        var segStart = start
        var i = start + 1
        let innerEnd = (end > start + 1 && units[end - 1] == 0x22) ? end - 1 : end
        while i < innerEnd {
            if units[i] == 0x5C && i + 1 < innerEnd { i += 2; continue }
            if units[i] == 0x24, let varEnd = matchShellVariable(units, start: i, end: innerEnd) {
                if i > segStart {
                    tokens.append(CodeToken(range: NSRange(location: segStart, length: i - segStart), kind: .string))
                }
                tokens.append(CodeToken(range: NSRange(location: i, length: varEnd - i), kind: .variable))
                segStart = varEnd
                i = varEnd
                continue
            }
            i += 1
        }
        if end > segStart {
            tokens.append(CodeToken(range: NSRange(location: segStart, length: end - segStart), kind: .string))
        }
    }

    private static func scanNumber(_ units: [UInt16], from start: Int, end: Int) -> Int {
        var i = start
        if units[i] == 0x30, i + 1 < end {
            let next = units[i + 1]
            if next == 0x78 || next == 0x58 { // 0x hex
                i += 2
                while i < end && (isHexDigit(units[i]) || units[i] == 0x5F) { i += 1 }
                while i < end && isIdentContinue(units[i]) { i += 1 }
                return i
            }
            if next == 0x62 || next == 0x42 { // 0b binary
                i += 2
                while i < end && (units[i] == 0x30 || units[i] == 0x31 || units[i] == 0x5F) { i += 1 }
                while i < end && isIdentContinue(units[i]) { i += 1 }
                return i
            }
            if next == 0x6F || next == 0x4F { // 0o octal
                i += 2
                while i < end && ((units[i] >= 0x30 && units[i] <= 0x37) || units[i] == 0x5F) { i += 1 }
                while i < end && isIdentContinue(units[i]) { i += 1 }
                return i
            }
        }
        while i < end && (isDigit(units[i]) || units[i] == 0x5F) { i += 1 }
        if i < end && units[i] == 0x2E && i + 1 < end && isDigit(units[i + 1]) {
            i += 1
            while i < end && (isDigit(units[i]) || units[i] == 0x5F) { i += 1 }
        }
        if i < end && (units[i] == 0x65 || units[i] == 0x45) {
            var e = i + 1
            if e < end && (units[e] == 0x2B || units[e] == 0x2D) { e += 1 }
            if e < end && isDigit(units[e]) {
                i = e + 1
                while i < end && (isDigit(units[i]) || units[i] == 0x5F) { i += 1 }
            }
        }
        // Optional numeric suffix (u64, i32, f32, UL, etc.)
        while i < end && isIdentContinue(units[i]) { i += 1 }
        return i
    }

    private static func emitPerLine(_ units: [UInt16], start: Int, end: Int,
                                    kind: CodeTokenKind, tokens: inout [CodeToken]) {
        var segStart = start
        var i = start
        while i < end {
            if units[i] == 0x0A || units[i] == 0x0D {
                if i > segStart {
                    tokens.append(CodeToken(range: NSRange(location: segStart, length: i - segStart), kind: kind))
                }
                i += 1
                while i < end && (units[i] == 0x0A || units[i] == 0x0D) { i += 1 }
                segStart = i
            } else {
                i += 1
            }
        }
        if end > segStart {
            tokens.append(CodeToken(range: NSRange(location: segStart, length: end - segStart), kind: kind))
        }
    }

    private static func isLineLeading(_ units: [UInt16], at index: Int, minStart: Int) -> Bool {
        var i = index
        while i > minStart {
            i -= 1
            let u = units[i]
            if u == 0x0A || u == 0x0D { return true }
            if u != 0x20 && u != 0x09 { return false }
        }
        return true
    }

    private static func isFollowedByColon(_ units: [UInt16], after index: Int, end: Int) -> Bool {
        var i = index
        while i < end && (units[i] == 0x20 || units[i] == 0x09) { i += 1 }
        return i < end && units[i] == 0x3A
    }

    private static func isFollowedByOpenParen(_ units: [UInt16], after index: Int, end: Int) -> Bool {
        var i = index
        while i < end && (units[i] == 0x20 || units[i] == 0x09) { i += 1 }
        return i < end && units[i] == 0x28
    }

    private static func isPascalCaseIdentifier(_ units: [UInt16], start: Int, end: Int) -> Bool {
        guard end - start >= 2, units[start] >= 0x41 && units[start] <= 0x5A else { return false }
        var hasLower = false
        for i in (start + 1)..<end {
            let u = units[i]
            if u >= 0x61 && u <= 0x7A { hasLower = true; break }
        }
        return hasLower
    }

    private static func isDigit(_ u: UInt16) -> Bool { u >= 0x30 && u <= 0x39 }

    private static func isHexDigit(_ u: UInt16) -> Bool {
        isDigit(u) || (u >= 0x41 && u <= 0x46) || (u >= 0x61 && u <= 0x66)
    }

    private static func isIdentStart(_ u: UInt16) -> Bool {
        (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) || u == 0x5F
    }

    private static func isIdentContinue(_ u: UInt16) -> Bool {
        isIdentStart(u) || isDigit(u)
    }

    private static func isShellCommentBoundary(_ u: UInt16) -> Bool {
        u == 0x20 || u == 0x09 || u == 0x0A || u == 0x0D || u == 0x3B || u == 0x26 || u == 0x7C || u == 0x28
    }

    private static func isShellNumberBoundary(_ u: UInt16) -> Bool {
        isShellCommentBoundary(u) || u == 0x29 || u == 0x3D || u == 0x5B || u == 0x5D || u == 0x2C
    }

    private static func asciiString(_ units: [UInt16], start: Int, end: Int) -> String {
        String(utf16CodeUnits: Array(units[start..<end]), count: end - start)
    }

    // MARK: - Language Specs

    private static func spec(for language: CodeLanguage) -> Spec {
        switch language {
        case .swift:
            return Spec(
                keywords: ["actor", "as", "associatedtype", "async", "await", "break", "case", "catch", "class",
                           "continue", "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough",
                           "fileprivate", "final", "for", "func", "guard", "if", "import", "in", "indirect", "infix",
                           "init", "inout", "internal", "is", "lazy", "let", "mutating", "nonisolated", "nonmutating",
                           "open", "operator", "optional", "override", "package", "postfix", "prefix", "private",
                           "protocol", "public", "repeat", "required", "rethrows", "return", "some", "static", "struct",
                           "subscript", "switch", "throw", "throws", "try", "typealias", "unowned", "var", "weak",
                           "where", "while", "any", "isolated", "consuming", "borrowing"],
                types: ["Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
                        "Double", "Float", "CGFloat", "Bool", "String", "Substring", "Character", "Data", "URL",
                        "Date", "UUID", "Void", "Never", "Any", "AnyObject", "Error", "Result", "Optional", "Array",
                        "Dictionary", "Set", "Task", "Sendable"],
                constants: ["true", "false", "nil", "self", "Self", "super"],
                caseInsensitive: false,
                slashSlashComments: true, slashStarComments: true, nestedBlockComments: true,
                hashComments: false, dashDashComments: false,
                singleQuotedStrings: false, singleQuoteDoubledEscape: false,
                backtickRawStrings: false, backtickTemplateStrings: false,
                tripleDoubleStrings: true, tripleSingleStrings: false,
                stringPrefixes: [],
                cPreprocessor: false, atAttributes: true, rustAttributesAndLifetimes: false,
                shellSyntax: false, jsonMode: false, yamlMode: false, makeMode: false,
                pascalCaseTypes: true
            )

        case .go:
            return Spec(
                keywords: ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
                           "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range",
                           "return", "select", "struct", "switch", "type", "var"],
                types: ["any", "bool", "byte", "comparable", "complex64", "complex128", "error", "float32", "float64",
                        "int", "int8", "int16", "int32", "int64", "rune", "string", "uint", "uint8", "uint16",
                        "uint32", "uint64", "uintptr"],
                constants: ["true", "false", "nil", "iota"],
                caseInsensitive: false,
                slashSlashComments: true, slashStarComments: true, nestedBlockComments: false,
                hashComments: false, dashDashComments: false,
                singleQuotedStrings: true, singleQuoteDoubledEscape: false,
                backtickRawStrings: true, backtickTemplateStrings: false,
                tripleDoubleStrings: false, tripleSingleStrings: false,
                stringPrefixes: [],
                cPreprocessor: false, atAttributes: false, rustAttributesAndLifetimes: false,
                shellSyntax: false, jsonMode: false, yamlMode: false, makeMode: false,
                pascalCaseTypes: false
            )

        case .c:
            return Spec(
                keywords: ["auto", "break", "case", "const", "continue", "default", "do", "else", "enum", "extern",
                           "for", "goto", "if", "inline", "register", "restrict", "return", "sizeof", "static",
                           "struct", "switch", "typedef", "union", "volatile", "while"],
                types: ["void", "char", "short", "int", "long", "float", "double", "signed", "unsigned", "bool",
                        "_Bool", "size_t", "ssize_t", "ptrdiff_t", "intptr_t", "uintptr_t",
                        "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t",
                        "FILE"],
                constants: ["true", "false", "NULL", "EOF"],
                caseInsensitive: false,
                slashSlashComments: true, slashStarComments: true, nestedBlockComments: false,
                hashComments: false, dashDashComments: false,
                singleQuotedStrings: true, singleQuoteDoubledEscape: false,
                backtickRawStrings: false, backtickTemplateStrings: false,
                tripleDoubleStrings: false, tripleSingleStrings: false,
                stringPrefixes: [],
                cPreprocessor: true, atAttributes: false, rustAttributesAndLifetimes: false,
                shellSyntax: false, jsonMode: false, yamlMode: false, makeMode: false,
                pascalCaseTypes: false
            )

        case .cpp:
            return Spec(
                keywords: ["alignas", "alignof", "auto", "break", "case", "catch", "class", "co_await", "co_return",
                           "co_yield", "concept", "const", "consteval", "constexpr", "constinit", "const_cast",
                           "continue", "decltype", "default", "delete", "do", "dynamic_cast", "else", "enum",
                           "explicit", "export", "extern", "final", "for", "friend", "goto", "if", "inline", "mutable",
                           "namespace", "new", "noexcept", "operator", "override", "private", "protected", "public",
                           "reinterpret_cast", "requires", "return", "sizeof", "static", "static_assert", "static_cast",
                           "struct", "switch", "template", "throw", "try", "typedef", "typeid", "typename", "union",
                           "using", "virtual", "volatile", "while"],
                types: ["void", "bool", "char", "char8_t", "char16_t", "char32_t", "wchar_t", "short", "int", "long",
                        "float", "double", "signed", "unsigned", "size_t", "ssize_t", "ptrdiff_t",
                        "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t",
                        "string", "string_view", "vector", "map", "unordered_map", "set", "optional", "unique_ptr",
                        "shared_ptr", "span"],
                constants: ["true", "false", "nullptr", "NULL", "this"],
                caseInsensitive: false,
                slashSlashComments: true, slashStarComments: true, nestedBlockComments: false,
                hashComments: false, dashDashComments: false,
                singleQuotedStrings: true, singleQuoteDoubledEscape: false,
                backtickRawStrings: false, backtickTemplateStrings: false,
                tripleDoubleStrings: false, tripleSingleStrings: false,
                stringPrefixes: [],
                cPreprocessor: true, atAttributes: true, rustAttributesAndLifetimes: false,
                shellSyntax: false, jsonMode: false, yamlMode: false, makeMode: false,
                pascalCaseTypes: false
            )

        case .rust:
            return Spec(
                keywords: ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
                           "extern", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut",
                           "pub", "ref", "return", "static", "struct", "trait", "type", "unsafe", "use", "where",
                           "while"],
                types: ["bool", "char", "str", "i8", "i16", "i32", "i64", "i128", "isize",
                        "u8", "u16", "u32", "u64", "u128", "usize", "f32", "f64",
                        "String", "Vec", "Option", "Result", "Box", "Rc", "Arc", "HashMap", "HashSet", "Path", "PathBuf"],
                constants: ["true", "false", "self", "Self", "super", "Some", "None", "Ok", "Err"],
                caseInsensitive: false,
                slashSlashComments: true, slashStarComments: true, nestedBlockComments: true,
                hashComments: false, dashDashComments: false,
                singleQuotedStrings: true, singleQuoteDoubledEscape: false,
                backtickRawStrings: false, backtickTemplateStrings: false,
                tripleDoubleStrings: false, tripleSingleStrings: false,
                stringPrefixes: [0x62, 0x72], // b, r
                cPreprocessor: false, atAttributes: false, rustAttributesAndLifetimes: true,
                shellSyntax: false, jsonMode: false, yamlMode: false, makeMode: false,
                pascalCaseTypes: true
            )

        case .python:
            return Spec(
                keywords: ["and", "as", "assert", "async", "await", "break", "case", "class", "continue", "def", "del",
                           "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is",
                           "lambda", "match", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while",
                           "with", "yield"],
                types: ["int", "float", "str", "bool", "bytes", "list", "dict", "set", "tuple", "object", "type",
                        "Any", "Optional", "Union", "List", "Dict", "Set", "Tuple", "Callable", "Iterable", "Sequence"],
                constants: ["True", "False", "None", "self", "cls"],
                caseInsensitive: false,
                slashSlashComments: false, slashStarComments: false, nestedBlockComments: false,
                hashComments: true, dashDashComments: false,
                singleQuotedStrings: true, singleQuoteDoubledEscape: false,
                backtickRawStrings: false, backtickTemplateStrings: false,
                tripleDoubleStrings: true, tripleSingleStrings: true,
                stringPrefixes: [0x66, 0x46, 0x72, 0x52, 0x62, 0x42, 0x75, 0x55], // f, r, b, u
                cPreprocessor: false, atAttributes: true, rustAttributesAndLifetimes: false,
                shellSyntax: false, jsonMode: false, yamlMode: false, makeMode: false,
                pascalCaseTypes: false
            )

        case .javascript:
            return Spec(
                keywords: ["async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
                           "default", "delete", "do", "else", "export", "extends", "finally", "for", "from", "function",
                           "if", "import", "in", "instanceof", "let", "new", "of", "return", "static", "switch",
                           "throw", "try", "typeof", "var", "void", "while", "with", "yield"],
                types: ["Array", "Object", "String", "Number", "Boolean", "Promise", "Map", "Set", "Date", "RegExp",
                        "Error", "Symbol", "BigInt"],
                constants: ["true", "false", "null", "undefined", "NaN", "Infinity", "this", "super"],
                caseInsensitive: false,
                slashSlashComments: true, slashStarComments: true, nestedBlockComments: false,
                hashComments: false, dashDashComments: false,
                singleQuotedStrings: true, singleQuoteDoubledEscape: false,
                backtickRawStrings: false, backtickTemplateStrings: true,
                tripleDoubleStrings: false, tripleSingleStrings: false,
                stringPrefixes: [],
                cPreprocessor: false, atAttributes: false, rustAttributesAndLifetimes: false,
                shellSyntax: false, jsonMode: false, yamlMode: false, makeMode: false,
                pascalCaseTypes: false
            )

        case .typescript:
            return Spec(
                keywords: ["abstract", "as", "asserts", "async", "await", "break", "case", "catch", "class", "const",
                           "continue", "debugger", "declare", "default", "delete", "do", "else", "enum", "export",
                           "extends", "finally", "for", "from", "function", "if", "implements", "import", "in",
                           "infer", "instanceof", "interface", "is", "keyof", "let", "module", "namespace", "new",
                           "of", "override", "private", "protected", "public", "readonly", "return", "satisfies",
                           "static", "switch", "throw", "try", "type", "typeof", "var", "while", "with", "yield"],
                types: ["any", "unknown", "never", "void", "boolean", "number", "string", "bigint", "symbol", "object",
                        "Array", "Promise", "Record", "Partial", "Required", "Readonly", "Pick", "Omit", "Map", "Set"],
                constants: ["true", "false", "null", "undefined", "NaN", "Infinity", "this", "super"],
                caseInsensitive: false,
                slashSlashComments: true, slashStarComments: true, nestedBlockComments: false,
                hashComments: false, dashDashComments: false,
                singleQuotedStrings: true, singleQuoteDoubledEscape: false,
                backtickRawStrings: false, backtickTemplateStrings: true,
                tripleDoubleStrings: false, tripleSingleStrings: false,
                stringPrefixes: [],
                cPreprocessor: false, atAttributes: true, rustAttributesAndLifetimes: false,
                shellSyntax: false, jsonMode: false, yamlMode: false, makeMode: false,
                pascalCaseTypes: true
            )

        case .bash:
            return Spec(
                keywords: ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac",
                           "in", "function", "select", "time", "return", "exit", "break", "continue", "local",
                           "export", "readonly", "declare", "typeset", "unset", "source", "set", "shift", "trap",
                           "begin", "end", "and", "or", "not", "switch"],
                types: [],
                constants: ["true", "false"],
                caseInsensitive: false,
                slashSlashComments: false, slashStarComments: false, nestedBlockComments: false,
                hashComments: true, dashDashComments: false,
                singleQuotedStrings: true, singleQuoteDoubledEscape: false,
                backtickRawStrings: false, backtickTemplateStrings: false,
                tripleDoubleStrings: false, tripleSingleStrings: false,
                stringPrefixes: [],
                cPreprocessor: false, atAttributes: false, rustAttributesAndLifetimes: false,
                shellSyntax: true, jsonMode: false, yamlMode: false, makeMode: false,
                pascalCaseTypes: false
            )

        case .json:
            return Spec(
                keywords: [],
                types: [],
                constants: ["true", "false", "null"],
                caseInsensitive: false,
                slashSlashComments: true, slashStarComments: true, nestedBlockComments: false,
                hashComments: false, dashDashComments: false,
                singleQuotedStrings: false, singleQuoteDoubledEscape: false,
                backtickRawStrings: false, backtickTemplateStrings: false,
                tripleDoubleStrings: false, tripleSingleStrings: false,
                stringPrefixes: [],
                cPreprocessor: false, atAttributes: false, rustAttributesAndLifetimes: false,
                shellSyntax: false, jsonMode: true, yamlMode: false, makeMode: false,
                pascalCaseTypes: false
            )

        case .yaml:
            return Spec(
                keywords: [], types: [], constants: [],
                caseInsensitive: true,
                slashSlashComments: false, slashStarComments: false, nestedBlockComments: false,
                hashComments: true, dashDashComments: false,
                singleQuotedStrings: true, singleQuoteDoubledEscape: true,
                backtickRawStrings: false, backtickTemplateStrings: false,
                tripleDoubleStrings: false, tripleSingleStrings: false,
                stringPrefixes: [],
                cPreprocessor: false, atAttributes: false, rustAttributesAndLifetimes: false,
                shellSyntax: false, jsonMode: false, yamlMode: true, makeMode: false,
                pascalCaseTypes: false
            )

        case .sql:
            return Spec(
                keywords: ["select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create",
                           "table", "index", "view", "alter", "drop", "join", "inner", "left", "right", "full", "outer",
                           "cross", "on", "as", "and", "or", "not", "in", "is", "like", "between", "exists", "case",
                           "when", "then", "else", "end", "group", "by", "having", "order", "asc", "desc", "limit",
                           "offset", "distinct", "union", "all", "with", "primary", "key", "foreign", "references",
                           "unique", "default", "check", "constraint", "begin", "commit", "rollback", "transaction",
                           "pragma", "autoincrement", "if"],
                types: ["integer", "int", "bigint", "smallint", "text", "varchar", "char", "blob", "real", "float",
                        "double", "numeric", "decimal", "boolean", "bool", "date", "time", "timestamp", "json", "jsonb"],
                constants: ["null", "true", "false"],
                caseInsensitive: true,
                slashSlashComments: false, slashStarComments: true, nestedBlockComments: false,
                hashComments: false, dashDashComments: true,
                singleQuotedStrings: true, singleQuoteDoubledEscape: true,
                backtickRawStrings: false, backtickTemplateStrings: false,
                tripleDoubleStrings: false, tripleSingleStrings: false,
                stringPrefixes: [],
                cPreprocessor: false, atAttributes: false, rustAttributesAndLifetimes: false,
                shellSyntax: false, jsonMode: false, yamlMode: false, makeMode: false,
                pascalCaseTypes: false
            )

        case .make:
            return Spec(
                keywords: [], types: [], constants: [],
                caseInsensitive: false,
                slashSlashComments: false, slashStarComments: false, nestedBlockComments: false,
                hashComments: true, dashDashComments: false,
                singleQuotedStrings: true, singleQuoteDoubledEscape: false,
                backtickRawStrings: false, backtickTemplateStrings: false,
                tripleDoubleStrings: false, tripleSingleStrings: false,
                stringPrefixes: [],
                cPreprocessor: false, atAttributes: false, rustAttributesAndLifetimes: false,
                shellSyntax: false, jsonMode: false, yamlMode: false, makeMode: true,
                pascalCaseTypes: false
            )
        }
    }
}
