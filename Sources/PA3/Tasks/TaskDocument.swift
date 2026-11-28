import Foundation

struct TaskCategory: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
}

struct TaskProject: Identifiable, Equatable, Sendable {
    let id: String
    var parentID: String?
    var categoryID: String
    var name: String
}

struct PersonalTask: Identifiable, Equatable, Sendable {
    let id: String
    var projectID: String
    var body: String {
        didSet {
            subject = Self.makeSubject(from: body)
            metadata = TaskMetadata(body)
        }
    }
    private(set) var subject: String
    private(set) var metadata: TaskMetadata
    var isUntitled: Bool {
        let first = body.components(separatedBy: .newlines).first ?? ""
        return first.trimmingCharacters(in: .whitespaces).isEmpty
    }

    init(id: String, projectID: String, body: String) {
        self.id = id
        self.projectID = projectID
        self.body = body
        self.subject = Self.makeSubject(from: body)
        self.metadata = TaskMetadata(body)
    }

    private static func makeSubject(from body: String) -> String {
        let first = body.components(separatedBy: .newlines).first ?? ""
        return first.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled task" : first
    }
}

struct TaskSnapshot: Sendable {
    var categories: [TaskCategory]
    var projects: [TaskProject]
    var tasks: [PersonalTask]
}

/// Derived values only. The original document is always the source of truth.
struct TaskMetadata: Equatable, Sendable {
    var due: String?
    var priority: Int?
    var done = false
    var warnings: [String] = []

    private static let tags = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_])#(due|priority|prio|pri|status):([^\s#]+)|(?<![\p{L}\p{N}_])#done\b"#,
        options: [.caseInsensitive]
    )

    init(_ text: String, referenceDate: Date = Date(), calendar: Calendar = .current) {
        let source = text as NSString
        var seen = Set<String>()
        for match in Self.tags.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            if match.range(at: 1).location == NSNotFound { done = true; continue }
            var key = source.substring(with: match.range(at: 1)).lowercased()
            if key == "prio" || key == "pri" { key = "priority" }
            let value = source.substring(with: match.range(at: 2))
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?)]}"))
            if !seen.insert(key).inserted { warnings.append("Multiple #\(key) tags; the last valid value is used.") }
            switch key {
            case "due":
                if let resolved = Self.parseDueDate(value, referenceDate: referenceDate, calendar: calendar) { due = resolved }
                else { warnings.append("Use #due:YYYY-MM-DD, MM/DD/YYYY, today, tomorrow, or +1w/+2w3d.") }
            case "priority":
                if let level = Self.parsePriority(value) { priority = level }
                else { warnings.append("Use #pri:, #prio:, or #priority: with 0–5 or p0–p5. Priority 0 is highest.") }
            case "status":
                let status = value.lowercased()
                if status == "done" { done = true }
                else if status == "open" { done = false }
                else { warnings.append("Use #status:open or #status:done.") }
            default: break
            }
        }
    }

    private static let trailingPunctuation = CharacterSet(charactersIn: ".,;!?)]}")

    private static func parsePriority(_ value: String) -> Int? {
        let lowered = value.lowercased()
        let digits: Substring = lowered.hasPrefix("p") ? lowered.dropFirst() : lowered[...]
        guard digits.count == 1, let digit = digits.first, digit >= "0", digit <= "5" else { return nil }
        return Int(String(digit))
    }

    private static func parseDueDate(_ value: String, referenceDate: Date, calendar: Calendar) -> String? {
        parseAbsoluteDate(value) ?? parseDueFormula(value, referenceDate: referenceDate, calendar: calendar)
    }

    /// Accepts YYYY-MM-DD (4-digit year, 2-digit month, 2-digit day) and M/D/YYYY or M-D-YYYY.
    /// Returns canonical YYYY-MM-DD for valid calendar dates.
    static func parseAbsoluteDate(_ value: String) -> String? {
        if value.contains("/") {
            let parts = value.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 3, (1...2).contains(parts[0].count), (1...2).contains(parts[1].count), parts[2].count == 4,
                  let month = Int(parts[0]), let day = Int(parts[1]), let year = Int(parts[2]) else { return nil }
            return validatedISO(year: year, month: month, day: day)
        }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        if parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
           let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) {
            return validatedISO(year: year, month: month, day: day)
        }
        if (1...2).contains(parts[0].count), (1...2).contains(parts[1].count), parts[2].count == 4,
           let month = Int(parts[0]), let day = Int(parts[1]), let year = Int(parts[2]) {
            return validatedISO(year: year, month: month, day: day)
        }
        return nil
    }

    /// Resolves keywords (`today`, `tomorrow`) and relative formulas (`+1w`, `today+1w`, `tomorrow+3d`, `+2w3d`, `+1m2w3d`).
    static func parseDueFormula(_ value: String, referenceDate: Date = Date(), calendar: Calendar = .current) -> String? {
        let lowered = value.lowercased()
        let baseDays: Int
        let offsetPart: Substring
        if lowered == "today" {
            baseDays = 0; offsetPart = ""
        } else if lowered == "tomorrow" {
            baseDays = 1; offsetPart = ""
        } else if lowered.hasPrefix("today+") {
            baseDays = 0; offsetPart = lowered.dropFirst("today".count)
        } else if lowered.hasPrefix("tomorrow+") {
            baseDays = 1; offsetPart = lowered.dropFirst("tomorrow".count)
        } else if lowered.hasPrefix("+") {
            baseDays = 0; offsetPart = lowered[...]
        } else {
            return nil
        }

        var months = 0
        var weeks = 0
        var days = 0
        if !offsetPart.isEmpty {
            guard offsetPart.first == "+" else { return nil }
            var index = offsetPart.index(after: offsetPart.startIndex)
            guard index < offsetPart.endIndex else { return nil }
            var termCount = 0
            while index < offsetPart.endIndex {
                if offsetPart[index] == "+" {
                    // Allow optional '+' between terms (e.g. +2w+3d), but not consecutive or trailing '+'.
                    guard termCount > 0 else { return nil }
                    index = offsetPart.index(after: index)
                    guard index < offsetPart.endIndex else { return nil }
                }
                let digitStart = index
                while index < offsetPart.endIndex, offsetPart[index].isASCII, offsetPart[index].isNumber {
                    index = offsetPart.index(after: index)
                }
                guard digitStart < index, index < offsetPart.endIndex,
                      let amount = Int(offsetPart[digitStart..<index]), amount <= 100_000 else { return nil }
                let unit = offsetPart[index]
                index = offsetPart.index(after: index)
                switch unit {
                case "d": days += amount
                case "w": weeks += amount
                case "m": months += amount
                default: return nil
                }
                termCount += 1
            }
            guard termCount > 0 else { return nil }
        }

        let start = calendar.startOfDay(for: referenceDate)
        let components = DateComponents(month: months, day: baseDays + weeks * 7 + days)
        guard let target = calendar.date(byAdding: components, to: start) else { return nil }
        let resolved = calendar.dateComponents([.year, .month, .day], from: target)
        guard let year = resolved.year, let month = resolved.month, let day = resolved.day else { return nil }
        return validatedISO(year: year, month: month, day: day)
    }

    static func dueFormulaReplacements(in text: String, referenceDate: Date = Date(), calendar: Calendar = .current) -> [(range: NSRange, replacement: String)] {
        let source = text as NSString
        var replacements: [(range: NSRange, replacement: String)] = []
        for match in Self.tags.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard match.range(at: 1).location != NSNotFound else { continue }
            let key = source.substring(with: match.range(at: 1)).lowercased()
            guard key == "due" else { continue }
            let rawRange = match.range(at: 2)
            let rawValue = source.substring(with: rawRange)
            var trimmed = rawValue
            while let last = trimmed.unicodeScalars.last, trailingPunctuation.contains(last) {
                trimmed.unicodeScalars.removeLast()
            }
            guard !trimmed.isEmpty,
                  let resolved = parseDueFormula(trimmed, referenceDate: referenceDate, calendar: calendar) else { continue }
            let coreRange = NSRange(location: rawRange.location, length: (trimmed as NSString).length)
            replacements.append((coreRange, resolved))
        }
        return replacements
    }

    static func expandingDueFormulas(in text: String, cursorLocation: Int? = nil,
                                     referenceDate: Date = Date(), calendar: Calendar = .current) -> (text: String, cursorLocation: Int) {
        let replacements = dueFormulaReplacements(in: text, referenceDate: referenceDate, calendar: calendar)
        var cursor = cursorLocation ?? (text as NSString).length
        guard !replacements.isEmpty else { return (text, cursor) }
        let mutable = NSMutableString(string: text)
        for item in replacements.reversed() {
            mutable.replaceCharacters(in: item.range, with: item.replacement)
            let delta = (item.replacement as NSString).length - item.range.length
            if cursor >= NSMaxRange(item.range) {
                cursor += delta
            } else if cursor > item.range.location {
                cursor = item.range.location + (item.replacement as NSString).length
            }
        }
        let result = mutable as String
        return (result, min(max(0, cursor), (result as NSString).length))
    }

    private static func validatedISO(year: Int, month: Int, day: Int) -> String? {
        guard year > 0 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: date) == components else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    enum TagKind: Equatable, Sendable {
        case due
        case priority(Int)
        case done
        case open
    }

    struct TagMatch: Equatable, Sendable {
        let range: NSRange
        let kind: TagKind
    }

    static func validTagMatches(in text: String, referenceDate: Date = Date(), calendar: Calendar = .current) -> [TagMatch] {
        let source = text as NSString
        var matches: [TagMatch] = []
        for match in Self.tags.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            if match.range(at: 1).location == NSNotFound {
                matches.append(TagMatch(range: match.range, kind: .done))
                continue
            }
            var key = source.substring(with: match.range(at: 1)).lowercased()
            if key == "prio" || key == "pri" { key = "priority" }
            let rawRange = match.range(at: 2)
            let rawValue = source.substring(with: rawRange)
            var trimmed = rawValue
            while let last = trimmed.unicodeScalars.last, trailingPunctuation.contains(last) {
                trimmed.unicodeScalars.removeLast()
            }
            guard !trimmed.isEmpty else { continue }
            let end = rawRange.location + (trimmed as NSString).length
            let tagRange = NSRange(location: match.range.location, length: end - match.range.location)
            switch key {
            case "due":
                if parseDueDate(trimmed, referenceDate: referenceDate, calendar: calendar) != nil {
                    matches.append(TagMatch(range: tagRange, kind: .due))
                }
            case "priority":
                if let level = parsePriority(trimmed) {
                    matches.append(TagMatch(range: tagRange, kind: .priority(level)))
                }
            case "status":
                let status = trimmed.lowercased()
                if status == "done" { matches.append(TagMatch(range: tagRange, kind: .done)) }
                else if status == "open" { matches.append(TagMatch(range: tagRange, kind: .open)) }
            default:
                break
            }
        }
        return matches
    }

    static func togglingCompletion(in text: String) -> String {
        if !TaskMetadata(text).done {
            return text + (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + "#done"
        }
        let source = text as NSString
        let expression = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])#(?:done\b|status:done\b)"#, options: [.caseInsensitive])
        return expression.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: source.length), withTemplate: "")
    }
}

/// Dictation edits a bounded selection, preserving every byte outside that selection.
struct TaskDictationInsertion {
    let original: String
    let range: NSRange

    init(text: String, selection: NSRange) {
        original = text
        let length = (text as NSString).length
        let location = min(max(0, selection.location), length)
        range = NSRange(location: location, length: min(max(0, selection.length), length - location))
    }

    func applying(_ transcript: String) -> String {
        result(for: transcript).body
    }

    func result(for transcript: String) -> (body: String, cursorLocation: Int) {
        // An empty recognition must not erase a selected passage.
        guard !transcript.isEmpty else { return (original, range.location) }
        let source = original as NSString
        let prefix = source.substring(to: range.location)
        let suffix = source.substring(from: NSMaxRange(range))
        let leftSpace = prefix.last.map { !$0.isWhitespace } == true
            && transcript.first.map { !$0.isWhitespace && !$0.isPunctuation } == true
        let rightSpace = suffix.first.map { !$0.isWhitespace && !$0.isPunctuation } == true
            && transcript.last.map { !$0.isWhitespace } == true
        let inserted = (leftSpace ? " " : "") + transcript
        let cursor = (prefix as NSString).length + (inserted as NSString).length
        return (prefix + inserted + (rightSpace ? " " : "") + suffix, cursor)
    }
}
