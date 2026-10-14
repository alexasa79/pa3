import AppKit

@MainActor
func runShortcutsTests() -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ name: String) {
        if !condition { failures.append("shortcuts: " + name) }
    }
    let controller = DictationController(transcriber: TranscriberService())
    check(controller.characterCount == 0 && controller.wordCount == 0 && controller.transcriptionIterations == 0,
          "empty session starts with zero statistics")
    check(controller.status == "Dictation paused", "new window has a single paused status")
    controller.dictating = true // Exercise display state without opening a microphone.
    for message in ["Starting Whisper...", "Starting Whisper... 179s", "Waiting for Whisper..."] {
        controller.serviceMessage = message
        controller.debugMessage = message
        check(controller.startingWhisper && controller.status == "Starting Whisper…" && controller.statusDetail.isEmpty,
              "Whisper startup appears in the header without a duplicate footer message")
        controller.dictating = false
        check(!controller.startingWhisper && controller.status == "Dictation paused",
              "startup messages cannot make paused dictation appear active")
        controller.dictating = true
    }
    for message in ["Dictation active", "Transcribing...", "Whisper ready"] {
        controller.serviceMessage = message
        controller.debugMessage = message
        check(!controller.startingWhisper && controller.status == "Dictation active" && controller.statusDetail.isEmpty,
              "recognition batches do not change status or add a duplicate label")
        controller.handleTranscription(TranscriptionUpdate(text: "Words from the latest batch.", language: "english"))
        check(controller.status == "Dictation active" && controller.statusDetail.isEmpty,
              "new transcript text does not change status or display a character count")
    }
    check(controller.transcriptionIterations == 3, "unchanged recognition results count as separate iterations")
    controller.handleTranscription(TranscriptionUpdate(text: "Hi, שלום 👨‍👩‍👧‍👦!", language: "english"))
    check(controller.characterCount == 10 && controller.wordCount == 2,
          "statistics count Unicode characters and words without counting punctuation or emoji as words (\(controller.characterCount) characters, \(controller.wordCount) words in \(controller.text))")
    check(controller.transcriptionIterations == 4, "statistics count transcription results rather than status messages")
    controller.debugMessage = "Whisper failed to start"
    check(controller.statusDetail == "Whisper failed to start", "service failures remain visible")
    controller.dictating = false
    controller.spellChecking = true
    check(controller.status == "Checking spelling…", "spell checking has a clear status")
    controller.spellChecking = false
    controller.beginNewSession()
    check(controller.characterCount == 0 && controller.wordCount == 0 && controller.transcriptionIterations == 0,
          "new session resets statistics")
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
    check(controller.status == "Finishing transcription…", "stopping reports pending transcription immediately")
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
    check(controller.status == "Dictation paused" && controller.statusDetail.isEmpty,
          "completed stop shows a single steady paused status")
    check(controller.transcriptionIterations == 1 && controller.wordCount == 3 && controller.characterCount == 17,
          "pausing preserves transcript statistics without adding an iteration")
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
    controller.restartDictation()
    check(controller.characterCount == 0 && controller.wordCount == 0 && controller.transcriptionIterations == 0,
          "restart resets transcript statistics")
    return failures
}
