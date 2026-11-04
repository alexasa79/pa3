import AppKit

@MainActor
func runClipboardInsertionTests() -> [String] {
    var failures: [String] = []
    let pasteboard = NSPasteboard.general
    let savedItems = (pasteboard.pasteboardItems ?? []).map { item in
        item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
    }
    defer {
        pasteboard.clearContents()
        let items = savedItems.map { entries in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }
    let controller = DictationController(transcriber: TranscriberService())
    var starts = 0
    controller.prepareModels = { starts += 1; return false } // No microphone or models.
    func check(_ condition: Bool, _ name: String) {
        if !condition { failures.append("clipboard: " + name + " [" + controller.text + "]") }
    }
    func press(_ characters: String) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: 0, windowNumber: 0, context: nil,
                                    characters: characters, charactersIgnoringModifiers: characters,
                                    isARepeat: false, keyCode: characters == " " ? 49 : 0)!
        controller.handleKey(KeyEvent(nsEvent: event))
    }
    func clipboard(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
    func seed(_ text: String) {
        controller.beginNewSession()
        update(text)
        controller.dictating = true // Commit a transcript without opening capture.
        controller.stopDictation()
        waitForStop()
    }
    func select(_ index: Int) {
        controller.selectedWord = index
        controller.selectionStart = index
        controller.selectionEnd = index
    }
    func update(_ text: String) {
        controller.handleTranscription(TranscriptionUpdate(text: text, language: "english"))
    }
    func waitForStop() {
        let deadline = Date().addingTimeInterval(2)
        while !controller.canStartDictation && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        check(controller.canStartDictation, "stop completes")
    }
    for key in ["v", "V"] {
        seed("First words.\n\nLast paragraph.")
        select(0)
        clipboard("  API_Name\n  NASA  ")
        press(key)
        let pasted = key == "v" ? "First API_Name NASA words.\n\nLast paragraph." :
            "First words.\n\nAPI_Name NASA\n\nLast paragraph."
        check(controller.text == pasted, "\(key) inserts at current word/paragraph and normalizes clipboard whitespace")
        press("u")
        check(controller.text == "First words.\n\nLast paragraph." && controller.selectedWord == 0,
              "\(key) is one undoable edit restoring the selection")
        press(key)
        press(" ")
        controller.dictating = true
        update("Draft.")
        update("And it works.")
        let expected = key == "v" ? "First API_Name NASA and it works. words.\n\nLast paragraph." :
            "First words.\n\nAPI_Name NASA\n\nAnd it works.\n\nLast paragraph."
        check(controller.text == expected, "\(key) resumes in place with boundary-aware punctuation and capitalization")
        let tail = controller.words.firstIndex(of: "Last")!
        check(controller.tokens()[..<tail].contains(where: \.pending) &&
              !controller.tokens()[tail...].contains(where: \.pending), "only speech is pending before preserved suffix")
        controller.stopDictation()
        waitForStop()
        check(controller.text == expected, "\(key) continuation commits without moving suffix")
    }
    seed("")
    clipboard("One")
    press("v")
    press("v")
    check(controller.text == "One One", "repeated inline pastes stay inline")
    press("u")
    press(" ")
    update("Two.")
    check(controller.text == "One two.", "undo restores the earlier paste continuation")

    seed("one two three")
    clipboard("first")
    select(0)
    press("v")
    select(2)
    clipboard("second")
    press("v")
    check(controller.text == "one first two second three", "a second paused paste follows the newly selected word")
    press("c")
    controller.editText = "changed"
    controller.applyCurrentEdit()
    press(" ")
    update("New paragraph.")
    check(controller.text == "one first two changed three\n\nNew paragraph.", "manual editing clears a stale paste continuation")

    seed("Unchanged.")
    clipboard(" \n ")
    press("v")
    press("V")
    check(controller.text == "Unchanged.", "empty clipboard is a no-op")
    press(" ")
    update("New paragraph.")
    check(controller.text == "Unchanged.\n\nNew paragraph.", "empty paste does not change default resume")

    for key in ["v", "V"] {
        seed("")
        controller.dictating = true
        update("The setting is.")
        clipboard("foo")
        let before = starts
        press(key)
        // A second paste during shutdown must not schedule another restart.
        press(key)
        waitForStop()
        check(starts == before + 1, "\(key) restarts once after live paste")
        update("And it works.")
        let expected = key == "v" ? "The setting is foo and it works." :
            "The setting is.\n\nfoo\n\nAnd it works."
        check(controller.text == expected, "\(key) live paste handles sentence joins")
    }
    for (pasted, expected) in [
        ("foo", "The setting is foo and it works."),
        ("the new setting", "The setting is the new setting and it works."),
        ("Done.", "The setting is. Done. And it works."),
        ("It works!", "The setting is. It works! And it works."),
        ("Ready?", "The setting is. Ready? And it works."),
        ("“It works.”", "The setting is. “It works.” And it works.")
    ] {
        seed("The setting is.")
        clipboard(pasted)
        press("v")
        press(" ")
        update("A draft.")
        update("And it works.")
        check(controller.text == expected, "ending punctuation determines how to join \(pasted)")
        controller.dictating = true
        controller.stopDictation()
        waitForStop()
        check(controller.text == expected, "smart join remains unchanged when committed")
    }
    seed("Keep this. Following sentence.\n\nLast paragraph.")
    select(0)
    clipboard("Pasted sentence.")
    press("v")
    check(controller.text == "Keep this. Pasted sentence. Following sentence.\n\nLast paragraph.",
          "sentence paste follows the selected sentence and keeps its punctuation")
    press("u")
    check(controller.text == "Keep this. Following sentence.\n\nLast paragraph." && controller.selectedWord == 0,
          "sentence paste and its boundary adjustment undo together")
    seed("The setting is")
    clipboard("This works.")
    press("v")
    check(controller.text == "The setting is. This works.", "sentence paste completes an unpunctuated prefix")
    for punctuation in [".", ",", ":", ";", "!", "?"] {
        seed("Use the setting" + punctuation)
        clipboard("foo")
        press("v")
        check(controller.text == "Use the setting foo", "fragment removes preceding boundary punctuation \(punctuation)")
        press("u")
        check(controller.text == "Use the setting" + punctuation, "undo restores removed punctuation")
    }
    for prefix in ["Ask Dr.", "Use NASA.", "Version 3.", "Use e.g.", "Wait..."] {
        seed(prefix)
        clipboard("foo")
        press("v")
        check(controller.text == prefix + " foo", "ambiguous period in \(prefix) is preserved")
    }
    for name in ["Alice", "NASA", "iPhone", "I", "Will", "May"] {
        seed("Ask")
        clipboard("someone")
        press("v")
        press(" ")
        update(name + " can help.")
        check(controller.text == "Ask someone " + name + " can help.", "continuation preserves \(name)")
    }
    check(clipboardFragmentPrefix("המילה היא.") == "המילה היא", "fragment joins work in scripts without letter casing")
    check(clipboardPasteIsSentence("“שלום!”") && clipboardPasteIsSentence("هل يعمل؟"),
          "sentence classification recognizes quoted and Arabic sentence endings")
    check(!clipboardPasteIsSentence("several words,") && !clipboardPasteIsSentence("the setting:"),
          "commas and colons do not classify fragments as complete sentences")
    for (spoken, expected) in [
        ("Works perfectly. Another sentence.", "works perfectly. Another sentence."),
        ("Running smoothly.", "running smoothly."),
        ("A useful option.", "a useful option."),
        ("An ordinary word.", "an ordinary word."),
        ("Will help.", "will help."),
        ("May be useful.", "may be useful."),
        ("Beautiful flowers.", "beautiful flowers."),
        ("Continuation.", "continuation."),
        ("“Works perfectly.”", "“works perfectly.”"),
        ("Alice can help.", "Alice can help."),
        ("London is nice.", "London is nice."),
        ("NASA can help.", "NASA can help."),
        ("OpenAI can help.", "OpenAI can help."),
        ("iPhone works.", "iPhone works."),
        ("I can help.", "I can help.")
    ] {
        seed("Use the setting.")
        clipboard("foo")
        press("v")
        press(" ")
        update("Initial draft.")
        update(spoken)
        check(controller.text == "Use the setting foo " + expected,
              "fragment corrects the first continuation word in \(spoken)")
        controller.dictating = true
        controller.stopDictation()
        waitForStop()
        check(controller.text == "Use the setting foo " + expected, "continuation casing survives commit")
    }
    seed("Use the setting. Works perfectly.\n\nNext paragraph.")
    select(controller.words.firstIndex(of: ".")!)
    clipboard("foo")
    press("v")
    check(controller.text == "Use the setting foo works perfectly.\n\nNext paragraph.",
          "fragment lowercases an existing remainder without changing later sentences or paragraphs")
    press("u")
    check(controller.text == "Use the setting. Works perfectly.\n\nNext paragraph.",
          "undo restores both punctuation and remainder casing")
    for key in ["v", "V"] {
        seed("Use the setting.")
        clipboard("Done.")
        press(key)
        press(" ")
        update("Works perfectly.")
        check(controller.text.hasSuffix("Done." + (key == "v" ? " " : "\n\n") + "Works perfectly."),
              "sentence and paragraph pastes retain sentence-start capitalization")
    }
    check(controller.keyBindings().contains { $0.hasPrefix("v:") } &&
          controller.keyBindings().contains { $0.hasPrefix("V:") }, "both paste commands are listed in help")
    seed("First.\n\nLast.")
    select(0)
    press("o")
    controller.dictating = true
    update("Middle")
    clipboard("inserted")
    press("v")
    waitForStop()
    update("Continuation.")
    check(controller.text == "First.\n\nMiddle inserted continuation.\n\nLast.",
          "live paste in an inserted paragraph preserves later paragraphs")
    controller.beginNewSession()
    press(" ")
    update("Fresh.")
    check(controller.text == "Fresh.", "new session clears clipboard continuation")
    return failures
}
