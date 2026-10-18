import Foundation

enum ScreenOCRMapping {
    private struct Unit {
        let range: NSRange
        let text: String?
        let formula: Bool
    }
    static func document(recognized: String, visual: ScreenTextDocument) throws -> ScreenTextDocument {
        let segments = try ScreenMath.segments(paragraphs(recognized, visual: visual.text))
        let text = segments.map(\.text).joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 100_000 else {
            throw NarrationText.Invalid("No readable screen text found.")
        }
        var units: [Unit] = []
        for segment in segments {
            if segment.formula { units.append(Unit(range: segment.range, text: nil, formula: true)) }
            else {
                units += ScreenTextRelocation.words(segment.text).map {
                    Unit(range: NSRange(location: segment.range.location + $0.range.location, length: $0.range.length), text: $0.text, formula: false)
                }
            }
        }
        let words = ScreenTextRelocation.words(visual.text)
        let n = units.count, m = words.count
        // Alignment is only against the captured region, never against a whole PDF
        // or unrelated screen contents. Bound work for abnormally large selections.
        guard (n + 1) * (m + 1) <= 4_000_000 else { throw NarrationText.Invalid("Select a smaller screen area for highlighting.") }
        var table = [UInt16](repeating: 0, count: (n + 1) * (m + 1))
        if n > 0, m > 0 {
            for i in (0..<n).reversed() {
                for j in (0..<m).reversed() {
                    table[i * (m + 1) + j] = units[i].text == words[j].text
                        ? 1 + table[(i + 1) * (m + 1) + j + 1]
                        : max(table[(i + 1) * (m + 1) + j], table[i * (m + 1) + j + 1])
                }
            }
        }
        var anchors: [(Int, Int)] = [], i = 0, j = 0
        while i < n, j < m {
            if units[i].text == words[j].text { anchors.append((i, j)); i += 1; j += 1 }
            else if table[(i + 1) * (m + 1) + j] >= table[i * (m + 1) + j + 1] { i += 1 }
            else { j += 1 }
        }
        var links = anchors.map { ScreenTextRangeLink(range: units[$0.0].range, visualRange: words[$0.1].range) }
        // A formula's whole observed region represents its spoken expansion.
        // This avoids inventing word boxes for "fraction", "power", or "epsilon".
        let boundaries = [(-1, -1)] + anchors + [(n, m)]
        for (left, right) in zip(boundaries, boundaries.dropFirst()) {
            let source = (left.0 + 1)..<right.0, target = (left.1 + 1)..<right.1
            guard !source.isEmpty, !target.isEmpty else { continue }
            if source.contains(where: { units[$0].formula }) {
                let range = NSRange(location: words[target.lowerBound].range.location,
                    length: NSMaxRange(words[target.upperBound - 1].range) - words[target.lowerBound].range.location)
                for index in source where units[index].formula || (units[index].text?.count ?? 0) <= 2 {
                    links.append(ScreenTextRangeLink(range: units[index].range, visualRange: range))
                }
            } else if source.count == 1, target.count == 2,
                target.map({ words[$0].text }).joined() == units[source.lowerBound].text {
                for index in target { links.append(ScreenTextRangeLink(range: units[source.lowerBound].range, visualRange: words[index].range)) }
            }
        }
        var spans: [ScreenTextSpan] = []
        for link in links {
            spans += visual.spans.filter { NSIntersectionRange($0.range, link.visualRange).length > 0 }.map {
                ScreenTextSpan(range: link.range, box: $0.box)
            }
        }
        return ScreenTextDocument(text: text, spans: spans, frame: visual.frame, sourceWindow: visual.sourceWindow,
            tracking: ScreenTextTracking(text: visual.text, spans: visual.spans, links: links),
            formulas: segments.filter(\.formula).map(\.range))
    }

    private static func paragraphs(_ recognized: String, visual: String) -> String {
        var text = recognized.replacingOccurrences(of: #"(?m)^#{1,6}[ \t]+"#, with: "", options: .regularExpression)
        let words = ScreenTextRelocation.words(visual)
        let breaks = try! NSRegularExpression(pattern: #"\n\n+"#)
        for boundary in breaks.matches(in: visual, range: NSRange(location: 0, length: visual.utf16.count)) {
            guard let before = words.last(where: { NSMaxRange($0.range) <= boundary.range.location }),
                  let after = words.first(where: { $0.range.location >= NSMaxRange(boundary.range) }) else { continue }
            // Transfer only uniquely anchored layout breaks. Model line wrapping
            // must not remove the heading/paragraph pauses already visible on screen.
            let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: before.text)
                + #"[.!?:;]?(\s+)"# + NSRegularExpression.escapedPattern(for: after.text) + #"(?![\p{L}\p{N}])"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count))
            if matches.count == 1, let range = Range(matches[0].range(at: 1), in: text) { text.replaceSubrange(range, with: "\n\n") }
        }
        return text
    }
}
