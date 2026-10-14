import Foundation

/// Maps Foundation's sentence boundaries back to selectable transcript tokens.
/// A paragraph boundary always ends the editing range, even without punctuation.
func sentenceWordRange(words: [String], paragraphs: [Int], containing index: Int) -> ClosedRange<Int>? {
    guard words.indices.contains(index), paragraphs.count == words.count else { return nil }
    let paragraph = paragraphs[index]
    var first = index, last = index
    while first > 0 && paragraphs[first - 1] == paragraph { first -= 1 }
    while last + 1 < words.count && paragraphs[last + 1] == paragraph { last += 1 }

    var text = ""
    var offsets: [NSRange] = []
    var offset = 0
    for i in first...last {
        if i > first && shouldInsertSpace(before: words[i], after: words[i - 1]) {
            text += " "
            offset += 1
        }
        let length = words[i].utf16.count
        offsets.append(NSRange(location: offset, length: length))
        text += words[i]
        offset += length
    }
    let location = offsets[index - first].location
    var sentence: NSRange?
    text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.bySentences, .localized]) { _, range, _, stop in
        let candidate = NSRange(range, in: text)
        if NSLocationInRange(location, candidate) {
            sentence = candidate
            stop = true
        }
    }
    guard let sentence,
          let start = offsets.firstIndex(where: { NSMaxRange($0) > sentence.location }),
          let end = offsets.lastIndex(where: { $0.location < NSMaxRange(sentence) }) else { return nil }
    return (first + start)...(first + end)
}
