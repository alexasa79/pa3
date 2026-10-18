import Foundation

/// Converts recognized notation to speech while retaining the source formula as
/// one visual unit. Every spoken word in a formula shares its actual screen boxes.
enum ScreenMath {
    struct Segment {
        let text: String
        let original: String
        let formula: Bool
        var range: NSRange = NSRange()
    }
    static let greek: [String: String] = [
        "alpha": "alpha", "beta": "beta", "gamma": "gamma", "delta": "delta", "epsilon": "epsilon", "varepsilon": "epsilon",
        "zeta": "zeta", "eta": "eta", "theta": "theta", "vartheta": "theta", "iota": "iota", "kappa": "kappa",
        "lambda": "lambda", "mu": "mu", "nu": "nu", "xi": "xi", "omicron": "omicron", "pi": "pi", "varpi": "pi",
        "rho": "rho", "varrho": "rho", "sigma": "sigma", "varsigma": "sigma", "tau": "tau", "upsilon": "upsilon",
        "phi": "phi", "varphi": "phi", "chi": "chi", "psi": "psi", "omega": "omega"
    ]
    static let glyphs: [Character: String] = Dictionary(uniqueKeysWithValues:
        zip(Array("αβγδεζηθικλμνξοπρστυφχψω"), ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa", "lambda", "mu", "nu", "xi", "omicron", "pi", "rho", "sigma", "tau", "upsilon", "phi", "chi", "psi", "omega"]))
        .merging(["ϵ": "epsilon", "ϑ": "theta", "ς": "sigma", "ϕ": "phi"], uniquingKeysWith: { a, _ in a })
    private static let letters = ["a": "ay", "b": "bee", "c": "see", "d": "dee", "e": "ee", "f": "ef", "g": "jee",
        "h": "aitch", "i": "eye", "j": "jay", "k": "kay", "l": "ell", "m": "em", "n": "en", "o": "oh",
        "p": "pee", "q": "cue", "r": "ar", "s": "ess", "t": "tee", "u": "you", "v": "vee", "w": "double you", "x": "ex", "y": "why", "z": "zee"]
    private static let operators = ["times": "times", "cdot": "times", "div": "divided by", "pm": "plus or minus",
        "le": "less than or equal to", "leq": "less than or equal to", "ge": "greater than or equal to", "geq": "greater than or equal to",
        "ne": "not equal to", "neq": "not equal to", "approx": "approximately equals", "infty": "infinity", "to": "approaches",
        "in": "in", "notin": "not in", "ldots": "dot dot dot", "dots": "dot dot dot"]

    static func segments(_ input: String) throws -> [Segment] {
        let patterns = #"\\\([\s\S]*?\\\)|\\\[[\s\S]*?\\\]|\$\$[\s\S]*?\$\$|\$[^$\n]+\$(?!\d)|\d+(?:\.\d+)?\s*/\s*(?:\d+(?:\.\d+)?|[α-ωϵϑϕ])|[α-ωΑ-Ωϵϑϕ]|[=≥≤≠≈]"#
        let regex = try NSRegularExpression(pattern: patterns)
        let plain = try NSRegularExpression(pattern: #"\s+|\S+"#)
        let source = input as NSString
        var result: [Segment] = [], cursor = 0
        func appendPlain(_ range: NSRange) {
            let text = source.substring(with: range) as NSString
            for token in plain.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
                let value = text.substring(with: token.range)
                result.append(Segment(text: value, original: value, formula: false))
            }
        }
        for match in regex.matches(in: input, range: NSRange(location: 0, length: source.length)) {
            appendPlain(NSRange(location: cursor, length: match.range.location - cursor))
            let raw = source.substring(with: match.range)
            var value = raw
            if raw.hasPrefix("\\(") || raw.hasPrefix("\\[") || raw.hasPrefix("$$") { value = String(raw.dropFirst(2).dropLast(2)) }
            else if raw.hasPrefix("$") { value = String(raw.dropFirst().dropLast()) }
            var parser = Parser(value)
            let spoken = try parser.parse()
            let before = result.last?.text.last
            let after = NSMaxRange(match.range) < source.length ? source.substring(from: NSMaxRange(match.range)).first : nil
            let left = before.map { $0.isLetter || $0.isNumber } == true ? " " : ""
            let right = after.map { $0.isLetter || $0.isNumber } == true ? " " : ""
            result.append(Segment(text: left + spoken + right, original: raw, formula: true))
            cursor = NSMaxRange(match.range)
        }
        appendPlain(NSRange(location: cursor, length: source.length - cursor))
        if result.contains(where: { !$0.formula && ($0.text.contains("\\(") || $0.text.contains("\\[") || $0.text.contains("$$")
            || $0.text.range(of: #"\\(?:frac|varepsilon)\b"#, options: .regularExpression) != nil) }) {
            throw NarrationText.Invalid("The recognized formula is incomplete. Try capturing it again.")
        }
        var offset = 0
        for i in result.indices {
            result[i].range = NSRange(location: offset, length: result[i].text.utf16.count)
            offset += result[i].range.length
        }
        return result
    }

    private struct Parser {
        var chars: [Character]
        var index = 0
        var depth = 0
        init(_ text: String) { chars = Array(text) }
        mutating func spaces() { while index < chars.count && chars[index].isWhitespace { index += 1 } }
        mutating func argument() throws -> String {
            spaces()
            guard index < chars.count else { throw NarrationText.Invalid("The recognized formula is incomplete. Try capturing it again.") }
            // An unbraced TeX argument is one token: \frac12 is 1 over 2,
            // while a multi-digit argument is written as {12}.
            if chars[index].isNumber { let digit = chars[index]; index += 1; return String(digit) }
            return try atom()
        }
        mutating func parse(until end: Character? = nil) throws -> String {
            depth += 1
            defer { depth -= 1 }
            guard depth <= 32 else { throw NarrationText.Invalid("The formula is too deeply nested to narrate.") }
            var parts: [String] = []
            while index < chars.count {
                spaces()
                if index >= chars.count { break }
                if let end, chars[index] == end { index += 1; return parts.filter { !$0.isEmpty }.joined(separator: " ") }
                var value = try atom()
                spaces()
                while index < chars.count && (chars[index] == "^" || chars[index] == "_") {
                    let exponent = chars[index] == "^"
                    index += 1
                    value += exponent ? " to the power " : " sub "
                    value += try argument()
                    spaces()
                }
                parts.append(value)
            }
            if end != nil { throw NarrationText.Invalid("The recognized formula has an unclosed group. Try capturing it again.") }
            return parts.filter { !$0.isEmpty }.joined(separator: " ")
        }
        mutating func atom() throws -> String {
            spaces()
            guard index < chars.count else { return "" }
            let character = chars[index]
            index += 1
            if character == "{" { return try parse(until: "}") }
            if character == "(" { return "open parenthesis " + (try parse(until: ")")) + " close parenthesis" }
            if character == "[" { return "open bracket " + (try parse(until: "]")) + " close bracket" }
            if character == "O", index < chars.count, chars[index] == "(" {
                index += 1
                return "big O of " + (try parse(until: ")"))
            }
            if character == "\\" {
                let start = index
                while index < chars.count && chars[index].isLetter { index += 1 }
                if start == index {
                    guard index < chars.count else { return "" }
                    let escaped = chars[index]; index += 1
                    if ",;!: ".contains(escaped) { return "" }
                    if escaped == "%" { return "percent" }
                    throw NarrationText.Invalid("This formula contains unsupported notation: \\\(escaped)")
                }
                let command = String(chars[start..<index])
                if let name = greek[command.lowercased()] { return command.first?.isUppercase == true ? "capital " + name : name }
                if let name = operators[command] { return name }
                if ["left", "right", "quad", "qquad", "displaystyle", "textstyle", "limits"].contains(command) { return "" }
                if ["frac", "dfrac", "tfrac"].contains(command) {
                    let numerator = try argument(), denominator = try argument()
                    return "fraction " + numerator + " over " + denominator + " end fraction"
                }
                if command == "sqrt" {
                    spaces()
                    var root = "square root"
                    if index < chars.count, chars[index] == "[" {
                        index += 1
                        let degree = try parse(until: "]")
                        root = degree == "3" ? "cube root" : "root of degree " + degree
                    }
                    return root + " of " + (try argument()) + " end root"
                }
                if ["log", "ln", "sin", "cos", "tan", "min", "max", "exp"].contains(command) {
                    var name = command == "ln" ? "natural log" : command
                    spaces()
                    if command == "log", index < chars.count, chars[index] == "_" { index += 1; name += " base " + (try argument()) }
                    spaces()
                    if index < chars.count, chars[index] == "^" { index += 1; name += " to the power " + (try argument()) }
                    spaces()
                    guard index < chars.count else { throw NarrationText.Invalid("The recognized function is missing its argument.") }
                    return name + " of " + (try atom())
                }
                if ["text", "textrm", "mathrm", "mathit", "mathbf", "mathsf", "operatorname"].contains(command) {
                    spaces()
                    guard index < chars.count, chars[index] == "{" else { throw NarrationText.Invalid("The recognized formula is incomplete.") }
                    index += 1
                    let start = index
                    while index < chars.count && chars[index] != "}" { index += 1 }
                    guard index < chars.count else { throw NarrationText.Invalid("The recognized formula is incomplete.") }
                    let value = String(chars[start..<index]); index += 1
                    return value
                }
                throw NarrationText.Invalid("Formula narration does not yet support \\\(command).")
            }
            if let name = glyphs[character] { return name }
            if let lower = character.lowercased().first, let name = glyphs[lower] { return "capital " + name }
            if character.isNumber {
                let start = index - 1
                while index < chars.count && (chars[index].isNumber || (chars[index] == "." && index + 1 < chars.count && chars[index + 1].isNumber)) { index += 1 }
                return String(chars[start..<index])
            }
            if character.isASCII, character.isLetter { return letters[character.lowercased()] ?? String(character) }
            let symbols: [Character: String] = ["/": "over", "=": "equals", "+": "plus", "-": "minus", "−": "minus", "*": "times", "×": "times",
                "<": "less than", ">": "greater than", "≥": "greater than or equal to", "≤": "less than or equal to", "≠": "not equal to", "≈": "approximately equals",
                "^": "to the power", "_": "sub", ",": "comma", ".": ".", ":": "colon", "|": "vertical bar", "%": "percent"]
            if let symbol = symbols[character] { return symbol }
            throw NarrationText.Invalid("This formula contains unsupported notation: \(character)")
        }
    }
}
