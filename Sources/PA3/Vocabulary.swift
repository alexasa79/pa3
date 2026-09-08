import Foundation

final class Vocabulary {
    private let path: URL
    private let lock = NSLock()
    private var words: [String] = []
    private var index: Set<String> = []

    init(path: URL) {
        self.path = path
        load()
    }

    func add(_ word: String) -> (normalized: String, added: Bool) {
        let normalized = Self.normalize(word)
        if normalized.isEmpty {
            return ("", false)
        }
        lock.lock()
        defer { lock.unlock() }
        if index.contains(normalized) {
            return (normalized, false)
        }
        words.append(normalized)
        index.insert(normalized)
        saveLocked()
        return (normalized, true)
    }

    func allWords() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return words
    }

    func replace(with text: String) -> [String] {
        let nextWords = Self.normalizedUniqueWords(from: text)
        lock.lock()
        defer { lock.unlock() }
        words = nextWords
        index = Set(nextWords)
        saveLocked()
        return words
    }

    func systemPrompt() -> String {
        lock.lock()
        defer { lock.unlock() }
        // Give Whisper a fixed punctuation style without feeding back previous dictation.
        let punctuationExample = "Hello. This is a punctuated transcript."
        if words.isEmpty {
            return punctuationExample
        }
        return "vocabulary: " + words.joined(separator: ", ") + "\n" + punctuationExample
    }

    private func load() {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            return
        }
        for line in text.components(separatedBy: .newlines) {
            let normalized = Self.normalize(line)
            if !normalized.isEmpty, !index.contains(normalized) {
                words.append(normalized)
                index.insert(normalized)
            }
        }
    }

    private func saveLocked() {
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? words.joined(separator: "\n").appending("\n").write(to: path, atomically: true, encoding: .utf8)
    }

    private static func normalize(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?:;\"'()[]{}"))
    }

    private static func normalizedUniqueWords(from text: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for line in text.components(separatedBy: .newlines) {
            let normalized = normalize(line)
            if !normalized.isEmpty, !seen.contains(normalized) {
                result.append(normalized)
                seen.insert(normalized)
            }
        }
        return result
    }
}

final class OllamaClient {
    private let endpoint = URL(string: "http://localhost:11434")!
    private let model = "mistral:7b"

    func spellCheckTranscript(_ text: String) throws -> String {
        let prompt = """
        Spell-check the transcript below.

        Rules:
        - Preserve exact meaning, facts, and intent
        - Correct spelling mistakes
        - Correct obvious grammar and punctuation errors
        - Do not remove words, filler, repetitions, or restructure sentences
        - Keep existing paragraph breaks (blank lines); do not add new ones
        - Return ONLY the corrected text, nothing else

        Text:
        \(text)
        """
        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "options": [
                "temperature": 0.2,
                "repeat_penalty": 1.1
            ]
        ]
        var request = URLRequest(url: endpoint.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let result = SyncHTTP.data(for: request)

        if let error = result.error {
            throw error
        }
        guard result.statusCode == 200, let output = result.data else {
            throw NSError(domain: "PA3.Ollama", code: result.statusCode, userInfo: [NSLocalizedDescriptionKey: "Ollama returned \(result.statusCode)"])
        }
        let json = try JSONSerialization.jsonObject(with: output) as? [String: Any]
        if let error = json?["error"] as? String, !error.isEmpty {
            throw NSError(domain: "PA3.Ollama", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
        }
        return (json?["response"] as? String) ?? ""
    }
}
