import Foundation

func nextWordCapitalization(_ word: String) -> String {
    let lower = word.lowercased()
    let upper = word.uppercased()
    guard lower != upper else { return word }

    // Uppercase wins when the capitalized and uppercase forms coincide ("I").
    if word == upper { return lower }
    guard let first = lower.firstIndex(where: { $0.lowercased() != $0.uppercased() }) else {
        return word
    }
    let afterFirst = lower.index(after: first)
    let capitalized = String(lower[..<first]) + lower[first].uppercased() + String(lower[afterFirst...])
    if word == lower { return capitalized }
    if word == capitalized { return upper }
    return lower
}
