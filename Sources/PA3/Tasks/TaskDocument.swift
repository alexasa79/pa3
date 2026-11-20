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
    var body: String
    var subject: String {
        let first = body.components(separatedBy: .newlines).first ?? ""
        return first.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled task" : first
    }
    var metadata: TaskMetadata { TaskMetadata(body) }
}

struct TaskSnapshot: Sendable {
    var categories: [TaskCategory]
    var projects: [TaskProject]
    var tasks: [PersonalTask]
}

/// Derived values only. The original document is always the source of truth.
struct TaskMetadata: Equatable {
    var due: String?
    var priority: String?
    var done = false
    var warnings: [String] = []

    private static let tags = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])#(due|priority|prio|status):([^\s#]+)|(?<![\p{L}\p{N}_])#done\b"#)

    init(_ text: String) {
        let source = text as NSString
        var seen = Set<String>()
        for match in Self.tags.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            if match.range(at: 1).location == NSNotFound { done = true; continue }
            var key = source.substring(with: match.range(at: 1))
            if key == "prio" { key = "priority" }
            let value = source.substring(with: match.range(at: 2))
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?)]}"))
            if !seen.insert(key).inserted { warnings.append("Multiple #\(key) tags; the last valid value is used.") }
            switch key {
            case "due":
                if Self.validDate(value) { due = value }
                else { warnings.append("Use #due:YYYY-MM-DD, for example #due:2026-11-15.") }
            case "priority":
                if ["1", "2", "3"].contains(value) { priority = value }
                else { warnings.append("Use #priority:1, #priority:2, or #priority:3. Priority 1 is highest.") }
            case "status":
                if value == "done" { done = true }
                else if value == "open" { done = false }
                else if value != "open" { warnings.append("Use #status:open or #status:done.") }
            default: break
            }
        }
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
        let expression = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])#(?:done\b|status:done\b)"#)
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
