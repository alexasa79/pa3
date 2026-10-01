import AppKit

@MainActor
func runUndoTests() -> [String] {
    var failures: [String] = []
    let controller = DictationController(transcriber: TranscriberService())
    func check(_ condition: Bool, _ name: String) {
        if !condition { failures.append("undo: " + name) }
    }
    func press(_ characters: String) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: 0, windowNumber: 0, context: nil,
                                    characters: characters, charactersIgnoringModifiers: characters,
                                    isARepeat: false, keyCode: 0)!
        controller.handleKey(KeyEvent(nsEvent: event))
    }
    func select(_ index: Int, through end: Int? = nil) {
        controller.selectedWord = index
        controller.selectionStart = index
        controller.selectionEnd = end ?? index
    }
    func seed(_ text: String) {
        controller.beginNewSession()
        press("i")
        controller.editText = text
        controller.applyCurrentEdit()
        select(0)
    }
    for key in ["c", "C", "i", "I", "a"] {
        seed("one two one")
        press(key)
        controller.editText = "changed"
        controller.applyCurrentEdit()
        check(controller.text != "one two one", "\(key) changes text")
        press("u")
        check(controller.text == "one two one", "\(key) is undone as one edit")
        check(controller.selectionStart == 0 && controller.selectionEnd == 0, "\(key) restores selection")
        press("u")
        check(controller.text.isEmpty, "\(key) records no duplicate undo entry")
    }
    seed("one two three")
    press("c")
    controller.editText = "replacement"
    controller.applyCurrentEdit()
    select(1)
    press(".")
    press("u")
    check(controller.text == "replacement two three", "repeat change can be undone")
    press("u")
    check(controller.text == "one two three" && !controller.lastReplaceSet, "undo restores repeat-change state")

    seed("one two three four")
    select(1)
    press("S")
    press("J")
    check(controller.text == "one two three four", "join changes paragraphs")
    press("u")
    check(controller.text == "one two\n\nthree four", "join undo restores paragraphs")
    select(0)
    press("S")
    check(controller.text == "one\n\ntwo\n\nthree four", "split changes paragraphs")
    press("u")
    check(controller.text == "one two\n\nthree four", "split undo restores paragraphs")

    seed("one two")
    select(0, through: 1)
    press("x")
    check(controller.text.isEmpty, "delete all")
    press("u")
    check(controller.text == "one two" && controller.selectionEnd == 1, "delete-all undo restores range")
    press("c")
    press("u")
    check(controller.editText == "u", "u remains literal in edit mode")
    controller.cancelCurrentEdit()
    press("c")
    controller.editText = "one two"
    controller.applyCurrentEdit()
    press("u")
    check(controller.text.isEmpty, "unchanged edits do not consume undo")
    seed("one two")
    controller.beginNewSession()
    press("u")
    check(controller.text.isEmpty, "new session clears undo")
    return failures
}
