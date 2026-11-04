import Foundation

/// Repairs only the new join made by a deletion, never the whole transcript.
func cleanupDeletion(words input: [String], paragraphs: [Int], at boundary: Int, deletedParagraph: Int) -> (words: [String], paragraphs: [Int]) {
    guard input.count == paragraphs.count, boundary >= 0, boundary < input.count,
          paragraphs[boundary] == deletedParagraph else {
        return (input, normalizeParagraphs(paragraphs))
    }
    var words = input
    var paras = paragraphs
    var join = boundary
    let separators: Set<String> = [",", ";", ":"]
    let stops: Set<String> = [".", "!", "?"]

    // Remove an orphan separator at a paragraph start, or a newly adjacent
    // separator next to a sentence stop, or a duplicate period at the new join.
    // Match individual periods so existing ellipses, quotes and ?! stay intact.
    while join < words.count && paras[join] == deletedParagraph {
        let paragraphStart = join == 0 || paras[join - 1] != paras[join]
        if paragraphStart && separators.contains(words[join]) {
            words.remove(at: join)
            paras.remove(at: join)
        } else if !paragraphStart && words[join - 1] == "." && words[join] == "." {
            words.remove(at: join)
            paras.remove(at: join)
        } else if !paragraphStart && separators.contains(words[join]) &&
                    (stops.contains(words[join - 1]) || words[join - 1] == words[join]) {
            words.remove(at: join)
            paras.remove(at: join)
        } else if !paragraphStart && separators.contains(words[join - 1]) && stops.contains(words[join]) {
            words.remove(at: join - 1)
            paras.remove(at: join - 1)
            join -= 1
            break
        } else {
            break
        }
    }

    guard join < words.count, paras[join] == deletedParagraph else { return (words, normalizeParagraphs(paras)) }
    let paragraphStart = join == 0 || paras[join - 1] != paras[join]
    var sentenceStart = paragraphStart
    if !paragraphStart && stops.contains(words[join - 1]) {
        sentenceStart = true
        if words[join - 1] == ".", join >= 2 {
            let previous = words[join - 2]
            // A period after an initial, acronym, number, or abbreviation is
            // ambiguous. Favor preserving the user's casing.
            sentenceStart = !isCleanupAbbreviation(previous) &&
                previous.count > 1 && previous != previous.uppercased() &&
                !previous.contains(".") && previous.rangeOfCharacter(from: .decimalDigits) == nil
        }
    }
    let word = words[join]
    // Capitalize plain lowercase words only; preserve iPhone, NASA, e.g., paths,
    // identifiers and other non-word tokens. A dotted abbreviation's last period
    // can live in the next token because punctuation is independently selectable.
    if sentenceStart, word == word.lowercased(), !isCleanupAbbreviation(word),
       word.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) || CharacterSet.nonBaseCharacters.contains($0) }),
       let first = word.first, first.lowercased() != first.uppercased() {
        words[join] = first.uppercased() + word.dropFirst()
    }
    return (words, normalizeParagraphs(paras))
}

func isCleanupAbbreviation(_ word: String) -> Bool {
    let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "eg", "ie",
        "e.g", "i.e", "a.m", "p.m", "approx", "dept", "fig", "no", "inc", "ltd",
        "т.д", "т.п", "т.е", "г", "ул", "д", "стр"
    ]
    return abbreviations.contains(word.lowercased()) || word.contains(".")
}
