import Foundation

/// Logical text operations use UTF-16 ranges for AppKit, stepping by composed
/// characters so the Veda editing rules also work with emoji and combining marks.
enum TaskEditorText {
    struct Line {
        let range: NSRange
        let contentEnd: Int
    }

    static func line(_ text: NSString, at point: Int) -> Line {
        var start = 0, end = 0, contentEnd = 0
        text.getLineStart(&start, end: &end, contentsEnd: &contentEnd,
                          for: NSRange(location: min(max(0, point), text.length), length: 0))
        return Line(range: NSRange(location: start, length: end - start), contentEnd: contentEnd)
    }

    static func lines(_ text: NSString, at point: Int, count: Int) -> (range: NSRange, contentEnd: Int) {
        let first = line(text, at: point)
        var last = first
        for _ in 1..<max(1, count) {
            let next = NSMaxRange(last.range)
            if last.range.length == 0 || (next == text.length && last.contentEnd == next) { break }
            last = line(text, at: next)
        }
        return (NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location), last.contentEnd)
    }

    static func deletionRange(_ text: NSString, lines: (range: NSRange, contentEnd: Int)) -> NSRange {
        if lines.contentEnd == text.length, lines.range.location > 0 {
            let start = line(text, at: lines.range.location - 1).contentEnd
            return NSRange(location: start, length: text.length - start)
        }
        return lines.range
    }

    static func lastCharacter(_ text: NSString, at point: Int) -> Int {
        let row = line(text, at: point)
        return row.contentEnd > row.range.location
            ? text.rangeOfComposedCharacterSequence(at: row.contentEnd - 1).location : row.range.location
    }

    static func horizontal(_ text: NSString, at point: Int, forward: Bool) -> Int {
        let row = line(text, at: point)
        if forward {
            guard point < row.contentEnd else { return lastCharacter(text, at: point) }
            return min(NSMaxRange(text.rangeOfComposedCharacterSequence(at: point)), lastCharacter(text, at: point))
        }
        return point > row.range.location ? text.rangeOfComposedCharacterSequence(at: point - 1).location : point
    }

    static func indentation(_ text: NSString, at point: Int) -> String {
        let row = line(text, at: point)
        var end = row.range.location
        while end < row.contentEnd, [9, 32].contains(text.character(at: end)) { end += 1 }
        return text.substring(with: NSRange(location: row.range.location, length: end - row.range.location))
    }

    static func kind(_ text: NSString, at point: Int, underscore: Bool = true) -> Int {
        guard point < text.length else { return 0 }
        let value = text.substring(with: text.rangeOfComposedCharacterSequence(at: point))
        if value.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) { return 0 }
        if (underscore && value == "_") || value.unicodeScalars.allSatisfy({
            CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0)
        }) { return 1 }
        return 2
    }

    static func word(_ text: NSString, at point: Int, whole: Bool, trailingSpace: Bool) -> NSRange {
        let row = line(text, at: point)
        guard point < row.contentEnd else { return NSRange(location: point, length: 0) }
        let category = kind(text, at: point)
        var start = point
        if whole, category == 1 {
            while start > row.range.location {
                let previous = text.rangeOfComposedCharacterSequence(at: start - 1).location
                if kind(text, at: previous) != 1 { break }
                start = previous
            }
        }
        var end = NSMaxRange(text.rangeOfComposedCharacterSequence(at: point))
        if category != 2 {
            while end < row.contentEnd, kind(text, at: end) == category {
                end = NSMaxRange(text.rangeOfComposedCharacterSequence(at: end))
            }
        }
        if trailingSpace {
            while end < row.contentEnd, kind(text, at: end) == 0 {
                end = NSMaxRange(text.rangeOfComposedCharacterSequence(at: end))
            }
        }
        return NSRange(location: start, length: end - start)
    }

    static func words(_ text: NSString, at point: Int, count: Int, whole: Bool, trailingSpace: Bool) -> NSRange {
        let first = word(text, at: point, whole: whole, trailingSpace: trailingSpace)
        guard first.length > 0 else { return first }
        var end = NSMaxRange(first)
        for _ in 1..<max(1, count) {
            var next = end
            while next < text.length, kind(text, at: next) == 0 {
                next = NSMaxRange(text.rangeOfComposedCharacterSequence(at: next))
            }
            guard next < text.length else { break }
            end = NSMaxRange(word(text, at: next, whole: false, trailingSpace: trailingSpace))
        }
        return NSRange(location: first.location, length: end - first.location)
    }

    static func nextWord(_ text: NSString, at point: Int, underscore: Bool) -> Int {
        guard point < text.length else { return point }
        let row = line(text, at: point)
        let category = kind(text, at: point, underscore: underscore)
        var end = NSMaxRange(text.rangeOfComposedCharacterSequence(at: point))
        if category == 1 {
            while end < row.contentEnd, kind(text, at: end, underscore: underscore) == 1 {
                end = NSMaxRange(text.rangeOfComposedCharacterSequence(at: end))
            }
        }
        if category != 0, end == row.contentEnd, point < lastCharacter(text, at: point) {
            let next = NSMaxRange(row.range)
            let hasNextContent = next < text.length && !text.substring(with: line(text, at: next).range)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if end == text.length || hasNextContent { return lastCharacter(text, at: point) }
        }
        while end < text.length, kind(text, at: end, underscore: underscore) == 0 {
            end = NSMaxRange(text.rangeOfComposedCharacterSequence(at: end))
        }
        return end < text.length ? end : point
    }

    static func previousWord(_ text: NSString, at point: Int, underscore: Bool) -> Int {
        guard point > 0 else { return 0 }
        var start = text.rangeOfComposedCharacterSequence(at: point - 1).location
        while start > 0, kind(text, at: start, underscore: underscore) == 0 {
            start = text.rangeOfComposedCharacterSequence(at: start - 1).location
        }
        let row = line(text, at: start)
        while start > row.range.location, kind(text, at: start, underscore: underscore) != 1 {
            start = text.rangeOfComposedCharacterSequence(at: start - 1).location
        }
        while start > row.range.location {
            let previous = text.rangeOfComposedCharacterSequence(at: start - 1).location
            if kind(text, at: previous, underscore: underscore) != 1 { break }
            start = previous
        }
        return start
    }
}
