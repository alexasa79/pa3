import AppKit

@MainActor
func runRepeatReplacementTests() -> [String] {
    var failures: [String] = []
    let controller = DictationController(transcriber: TranscriberService())
    func check(_ condition: Bool, _ name: String) {
        if !condition { failures.append("repeat all: " + name) }
    }
    func press(_ characters: String) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: 0, windowNumber: 0, context: nil,
                                    characters: characters, charactersIgnoringModifiers: characters,
                                    isARepeat: false, keyCode: 0)!
        controller.handleKey(KeyEvent(nsEvent: event))
    }
    func select(_ start: Int, _ end: Int? = nil) {
        controller.selectedWord = start
        controller.selectionStart = start
        controller.selectionEnd = end ?? start
    }
    func seed(_ text: String) {
        controller.beginNewSession()
        controller.lastReplaceSet = false
        press("i")
        controller.editText = text
        controller.applyCurrentEdit()
        select(0)
    }
    func replace(_ value: String) {
        press("c")
        controller.editText = value
        controller.applyCurrentEdit()
    }
    seed("foo other foo, foobar Foo foo.")
    press(">")
    check(controller.text == "foo other foo, foobar Foo foo.", "no previous edit is a no-op")
    replace("bar")
    select(1)
    press(".")
    check(controller.text == "bar bar foo, foobar Foo foo.", "dot still replaces any selected word")
    press(">")
    check(controller.text == "bar bar bar, foobar Foo bar.", "bulk repeat retains original source and word boundaries")
    press(">")
    press("u")
    check(controller.text == "bar bar foo, foobar Foo foo.", "one undo reverts the entire bulk change; no matches do not consume undo")
    check(controller.selectedWord == 1, "bulk undo restores selection")
    press(">")
    check(controller.text == "bar bar bar, foobar Foo bar.", "undo preserves replacement rule")

    seed("foo foo foo")
    replace("foo bar")
    press(">")
    check(controller.text == "foo bar bar foo bar foo bar", "each original match is replaced once even if replacement contains source")

    seed("red fox red fox red wolf")
    select(0, 1)
    replace("blue bird")
    press(">")
    check(controller.text == "blue bird blue bird red wolf", "whole selected phrases match")

    seed("foo foo foo")
    replace("")
    press(">")
    check(controller.text.isEmpty, "empty replacements delete every remaining match")
    press("u")
    check(controller.text == "foo foo", "bulk deletion is undoable")

    seed("foo foo foo")
    select(1)
    press("S")
    select(0)
    replace("bar")
    press(">")
    check(controller.text == "bar bar\n\nbar", "matches across paragraphs preserve paragraph breaks")

    seed("red fox red fox")
    select(2)
    press("S")
    select(0, 1)
    replace("blue bird")
    press(">")
    check(controller.text == "blue bird red\n\nfox", "phrase matching does not cross an unrelated paragraph break")

    seed("foo other foo")
    replace("bar")
    select(1)
    replace("different")
    press("u")
    press(">")
    check(controller.text == "bar other bar", "undo restores both source and replacement")
    controller.dictating = true
    let previous = controller.text
    press(">")
    check(controller.text == previous, "disabled during dictation")
    controller.dictating = false
    press("c")
    press(">")
    check(controller.editText == ">", "greater-than remains literal in edit mode")
    controller.cancelCurrentEdit()
    return failures
}
