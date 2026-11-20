import AppKit

@MainActor
func runTaskTextNavigationTests() -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ message: String) { if !condition { failures.append("text navigation: " + message) } }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 160),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 160))
    scroll.hasVerticalScroller = true
    let editor = TaskModalTextView(frame: NSRect(x: 0, y: 0, width: 580, height: 2400))
    editor.isRichText = false
    editor.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
    editor.isVerticallyResizable = true
    editor.autoresizingMask = [.width]
    editor.textContainer?.widthTracksTextView = true
    scroll.documentView = editor
    window.contentView = scroll
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(editor)
    defer { window.orderOut(nil) }

    let characters: [UInt16: String] = [123: "\u{f702}", 124: "\u{f703}", 125: "\u{f701}", 126: "\u{f700}",
                                       115: "\u{f729}", 119: "\u{f72b}", 116: "\u{f72c}", 121: "\u{f72d}"]
    func press(_ code: UInt16, flags: NSEvent.ModifierFlags = [], text: String? = nil, equivalent: Bool = false) {
        let key = text ?? characters[code] ?? ""
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil, characters: key,
                                    charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
        if equivalent { check(editor.performKeyEquivalent(with: event), "Command navigation is handled before menu equivalents") }
        else { editor.keyDown(with: event) }
    }

    let body = "alpha beta gamma\nsecond line here\nthird line"
    for mode in [TaskEditorMode.normal, .insert] {
        editor.display(documentID: "navigation-\(mode)", body: body)
        editor.setMode(mode)
        func expect(_ name: String, from start: Int, code: UInt16, flags: NSEvent.ModifierFlags = [],
                    range: NSRange, text: String? = nil, equivalent: Bool = false) {
            editor.setSelectedRange(NSRange(location: start, length: 0))
            press(code, flags: flags, text: text, equivalent: equivalent)
            check(editor.selectedRange() == range, "\(mode) \(name): got \(editor.selectedRange()), expected \(range)")
            check(editor.mode == mode && editor.string == body, "\(mode) \(name) preserves the mode and text")
        }
        expect("Home", from: 26, code: 115, range: NSRange(location: 17, length: 0))
        expect("End", from: 26, code: 119, range: NSRange(location: 33, length: 0))
        expect("Shift-Home", from: 26, code: 115, flags: .shift, range: NSRange(location: 17, length: 9))
        expect("Shift-End", from: 26, code: 119, flags: .shift, range: NSRange(location: 26, length: 7))
        expect("Control-Home", from: 26, code: 115, flags: .control, range: NSRange(location: 0, length: 0))
        expect("Control-End", from: 26, code: 119, flags: .control, range: NSRange(location: 44, length: 0))
        expect("Control-Shift-End", from: 26, code: 119, flags: [.control, .shift], range: NSRange(location: 26, length: 18))
        expect("Command-Left", from: 26, code: 123, flags: .command, range: NSRange(location: 17, length: 0), equivalent: true)
        expect("Command-Right", from: 26, code: 124, flags: .command, range: NSRange(location: 33, length: 0), equivalent: true)
        expect("Command-Up", from: 26, code: 126, flags: .command, range: NSRange(location: 0, length: 0), equivalent: true)
        expect("Command-Down", from: 26, code: 125, flags: .command, range: NSRange(location: 44, length: 0), equivalent: true)
        expect("Command-Shift-Up", from: 26, code: 126, flags: [.command, .shift], range: NSRange(location: 0, length: 26), equivalent: true)
        expect("Command-Shift-Right", from: 26, code: 124, flags: [.command, .shift], range: NSRange(location: 26, length: 7), equivalent: true)
        for modifier in [NSEvent.ModifierFlags.control, .option] {
            expect("\(modifier) Right", from: 0, code: 124, flags: modifier, range: NSRange(location: 5, length: 0))
            expect("\(modifier) Left", from: 10, code: 123, flags: modifier, range: NSRange(location: 6, length: 0))
            expect("\(modifier) Shift-Right", from: 0, code: 124, flags: [modifier, .shift], range: NSRange(location: 0, length: 5))
            expect("\(modifier) Shift-Left", from: 10, code: 123, flags: [modifier, .shift], range: NSRange(location: 6, length: 4))
            expect("\(modifier) Up", from: 26, code: 126, flags: modifier, range: NSRange(location: 17, length: 0))
            expect("\(modifier) Down", from: 26, code: 125, flags: modifier, range: NSRange(location: 33, length: 0))
        }
        expect("Left", from: 6, code: 123, range: NSRange(location: 5, length: 0))
        expect("Right", from: 6, code: 124, range: NSRange(location: 7, length: 0))
        expect("Up", from: 17, code: 126, range: NSRange(location: 0, length: 0))
        expect("Down", from: 0, code: 125, range: NSRange(location: 17, length: 0))
        expect("Shift-Left", from: 6, code: 123, flags: .shift, range: NSRange(location: 5, length: 1))
        expect("Shift-Right", from: 6, code: 124, flags: .shift, range: NSRange(location: 6, length: 1))
        expect("Control-A", from: 26, code: 0, flags: .control, range: NSRange(location: 17, length: 0), text: "a")
        expect("Control-E", from: 26, code: 14, flags: .control, range: NSRange(location: 33, length: 0), text: "e")
        expect("Control-B", from: 26, code: 11, flags: .control, range: NSRange(location: 25, length: 0), text: "b")
        expect("Control-F", from: 26, code: 3, flags: .control, range: NSRange(location: 27, length: 0), text: "f")
        expect("Control-P", from: 17, code: 35, flags: .control, range: NSRange(location: 0, length: 0), text: "p")
        expect("Control-N", from: 0, code: 45, flags: .control, range: NSRange(location: 17, length: 0), text: "n")
        expect("translated Fn-Left/Home", from: 26, code: 123, range: NSRange(location: 17, length: 0), text: "\u{f729}")

        let unicode = "A 👨‍👩‍👧‍👦 שלום B"
        let emoji = (unicode as NSString).range(of: "👨‍👩‍👧‍👦")
        editor.display(documentID: "unicode-\(mode)", body: unicode)
        editor.setMode(mode)
        editor.setSelectedRange(NSRange(location: emoji.location, length: 0))
        press(124)
        check(editor.selectedRange().location == NSMaxRange(emoji), "\(mode) Right skips a whole composed character")
        press(123)
        check(editor.selectedRange().location == emoji.location, "\(mode) Left skips a whole composed character")
        press(124, flags: .shift)
        check(editor.selectedRange() == emoji, "\(mode) Shift-Right selects the whole composed character")
        check(editor.string == unicode && editor.mode == mode, "Unicode navigation preserves text and mode")

        let longBody = (0..<120).map { "Line \($0) with words" }.joined(separator: "\n")
        editor.display(documentID: "pages-\(mode)", body: longBody)
        editor.setMode(mode)
        editor.sizeToFit()
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.scrollRangeToVisible(editor.selectedRange())
        press(121)
        check(editor.selectedRange().location > 0, "\(mode) Page Down moves through a long description")
        editor.setSelectedRange(NSRange(location: (longBody as NSString).length, length: 0))
        editor.scrollRangeToVisible(editor.selectedRange())
        press(116)
        check(editor.selectedRange().location < (longBody as NSString).length, "\(mode) Page Up moves through a long description")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.scrollRangeToVisible(editor.selectedRange())
        press(121, flags: .shift)
        check(editor.selectedRange().length > 0, "\(mode) Shift-Page Down extends selection")
        check(editor.string == longBody && editor.mode == mode, "page navigation preserves text and mode")
    }
    editor.display(documentID: "vim-count", body: body)
    press(20, text: "3"); press(124)
    check(editor.selectedRange().location == 3, "Normal arrow movement preserves Vim counts")
    editor.setSelectedRange(NSRange(location: 0, length: 0))
    press(13, text: "w")
    check(editor.selectedRange().location == 6, "Vim w still moves to the next word start")
    return failures
}
