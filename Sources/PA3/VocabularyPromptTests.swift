import Foundation

func runVocabularyPromptTests() -> [String] {
    var failures: [String] = []
    let words = ["REDTRC", "BDL", "NVMe", "Yong Ze", "std::list"]
    let prompt = Vocabulary.whisperPrompt(for: words)
    if prompt != words.joined(separator: ", ") + "." {
        failures.append("Whisper prompt must be the glossary alone, without a label or invented transcript example")
    }
    if Vocabulary.whisperPrompt(for: []) != "" {
        failures.append("empty dictionary must not inject a canned utterance into Whisper context")
    }
    if Vocabulary.whisperPrompt(for: ["Hello", "vocabulary"]) != "Hello, vocabulary." {
        failures.append("real glossary words must be preserved even when they resemble the old example or label")
    }
    return failures
}
