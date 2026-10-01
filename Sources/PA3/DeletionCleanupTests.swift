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
    return failures
}
