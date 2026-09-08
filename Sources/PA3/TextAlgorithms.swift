import Foundation

let blankAudioToken = "[BLANK_AUDIO]"

func splitWords(_ text: String) -> [String] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return []
    }
    return trimmed.split(whereSeparator: { $0.isWhitespace }).flatMap { splitWordAndPunctuation(String($0)) }
}

func splitWordAndPunctuation(_ token: String) -> [String] {
    if token.isEmpty {
        return []
    }
    let chars = Array(token)
    var trailingStart = chars.count
    while trailingStart > 0, String(chars[trailingStart - 1]).rangeOfCharacter(from: .punctuationCharacters) != nil {
        trailingStart -= 1
    }
    if trailingStart == chars.count || trailingStart == 0 {
        return [token]
    }
    return [String(chars[..<trailingStart]), String(chars[trailingStart...])]
}

func splitWordsAndParagraphs(_ text: String) -> ([String], [Int]) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return ([], [])
    }
    var words: [String] = []
    var paragraphs: [Int] = []
    for (paraIdx, part) in trimmed.components(separatedBy: "\n\n").enumerated() {
        let partWords = splitWords(part)
        for word in partWords {
            words.append(word)
            paragraphs.append(paraIdx)
        }
    }
    return (words, normalizeParagraphs(paragraphs))
}

func normalizeParagraphs(_ paragraphs: [Int]) -> [Int] {
    if paragraphs.isEmpty {
        return []
    }
    var normalized: [Int] = []
    var current = -1
    var previous: Int?
    for value in paragraphs {
        if previous == nil || value != previous {
            current += 1
            previous = value
        }
        normalized.append(current)
    }
    return normalized
}

func filterBlankAudioWords(words: [String], paragraphs: [Int]) -> ([String], [Int]) {
    var filteredWords: [String] = []
    var filteredParagraphs: [Int] = []
    for (index, word) in words.enumerated() where word != blankAudioToken {
        filteredWords.append(word)
        if index < paragraphs.count {
            filteredParagraphs.append(paragraphs[index])
        }
    }
    return (filteredWords, normalizeParagraphs(filteredParagraphs))
}

func buildTextFromWordData(words: [String], paragraphs: [Int]) -> String {
    if words.isEmpty {
        return ""
    }
    var normalized = paragraphs
    if normalized.count != words.count {
        normalized = Array(repeating: 0, count: words.count)
    }

    var result: [String] = []
    var currentPara = normalized[0]
    var paraWords: [String] = []
    for (index, word) in words.enumerated() {
        if normalized[index] != currentPara {
            result.append(joinParagraphWords(paraWords))
            paraWords.removeAll(keepingCapacity: true)
            currentPara = normalized[index]
        }
        paraWords.append(word)
    }
    result.append(joinParagraphWords(paraWords))
    return result.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

func joinParagraphWords(_ words: [String]) -> String {
    var result = ""
    for (index, word) in words.enumerated() {
        if index > 0, shouldInsertSpace(before: word, after: words[index - 1]) {
            result += " "
        }
        result += word
    }
    return result
}

func shouldInsertSpace(before word: String, after previous: String) -> Bool {
    if word == "/" {
        return hasAlphanumeric(previous)
    }
    if previous == "/" {
        return false
    }
    return hasAlphanumeric(word)
}

func hasAlphanumeric(_ string: String) -> Bool {
    string.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
}

func appendText(_ left: String, _ right: String) -> String {
    let l = left.trimmingCharacters(in: .whitespacesAndNewlines)
    let r = right.trimmingCharacters(in: .whitespacesAndNewlines)
    if l.isEmpty { return r }
    if r.isEmpty { return l }
    return hasAlphanumeric(r) ? "\(l) \(r)" : "\(l)\(r)"
}

func joinText(_ left: String, _ right: String) -> (text: String, stableRunes: Int) {
    let l = left.trimmingCharacters(in: .whitespacesAndNewlines)
    let r = right.trimmingCharacters(in: .whitespacesAndNewlines)
    if l.isEmpty { return (r, 0) }
    if r.isEmpty { return (l, l.count) }
    if hasAlphanumeric(r) {
        return ("\(l) \(r)", l.count + 1)
    }
    return ("\(l)\(r)", l.count)
}

func endsSentence(_ word: String) -> Bool {
    let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: ")]}\"'"))
    guard let last = trimmed.last else { return false }
    return last == "." || last == "!" || last == "?"
}

func buildText(_ tokens: [String]) -> String {
    var result = ""
    var previous = ""
    for token in tokens {
        let word = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if word.isEmpty {
            continue
        }
        if !result.isEmpty, shouldInsertSpace(before: word, after: previous) {
            result += " "
        }
        result += word
        previous = word
    }
    return result
}

func wordIndexForRunes(words: [String], stableRunes: Int) -> Int {
    if stableRunes <= 0 || words.isEmpty {
        return 0
    }
    var runesSeen = 0
    for (index, word) in words.enumerated() {
        // Split-off punctuation such as the "." of "key." has no space before it in the text.
        if index > 0, shouldInsertSpace(before: word, after: words[index - 1]) {
            runesSeen += 1
        }
        runesSeen += word.count
        if runesSeen > stableRunes {
            return index
        }
    }
    return words.count
}

extension ClosedRange where Bound == Int {
    func clamped(_ value: Int) -> Int {
        Swift.min(upperBound, Swift.max(lowerBound, value))
    }
}
