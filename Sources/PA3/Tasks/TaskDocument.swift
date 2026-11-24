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

    init(_ text: String) {
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
                if Self.validDate(value) { due = value }
                else { warnings.append("Use #due:YYYY-MM-DD, for example #due:2026-11-15.") }
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

    private static func parsePriority(_ value: String) -> Int? {
        let lowered = value.lowercased()
        let digits: Substring = lowered.hasPrefix("p") ? lowered.dropFirst() : lowered[...]
        guard digits.count == 1, let digit = digits.first, digit >= "0", digit <= "5" else { return nil }
        return Int(String(digit))
    }

    private static func validDate(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), year > 0, let month = Int(parts[1]), let day = Int(parts[2]) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return false }
        return calendar.dateComponents([.year, .month, .day], from: date) == components
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
