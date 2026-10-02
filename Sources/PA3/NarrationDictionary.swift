import Foundation
import Combine

struct NarrationDictionaryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var spelling: String
    var pronunciation: String
}

@MainActor
final class NarrationDictionary: ObservableObject {
    @Published private(set) var entries: [NarrationDictionaryEntry] = []
    @Published private(set) var loadError: String?
    private let path: URL

    init(path: URL) {
        self.path = path
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        do {
            entries = try Self.validate(JSONDecoder().decode([NarrationDictionaryEntry].self, from: Data(contentsOf: path)))
        } catch {
            loadError = "Could not load narration dictionary: \(error.localizedDescription)"
            Logger.info(loadError!)
        }
    }

    static func validate(_ entries: [NarrationDictionaryEntry]) throws -> [NarrationDictionaryEntry] {
        guard entries.count <= 100 else { throw Invalid("Use at most 100 narration entries.") }
        var seen = Set<String>()
        return try entries.map { entry in
            var entry = entry
            entry.spelling = entry.spelling.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.pronunciation = entry.pronunciation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.spelling.isEmpty, !entry.pronunciation.isEmpty,
                  entry.spelling.count <= 128, entry.pronunciation.count <= 256,
                  !entry.spelling.contains(where: \.isNewline), !entry.pronunciation.contains(where: \.isNewline) else {
                throw Invalid("Enter a written word or phrase (up to 128 characters) and a single-line pronunciation (up to 256 characters).")
            }
            guard seen.insert(entry.spelling.lowercased()).inserted else {
                throw Invalid("Duplicate written text: \(entry.spelling)")
            }
            return entry
        }
    }

    func pronunciations() throws -> [String: String] {
        if let loadError { throw Invalid(loadError) }
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.spelling, $0.pronunciation) })
    }

    func save(_ draft: [NarrationDictionaryEntry]) throws {
        let validated = try Self.validate(draft)
        let data = try JSONEncoder().encode(validated)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: path, options: .atomic)
        entries = validated
        loadError = nil
    }

    struct Invalid: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
