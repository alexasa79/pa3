import AppKit

@MainActor
func runTaskEditorParityTests() -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ message: String) { if !condition { failures.append("Veda parity: " + message) } }
    let pasteboard = NSPasteboard.general
    let originalItems = (pasteboard.pasteboardItems ?? []).map { original in
        let item = NSPasteboardItem()
        for type in original.types { if let data = original.data(forType: type) { item.setData(data, forType: type) } }
        return item
    }
    defer { pasteboard.clearContents(); pasteboard.writeObjects(originalItems) }
    let editor = TaskModalTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
    editor.isRichText = false
    editor.allowsUndo = true
    editor.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
    var sequence = 0
    func show(_ body: String, at point: Int = 0) {
        sequence += 1
        editor.display(documentID: "parity-\(sequence)", body: body)
        editor.setSelectedRange(NSRange(location: point, length: 0))
    }
    func press(_ value: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                    windowNumber: 0, context: nil, characters: value, charactersIgnoringModifiers: value,
                                    isARepeat: false, keyCode: code)!
        editor.keyDown(with: event)
    }
    func keys(_ value: String) { for character in value { press(String(character)) } }
    func escape() { press("", code: 53) }
    func copy(_ text: String) { pasteboard.clearContents(); pasteboard.setString(text, forType: .string) }
    func text(_ expected: String, _ message: String) {
        check(editor.string == expected, "\(message): got \(editor.string.debugDescription), expected \(expected.debugDescription)")
        let lineCount = 1 + expected.filter { $0.isNewline }.count
        check(editor.textGrid.lineStarts.count == lineCount, message + " refreshes actual gutter lines")
    }

    let deletions: [(String, Int, String, String)] = [
        ("one\ntwo\nthree", 9, "dd", "one\ntwo"),
        ("one\ntwo\n", 8, "dd", "one\ntwo"),
        ("\n", 1, "dd", ""),
        ("one\n\n", 5, "dd", "one\n"),
        ("one\ntwo\nthree", 4, "2dd", "one"),
        ("one\ntwo\n", 4, "2dd", "one"),
        ("one\ntwo\nthree", 0, "99dd", ""),
        ("one\r\ntwo\r\nthree", 11, "dd", "one\r\ntwo"),
        ("one\r\n", 5, "dd", "one"),
        ("one\u{2028}two", 5, "dd", "one"),
        ("Title\n👨‍👩‍👧‍👦\nlast", 19, "dd", "Title\n👨‍👩‍👧‍👦")
    ]
    for (body, point, command, expected) in deletions {
        show(body, at: point); keys(command)
        text(expected, "\(command) removes whole final logical lines")
        check(editor.visibleLineNumbers.last?.number == 1 + expected.filter { $0.isNewline }.count,
              "the visible gutter loses the deleted line")
        press("u"); text(body, "whole-line deletion undoes as one edit")
        press("U"); text(expected, "whole-line deletion redoes without a phantom line")
    }
    show("one\ntwo\nthree\nfour\nfive", at: 19)
    keys("dd"); check(editor.textGrid.lineStarts.count == 4, "the reported five-line task becomes four lines")
    keys("dd"); check(editor.textGrid.lineStarts.count == 3, "repeated dd reduces the actual line count")
    show("a\nb\nc\nd\ne\nf\ng")
    keys("2d3d"); text("g", "prefix and infix counts multiply")

    for (body, point, command, cleared) in [
        ("one\ntwo\nthree", 5, "cc", "one\n\nthree"),
        ("one\ntwo", 5, "cc", "one\n"),
        ("one\ntwo\nthree", 4, "2cc", "one\n"),
        ("one\ntwo\nthree", 0, "2cc", "\nthree")
    ] {
        show(body, at: point); keys(command)
        text(cleared, "\(command) preserves one empty line for replacement text")
        check(editor.mode == .insert, command + " enters Insert")
        editor.insertText("new", replacementRange: editor.selectedRange())
        escape(); press("u")
        text(body, command + " and its typed replacement undo together")
    }
    for (body, point, command, expected) in [
        ("hello_world next", 4, "dw", "next"),
        ("hello_world next", 4, "dW", "hell next"),
        ("alpha\nbeta", 2, "dw", "\nbeta"),
        ("a   b", 2, "dw", "a b"),
        ("a... b", 2, "dw", "a.. b"),
        ("alpha beta gamma", 2, "2dw", "gamma")
    ] {
        show(body, at: point); keys(command); text(expected, command + " uses Veda word boundaries")
        press("u"); text(body, command + " undoes exactly")
    }
    for (command, expected) in [("cw", " next"), ("cW", "hell next"), ("C", "hell"), ("c$", "hell")] {
        let body = "hello_world next"
        show(body, at: 4); keys(command); text(expected, command + " clears the expected text")
        editor.insertText("X", replacementRange: editor.selectedRange()); escape(); press("u")
        text(body, command + " and insertion form one undo group")
    }
    show("alpha beta gamma", at: 2); keys("2cw"); text(" gamma", "counted cw leaves trailing separator untouched"); escape()
    show("a b c d e f g"); keys("2d3w"); text("g", "word operator counts multiply")

    show("one\ntwo", at: 5); keys("yy")
    check(pasteboard.string(forType: .string) == "two\n", "yy on the last line copies linewise")
    check(editor.selectedRange().location == 5 && editor.string == "one\ntwo", "yy preserves text and cursor")
    for (body, point, command, clipboard, expected, cursor) in [
        ("ABC\nDEF", 5, "p", "123", "ABC\nDE123F", 8),
        ("ABC\nDEF", 5, "P", "123", "ABC\nD123EF", 7),
        ("a\nb", 0, "p", "new\n", "a\nnew\nb", 0),
        ("a\nb", 2, "P", "new\n", "a\nnew\nb", 6),
        ("a", 0, "p", "new\n", "a\nnew\n", 6),
        ("a\nb", 0, "2p", "new\n", "a\nnew\nnew\nb", 0),
        ("👨‍👩‍👧‍👦x", 0, "p", "é", "👨‍👩‍👧‍👦éx", 11)
    ] {
        show(body, at: point); copy(clipboard); keys(command)
        text(expected, command + " chooses linewise or characterwise placement")
        check(editor.selectedRange().location == cursor, command + " leaves the cursor at its intended position")
        press("u"); text(body, command + " undoes as one edit")
    }
    show("one\ntwo", at: 1); keys("yy"); press("p"); text("one\none\ntwo", "yy followed by p duplicates the whole line")
    show("ABC"); editor.setSelectedRange(NSRange(location: 1, length: 1)); copy("xyz"); press("p")
    text("AxyzC", "modal paste still replaces an explicit native selection")

    for (body, command, expected) in [
        ("one\n  two", "J", "one two"), ("one \n\ttwo", "J", "one two"),
        ("one\n   ", "J", "one"), ("\n  two", "J", "two"),
        ("one\r\n two", "J", "one two"), ("one\ntwo\nthree", "2J", "one two three")
    ] {
        show(body); keys(command); text(expected, command + " joins without stray indentation or duplicate spaces")
        press("u"); text(body, command + " undoes the complete join")
    }

    for (body, point, command, expected) in [
        ("foo_bar next", 0, "w", 8), ("foo_bar next", 0, "W", 3),
        ("foo_bar next", 4, "B", 0), ("hello, world! foo-bar", 17, "b", 14),
        ("alpha\nbeta", 0, "w", 4), ("alpha\nbeta", 4, "w", 6),
        ("a... b", 1, "w", 2), ("alpha", 0, "$", 4),
        ("a\nb", 0, "h", 0), ("a\nb", 0, "l", 0),
        ("first\nlast\n", 0, "G", 9)
    ] {
        show(body, at: point); keys(command)
        check(editor.selectedRange().location == expected, "\(command) moves to \(expected), got \(editor.selectedRange().location)")
        text(body, command + " leaves text untouched")
    }
    let wrapped = String(repeating: "word ", count: 40) + "\nnext"
    show(wrapped, at: 80); keys("0"); check(editor.selectedRange().location == 0, "0 reaches logical line start across wrapping")
    keys("$"); check(editor.selectedRange().location == 199, "$ reaches the last character of the logical wrapped line")
    keys("A"); check(editor.selectedRange().location == 200 && editor.mode == .insert, "A appends at logical line end"); escape()
    show("\nnext"); keys("a"); check(editor.selectedRange().location == 0, "a on an empty line does not cross its newline"); escape()
    show("A 👨‍👩‍👧‍👦"); keys("A"); escape()
    check(editor.selectedRange().location == 2, "Escape from Insert moves back one whole Unicode character")
    for (body, point, command, expected) in [
        ("  one\ntwo", 2, "o", "  one\n  \ntwo"),
        ("  one\ntwo", 6, "O", "  one\n  \ntwo"),
        ("  one", 2, "O", "\n  one")
    ] {
        show(body, at: point); keys(command); text(expected, command + " uses Veda's plain-text indentation context")
        editor.insertText("X", replacementRange: editor.selectedRange()); escape(); press("u")
        text(body, command + " and typing undo as one Insert session")
    }
    show("  one", at: 5); press("i"); press("\r", code: 36)
    text("  one\n  ", "Insert Return carries plain-text indentation")
    escape(); press("u"); text("  one", "Return and indentation undo together")
    show("abcdef"); press("x"); press("x"); keys("2u"); text("abcdef", "counted undo restores separate edits")
    keys("2U"); text("cdef", "counted redo reapplies separate edits")
    press("u"); press("u"); press("2"); press("r", flags: .control)
    text("cdef", "the PA3 Control-R redo alias honors a count")
    press("u", flags: .option); text("cdef", "unimplemented Option-U does not accidentally undo")
    show("a\nb", at: 2); press("\u{f702}", code: 123)
    check(editor.selectedRange().location == 2, "plain Normal Left does not cross a logical line boundary")
    show("abc"); editor.setSelectedRange(NSRange(location: 0, length: 2)); press("\u{f703}", code: 124)
    check(editor.selectedRange().location == 2, "native Right collapses an explicit selection")
    return failures
}
