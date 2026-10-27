import Foundation

struct NarrationIdentifier {
    // Explicit letter names keep Qwen from treating a one-letter part as a consonant sound.
    private static let letterNames = [
        "a": "ay", "b": "bee", "c": "see", "d": "dee", "e": "ee", "f": "ef",
        "g": "jee", "h": "aitch", "i": "eye", "j": "jay", "k": "kay", "l": "ell",
        "m": "em", "n": "en", "o": "oh", "p": "pee", "q": "cue", "r": "ar",
        "s": "ess", "t": "tee", "u": "you", "v": "vee", "w": "double you",
        "x": "ex", "y": "why", "z": "zee"
    ]
    private let names: NSRegularExpression

    init() throws {
        names = try NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}_]+"#)
    }

    func pronounce(_ token: String) -> String {
        guard token.contains("_") else { return token }
        var body = token[...]
        while let last = body.last, ")]}.:!?,”’".contains(last) { body.removeLast() }
        // Paths are handled separately. Avoid rewriting URLs, email addresses,
        // or ambiguous dotted names as if they were standalone identifiers.
        guard !body.contains("/"), !body.contains("."), !body.contains("@") else { return token }
        let source = token as NSString
        let spoken = NSMutableString(string: token)
        for match in names.matches(in: token, range: NSRange(location: 0, length: source.length)).reversed() {
            let name = source.substring(with: match.range)
            guard name.contains("_"), let first = name.first, first.isLetter || first == "_",
                  name.contains(where: \.isLetter) else { continue }
            let words = name.components(separatedBy: "_").map { Self.letterNames[$0.lowercased()] ?? $0 }
            let replacement = words.joined(separator: " underscore ")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            spoken.replaceCharacters(in: match.range, with: replacement)
        }
        return spoken as String
    }
}
