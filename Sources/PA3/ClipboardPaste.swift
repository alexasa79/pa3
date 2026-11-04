import Foundation
import NaturalLanguage

/// Terminal punctuation, rather than word count, distinguishes a sentence from
/// a fragment. Closing quotes and brackets can follow the sentence stop.
func clipboardPasteIsSentence(_ text: String) -> Bool {
    let end = text.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’»)]}"))
    guard let last = end.last else { return false }
    return ".!?。！？…؟".contains(last)
}

/// Only touch the punctuation immediately before an inline fragment. Periods
/// belonging to abbreviations, initials, identifiers, or numbers are ambiguous.
func clipboardFragmentPrefix(_ text: String) -> String {
    var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let last = result.last, ".,;:!?。！？؟".contains(last) else { return result }
    if last == "." {
        let stem = String(result.dropLast())
        let word = stem.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        let hasCase = word.lowercased() != word.uppercased()
        if isCleanupAbbreviation(word) || (hasCase && (word.count <= 1 || word == word.uppercased())) ||
            word.rangeOfCharacter(from: .decimalDigits) != nil { return result }
    }
    while let last = result.last, ".,;:!?。！？؟".contains(last) { result.removeLast() }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

func clipboardSentencePrefix(_ text: String) -> String {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !clipboardPasteIsSentence(text) else { return text }
    return text.trimmingCharacters(in: CharacterSet(charactersIn: ",;:")) + "."
}

/// Remove a sentence-start capital at a fragment join. Local linguistic tags
/// protect recognized names; explicit casing protects acronyms and identifiers.
func clipboardContinuationText(_ text: String) -> String {
    let opening = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“‘([{«"))
    guard let start = text.firstIndex(where: { character in
        !character.unicodeScalars.allSatisfy { opening.contains($0) }
    }), text[start].isLetter else { return text }
    let end = text[start...].firstIndex(where: { !$0.isLetter }) ?? text.endIndex
    let word = String(text[start..<end])
    let lower = word.lowercased()
    // The tagger treats these names as modal verbs even in “Will can help”.
    let nextWord = text[end...].split(whereSeparator: { !$0.isLetter }).first?.lowercased() ?? ""
    let ambiguousName = ["Will", "May"].contains(word) &&
        ["can", "could", "is", "was", "has", "had", "said", "says"].contains(nextWord)
    guard let first = lower.first, word == first.uppercased() + lower.dropFirst(),
          word != lower, (word != word.uppercased() || word == "A"),
          !ambiguousName else { return text }

    let tagger = NLTagger(tagSchemes: [.nameTypeOrLexicalClass])
    tagger.string = text
    let (tag, _) = tagger.tag(at: start, unit: .word, scheme: .nameTypeOrLexicalClass)
    if tag == .personalName || tag == .placeName || tag == .organizationName { return text }
    var result = text
    result.replaceSubrange(start..<end, with: lower)
    return result
}
