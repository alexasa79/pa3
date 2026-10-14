import AppKit

@MainActor
func runDeletionCleanupTests() -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ name: String) {
        if !condition { failures.append("deletion cleanup: " + name) }
    }
    func deleting(_ text: String, _ removed: String) -> String {
        let (words, paras) = splitWordsAndParagraphs(text)
        let target = splitWords(removed)
        guard !target.isEmpty, let start = words.indices.first(where: {
            Array(words.dropFirst($0).prefix(target.count)) == target
        }) else { failures.append("missing test selection: " + removed); return text }
        let end = start + target.count
        let result = cleanupDeletion(words: Array(words[..<start]) + Array(words[end...]),
                                     paragraphs: Array(paras[..<start]) + Array(paras[end...]), at: start,
                                     deletedParagraph: paras[end - 1])
        return buildTextFromWordData(words: result.words, paragraphs: result.paragraphs)
    }
    for (source, removed, expected) in [
        ("Done. However, we continue.", "However", "Done. We continue."),
        ("Hello, extra. Next.", "extra", "Hello. Next."),
        ("One, extra, two.", "extra", "One, two."),
        ("Actually, hello there.", "Actually", "Hello there."),
        ("The cat sleeps.", "The", "Cat sleeps."),
        ("Done! The cat sleeps.", "The", "Done! Cat sleeps."),
        ("Done? The cat sleeps.", "The", "Done? Cat sleeps."),
        ("Done. The NASA team works.", "The", "Done. NASA team works."),
        ("The iPhone works.", "The", "iPhone works."),
        ("The e.g. example stays.", "The", "e.g. example stays."),
        ("The dr. smith example stays.", "The", "dr. smith example stays."),
        ("Dr. old smith arrived.", "old", "Dr. smith arrived."),
        ("J. old smith arrived.", "old", "J. smith arrived."),
        ("The foo_bar works.", "The", "foo_bar works."),
        ("The 3.14 value stays.", "The", "3.14 value stays."),
        ("Done... The cat sleeps.", "The", "Done... cat sleeps."),
        ("Really?! The cat sleeps.", "The", "Really?! cat sleeps."),
        ("First.\n\nThe cat sleeps.", "The", "First.\n\nCat sleeps."),
        ("Remove.\n\nlowercase stays.", "Remove.", "lowercase stays."),
        ("Remove,\n\nlowercase stays.", "Remove", "lowercase stays."),
        ("The кот спит.", "The", "Кот спит."),
        ("Odd., untouched. Delete this.", "Delete", "Odd., untouched. This."),
        ("Done. remove", "remove", "Done."),
        ("Only", "Only", "")
    ] {
        let result = deleting(source, removed)
        check(result == expected, "\(source) minus \(removed): got \(result), expected \(expected)")
    }

    let controller = DictationController(transcriber: TranscriberService())
    func press(_ characters: String) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: 0, windowNumber: 0, context: nil,
                                    characters: characters, charactersIgnoringModifiers: characters,
                                    isARepeat: false, keyCode: 0)!
        controller.handleKey(KeyEvent(nsEvent: event))
    }
    func seed() {
        controller.beginNewSession()
        press("i")
        controller.editText = "Done. However, we continue."
        controller.applyCurrentEdit()
        controller.selectedWord = 2
        controller.selectionStart = 2
        controller.selectionEnd = 2
    }
    seed()
    press("x")
    check(controller.text == "Done. We continue.", "x cleans the deletion")
    check(controller.keyBindings().contains("u: undo last change"), "undo is discoverable")
    press("u")
    check(controller.text == "Done. However, we continue.", "undo restores deletion and cleanup together")
    check(controller.selectedWord == 2 && controller.selectionStart == 2 && controller.selectionEnd == 2,
          "undo restores the original selection")
    var pasted = ""
    controller.onPasteAndHide = { pasted = $0 }
    controller.pasteAndHide()
    check(pasted == "Done. However, we continue.", "paste uses restored text")
    press("u")
    check(controller.text.isEmpty, "repeated undo restores the earlier insertion")
    press("u")
    check(controller.text.isEmpty, "empty undo history is harmless")
    seed()
    press("x")
    press("t")
    press("t")
    check(controller.text == "Done. we continue.", "manual lowercase wins")
    press("u")
    check(controller.text == "Done. WE continue.", "undo restores the latest capitalization edit")
    press("u")
    check(controller.text == "Done. We continue.", "undo restores the prior capitalization edit")
    press("u")
    check(controller.text == "Done. However, we continue.", "undo reaches the deletion after subsequent edits")
    seed()
    press("c")
    controller.editText = "odd.,"
    controller.applyCurrentEdit()
    check(controller.text.contains("odd.,"), "explicit punctuation is never cleaned")

    func seedSentence(_ source: String, at word: String) -> Int {
        controller.beginNewSession()
        controller.handleTranscription(TranscriptionUpdate(text: source, language: nil))
        let index = controller.words.firstIndex(of: word)!
        controller.selectedWord = index
        controller.selectionStart = index
        controller.selectionEnd = index
        return index
    }
    for (source, word, expected) in [
        ("The quick brown fox sleeps. Next sentence.", "brown", "The quick. Next sentence."),
        ("First sentence. Remove this entire sentence! Last one.", "Remove", "First sentence. Last one."),
        ("Dr. Smith paid 3.14 dollars. Next sentence.", "paid", "Dr. Smith. Next sentence."),
        ("Dr. Smith paid 3.14 dollars. Next sentence.", "Dr", "Next sentence."),
        ("The value is 3.14 dollars. Next sentence.", "3.14", "The value is. Next sentence."),
        ("She said, “Go now!” Then left.", "now", "She said, “Go!” Then left."),
        ("First... Second sentence?! Third.", "sentence", "First... Second?! Third."),
        ("Hello, extra words. Next.", "extra", "Hello. Next."),
        ("Keep some trailing words\n\nNext paragraph.", "trailing", "Keep some\n\nNext paragraph."),
        ("Remove this\n\nNext paragraph.", "Remove", "Next paragraph."),
        ("שלום עולם יפה. עוד משפט.", "עולם", "שלום. עוד משפט."),
        ("One two three.", "three", "One two."),
        ("Only words", "Only", ""),
        ("One two. Next.", ".", "One two. Next.")
    ] {
        let index = seedSentence(source, at: word)
        press("X")
        check(controller.text == expected, "X from \(word): got \(controller.text), expected \(expected)")
        if source != expected {
            press("u")
            check(controller.text == source && controller.selectedWord == index && controller.selectionStart == index && controller.selectionEnd == index,
                  "X undo restores the full sentence and selection")
        }
    }
    let source = "The quick brown fox sleeps. Next sentence."
    let index = seedSentence(source, at: "brown")
    controller.selectionStart = 0
    controller.selectionEnd = controller.words.count - 1
    let selectionEnd = controller.selectionEnd
    press("X")
    check(controller.text == "The quick. Next sentence.", "X uses the current word and never consumes a selected later sentence")
    press("u")
    check(controller.text == source && controller.selectedWord == index && controller.selectionStart == 0 && controller.selectionEnd == selectionEnd,
          "X undo restores an extended selection")
    _ = seedSentence(source, at: "brown")
    press("x")
    check(controller.text == "The quick fox sleeps. Next sentence.", "lowercase x still deletes only the current word")
    _ = seedSentence(source, at: "brown")
    controller.dictating = true
    press("X")
    check(controller.text == source, "X does not edit during dictation")
    controller.dictating = false
    press("c")
    press("X")
    check(controller.editText == "X" && controller.text == source, "X remains literal inside the text editor")
    controller.cancelCurrentEdit()
    check(controller.keyBindings().contains(where: { $0.hasPrefix("X: delete to sentence end") }), "X is discoverable in keyboard shortcuts")
    return failures
}
