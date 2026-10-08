import AppKit

@MainActor
func runShortcutsTests() -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ name: String) {
        if !condition { failures.append("shortcuts: " + name) }
    }
    let controller = DictationController(transcriber: TranscriberService())
    var startRequests = 0
    controller.prepareModels = { startRequests += 1; return false }
    var hidden = false
    controller.onHide = { hidden = true }
    func press(_ characters: String, code: UInt16 = 0) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: 0, windowNumber: 0, context: nil,
                                    characters: characters, charactersIgnoringModifiers: characters,
                                    isARepeat: false, keyCode: code)!
        controller.handleKey(KeyEvent(nsEvent: event))
    }
    let bindings = controller.keyBindings()
    for key in ["?", "u", ".", ">", "c", "C", "t", "J", "S", "A", "D", "o", "O"] {
        check(bindings.contains { $0.hasPrefix(key + ":") }, "\(key) remains listed without selection or edit history")
    }
    controller.handleTranscription(TranscriptionUpdate(text: "Keep these words.", language: "english"))
    controller.dictating = true // No microphone is opened by this test.
    press("?")
    check(controller.showingShortcuts && !controller.dictating, "question mark opens help and pauses")
    controller.startDictation()
    press(" ", code: 49)
    press("R")
    press("o")
    press("O")
    check(startRequests == 0 && !controller.dictating, "all dictation entry points stay paused while help is visible")
    check(controller.text == "Keep these words.", "restart is blocked without clearing text")
    let deadline = Date().addingTimeInterval(2)
    while controller.debugMessage != "Dictation stopped" && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    check(controller.debugMessage == "Dictation stopped" && controller.text == "Keep these words.", "pause finishes and preserves pending text")
    press("?")
    check(!controller.showingShortcuts && startRequests == 1, "closing resumes previously active dictation")
    press(" ", code: 49)
    check(startRequests == 2, "space can request dictation once help is closed")
    controller.toggleShortcuts()
    press("", code: 53)
    check(!controller.showingShortcuts && !hidden, "Escape closes help without discarding")
    check(startRequests == 2, "opening from paused leaves dictation paused on close")
    press("c")
    press("?")
    check(controller.editText == "?" && !controller.showingShortcuts, "question marks remain literal in the editor")
    controller.cancelCurrentEdit()
    controller.dictating = true
    press("?")
    press("?")
    check(startRequests == 2, "rapid close waits for the microphone stop to finish")
    let resumeDeadline = Date().addingTimeInterval(2)
    while startRequests == 2 && Date() < resumeDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    check(startRequests == 3, "rapid close resumes once stopping completes")
    controller.dictating = true
    press("?")
    press("?")
    controller.discardAndHide()
    let cancelDeadline = Date().addingTimeInterval(2)
    while !controller.canStartDictation && Date() < cancelDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    check(startRequests == 3, "discard cancels a queued resume")
    controller.toggleShortcuts()
    controller.beginNewSession()
    check(!controller.showingShortcuts, "new session resets help visibility")
    check(controller.keyBindings() == bindings, "full reference does not change with mode or selection")
    // Refuse microphone startup, then inject recognition updates to exercise the
    // paragraph destination selected by the actual keyboard handlers.
    func pauseAndCommit() {
        controller.dictating = true
        controller.stopDictation()
        let deadline = Date().addingTimeInterval(2)
        while !controller.canStartDictation && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        check(controller.canStartDictation, "paragraph test finishes stopping")
    }
    controller.handleTranscription(TranscriptionUpdate(text: "First paragraph.", language: "english"))
    pauseAndCommit()
    press("O")
    controller.handleTranscription(TranscriptionUpdate(text: "More words.", language: "english"))
    check(controller.text == "First paragraph. More words.", "O appends live text without a paragraph break")
    controller.dictating = true
    let requestsBefore = startRequests
    press("O")
    check(controller.dictating && startRequests == requestsBefore, "O does nothing while dictating")
    pauseAndCommit()
    check(controller.text == "First paragraph. More words.", "continuation keeps its paragraph when committed")
    press(" ", code: 49)
    controller.handleTranscription(TranscriptionUpdate(text: "Second paragraph.", language: "english"))
    pauseAndCommit()
    check(controller.text == "First paragraph. More words.\n\nSecond paragraph.", "Space still resumes into a new paragraph")
    press("O")
    controller.handleTranscription(TranscriptionUpdate(text: "Continued.", language: "english"))
    pauseAndCommit()
    check(controller.text == "First paragraph. More words.\n\nSecond paragraph. Continued.", "O continues the last paragraph and preserves earlier breaks")
    press("o")
    controller.handleTranscription(TranscriptionUpdate(text: "Third paragraph.", language: "english"))
    pauseAndCommit()
    check(controller.text.hasSuffix("Continued.\n\nThird paragraph."), "o still starts a new paragraph after a continuation")
    controller.beginNewSession()
    press("O")
    controller.handleTranscription(TranscriptionUpdate(text: "Fresh text.", language: "english"))
    pauseAndCommit()
    check(controller.text == "Fresh text.", "O works on an empty transcript")
    return failures
}
