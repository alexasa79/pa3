import AppKit

@MainActor
func runWordCapitalizationTests() -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ name: String) {
        if !condition { failures.append("capitalization: " + name) }
    }
    for (input, expected) in [
        ("word", "Word"), ("Word", "WORD"), ("WORD", "word"),
        ("wOrD", "word"), ("“word,”", "“Word,”"),
        ("don't", "Don't"), ("Don't", "DON'T"),
        ("привет", "Привет"), ("Привет", "ПРИВЕТ"), ("ПРИВЕТ", "привет"),
        ("école", "École"), ("i", "I"), ("I", "i"),
        ("123", "123"), ("שלום", "שלום"), ("", "")
    ] {
        check(nextWordCapitalization(input) == expected, "\(input) → \(expected)")
    }
    let controller = DictationController(transcriber: TranscriberService())
    func press(_ characters: String) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: 0, windowNumber: 0, context: nil,
                                    characters: characters, charactersIgnoringModifiers: characters,
                                    isARepeat: false, keyCode: 0)!
        controller.handleKey(KeyEvent(nsEvent: event))
    }
    press("t")
    check(controller.text.isEmpty && !controller.editMode, "empty transcript is unchanged")
    let (words, paragraphs) = splitWordsAndParagraphs("before\n\nword, after")
    controller.words = words
    controller.wordParagraphs = paragraphs
    controller.selectedWord = 1
    controller.selectionStart = 0
    controller.selectionEnd = 2
    for expected in ["Word,", "WORD,", "word,"] {
        press("t")
        check(controller.text == "before\n\n\(expected) after", "keyboard cycle preserves surrounding text and paragraphs")
        check(controller.selectedWord == 1 && controller.selectionStart == 0 && controller.selectionEnd == 2,
              "current word and expanded selection stay in place")
        check(!controller.editMode, "capitalization does not open the editor")
    }
    controller.dictating = true
    press("t")
    check(controller.words[1] == "word", "disabled during dictation")
    controller.dictating = false
    press("a")
    check(controller.editMode, "a opens append after")
    controller.editText = "added"
    controller.applyCurrentEdit()
    check(controller.text == "before\n\nword, added after", "append inserts after selection")
    press("c")
    press("t")
    check(controller.editText == "t", "t remains literal text in edit mode")
    controller.cancelCurrentEdit()
    press("I")
    controller.editText = "inserted"
    controller.applyCurrentEdit()
    check(controller.text == "before\n\nword, inserted added after", "Shift+I still inserts before selection")
    return failures
}
