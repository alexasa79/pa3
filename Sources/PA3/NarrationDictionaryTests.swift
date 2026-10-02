import AppKit
import SwiftUI

@MainActor
func runNarrationDictionaryTests() -> [String] {
    var failures: [String] = []
    func check(_ value: Bool, _ message: String) { if !value { failures.append("narration dictionary: " + message) } }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("dictionary.json")
    do {
        let store = NarrationDictionary(path: path)
        check(try store.pronunciations().isEmpty, "new dictionary starts empty")
        let entries = [NarrationDictionaryEntry(spelling: " SQL ", pronunciation: " sequel "),
                       NarrationDictionaryEntry(spelling: "New York", pronunciation: "the city"),
                       NarrationDictionaryEntry(spelling: "York", pronunciation: "SQL"),
                       NarrationDictionaryEntry(spelling: "src/main.cpp", pronunciation: "the main source file"),
                       NarrationDictionaryEntry(spelling: "type_name_t", pronunciation: "the type name")]
        try store.save(entries)
        let reloaded = NarrationDictionary(path: path)
        check(try reloaded.pronunciations()["SQL"] == "sequel", "entries persist and trim whitespace")
        let source = "🙂 sql SQLAlchemy New York York in src/main.cpp uses type_name_t."
        for output in ["playback", "pieces", "stream"] {
            let pieces = try NarrationText.plan(NarrationInput(text: source, output: output), dictionary: reloaded.pronunciations())
            check(pieces.map(\.text).joined(separator: " ") == "🙂 sequel SQLAlchemy the city SQL in the main source file uses the type name.",
                  "whole words, case, longest match, no recursion and path/identifier precedence: \(output)")
            check(pieces.first?.sourceRange == NSRange(location: 0, length: source.utf16.count), "original UTF-16 offsets survive substitutions")
        }
        let unicode = try NarrationText.plan(NarrationInput(text: "STRASSE привет"), dictionary: ["straße": "street", "ПРИВЕТ": "hello"])
        check(unicode.map(\.text) == ["street hello"], "Unicode case matching")
        let vocabulary = Vocabulary(path: directory.appendingPathComponent("transcription.txt"))
        _ = try vocabulary.replace(with: "WhisperWord")
        check(try store.pronunciations()["WhisperWord"] == nil, "transcription terms never become narration entries")
        check(vocabulary.allWords() == ["WhisperWord"], "narration entries never become transcription terms")
        let preview = try NarrationText.plan(NarrationInput(text: "sql", pronunciations: ["sql": "ess cue ell"]), dictionary: store.pronunciations())
        check(preview.map(\.text) == ["ess cue ell"], "request preview overrides saved entry")
        check(try store.pronunciations()["SQL"] == "sequel", "preview does not save changes")
        for invalid in [[NarrationDictionaryEntry(spelling: "", pronunciation: "test")],
                        [NarrationDictionaryEntry(spelling: "SQL", pronunciation: "")],
                        [NarrationDictionaryEntry(spelling: "SQL", pronunciation: "one"), NarrationDictionaryEntry(spelling: "sql", pronunciation: "two")],
                        [NarrationDictionaryEntry(spelling: "two\nlines", pronunciation: "test")]] {
            do { try store.save(invalid); check(false, "invalid dictionary accepted") } catch {}
        }
        check(store.entries.count == entries.count, "failed validation preserves saved dictionary")
        let badPath = directory.appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: badPath, withIntermediateDirectories: true)
        let bad = NarrationDictionary(path: badPath)
        do { try bad.save(entries); check(false, "write error not reported") } catch {}
        try Data("bad json".utf8).write(to: path)
        let corrupt = NarrationDictionary(path: path)
        do { _ = try corrupt.pronunciations(); check(false, "corrupt dictionary silently accepted") } catch {}
        try store.save([])
        check(try NarrationDictionary(path: path).pronunciations().isEmpty, "deleting entries persists")
        let math = "🙂 X≥0 and X ≤ 10, X≠5, X≈3."
        let pieces = try NarrationText.plan(NarrationInput(text: math), dictionary: ["X": "value"])
        check(pieces.map(\.text) == ["🙂 value is greater than or equal to 0 and value is less than or equal to 10, value is not equal to 5, value is approximately equal to 3."], "math processing follows dictionary")
        check(pieces.first?.sourceRange == NSRange(location: 0, length: math.utf16.count), "math source offsets")

        let controller = DictationController(transcriber: TranscriberService())
        let editor = DictionariesEditor(controller: controller, dictionary: store, tab: 1)
        var opened = false
        controller.onOpenDictionaries = { opened = true; editor.tab = 0 }
        controller.openVocabularyEditor()
        check(opened && editor.tab == 0 && !controller.dictating, "dictionary access never starts dictation")
        if CommandLine.arguments.contains("--dictionary-test") {
            editor.tab = 1
            editor.entries = entries
            let view = NSHostingView(rootView: DictionariesView(controller: controller, dictionary: store,
                preview: { _ in nil }, stopPreview: {}, editor: editor))
            view.frame = NSRect(x: 0, y: 0, width: 800, height: 480)
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/pa3-dictionaries.png"))
            }
        }
    } catch { failures.append("narration dictionary: \(error)") }
    return failures
}
