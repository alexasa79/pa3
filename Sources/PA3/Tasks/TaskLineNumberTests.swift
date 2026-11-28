import AppKit

@MainActor
func runTaskLineNumberTests() -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ message: String) { if !condition { failures.append("line numbers: " + message) } }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 250),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 250))
    scroll.hasVerticalScroller = true
    let editor = TaskModalTextView(frame: scroll.contentView.bounds)
    editor.isRichText = false
    editor.allowsUndo = true
    editor.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
    editor.textColor = PaperTheme.ink
    editor.backgroundColor = PaperTheme.canvas
    editor.isVerticallyResizable = true
    editor.isHorizontallyResizable = false
    editor.minSize = .zero
    editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    editor.autoresizingMask = [.width]
    editor.textContainer?.widthTracksTextView = true
    scroll.documentView = editor
    let grid = editor.textGrid
    window.contentView = scroll
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(editor)
    defer { window.orderOut(nil) }
    func show(_ id: String, _ body: String) {
        editor.display(documentID: id, body: body)
        editor.sizeToFit()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        window.contentView?.layoutSubtreeIfNeeded()
    }
    show("empty", "")
    check(grid.lineStarts == [0] && editor.visibleLineNumbers.map(\.number) == [1], "empty descriptions show line 1")
    show("blanks", "Title\nbody\n\nend\n")
    check(grid.lineStarts == [0, 6, 11, 12, 16] && editor.visibleLineNumbers.map(\.number) == [1, 2, 3, 4, 5],
          "blank lines and the trailing empty line each receive a number")
    let rows = editor.visibleLineNumbers
    check(zip(rows, rows.dropFirst()).allSatisfy { abs($1.baseline - $0.baseline - grid.rowHeight) < 0.01 },
          "bold text, body text, blank lines, and the final empty line have equal baseline spacing")
    if let layout = editor.layoutManager {
        for start in grid.lineStarts where start < (editor.string as NSString).length {
            let glyph = layout.glyphIndexForCharacter(at: start)
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let position = layout.location(forGlyphAt: glyph)
            check(abs(position.x + fragment.minX - grid.textStartX) < 0.01,
                  "text starts in the first character column after the number cells")
            check(abs(position.y - grid.baseline) < 0.01 && abs(fragment.height - grid.rowHeight) < 0.01,
                  "every row uses the same grid baseline and height")
        }
    }
    show("Unicode", "Title\r\n👨‍👩‍👧‍👦\r\nbody\u{2028}")
    check(grid.lineStarts == [0, 7, 20, 25], "Unicode, CRLF, and Unicode line separators use correct text offsets")

    let wrapped = "Task subject\n" + String(repeating: "A wrapped paragraph with words. ", count: 3) + "\n\n#due:2026-11-15"
    show("wrapped", wrapped)
    check(grid.lineStarts.count == 4 && editor.visibleLineNumbers.prefix(2).map(\.number) == [1, 2],
          "wrapped continuations do not add line numbers")
    if let layout = editor.layoutManager, let container = editor.textContainer {
        layout.ensureLayout(for: container)
        let start = grid.lineStarts[1]
        let glyph = layout.glyphIndexForCharacter(at: start)
        let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let point = NSPoint(x: editor.textContainerOrigin.x,
                            y: editor.textContainerOrigin.y + fragment.minY + layout.location(forGlyphAt: glyph).y)
        check(abs((editor.visibleLineNumbers.first { $0.number == 2 }?.baseline ?? -1000) - point.y) < 0.5,
              "numbers align with native text baselines below the bold subject")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: editor.textContainerOrigin.y + fragment.maxY + 1))
        scroll.reflectScrolledClipView(scroll.contentView)
        check(!editor.visibleLineNumbers.contains { $0.number == 2 }, "scrolling into a wrapped continuation does not repeat its number")
    }
    scroll.contentView.scroll(to: .zero)
    scroll.reflectScrolledClipView(scroll.contentView)
    scroll.displayIfNeeded()
    editor.displayIfNeeded()
    if let bitmap = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds) {
        check(scroll.verticalRulerView == nil && !scroll.rulersVisible, "numbers share the editor instead of using a separate ruler")
        scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/pa3-task-editor-combined.png"))
        var textPixels = 0
        for y in (bitmap.pixelsHigh / 10)..<(bitmap.pixelsHigh * 4 / 5) {
            for x in (bitmap.pixelsWide / 4)..<(bitmap.pixelsWide * 4 / 5) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   min(color.redComponent, color.greenComponent, color.blueComponent) > 0.6 { textPixels += 1 }
            }
        }
        check(textPixels > 100, "the complete scroll view renders description text beside the gutter")
    } else { check(false, "the complete editor renders") }
    let oldBlankBaseline = editor.visibleLineNumbers.first { $0.number == 3 }?.baseline
    window.setContentSize(NSSize(width: 600, height: 250))
    window.contentView?.layoutSubtreeIfNeeded()
    let newBlankBaseline = editor.visibleLineNumbers.first { $0.number == 3 }?.baseline
    check(oldBlankBaseline != nil && newBlankBaseline != nil && newBlankBaseline! < oldBlankBaseline!
          && grid.lineStarts.count == 4, "resizing reflows numbers with their logical lines")

    window.setContentSize(NSSize(width: 920, height: 170))
    let reported = "Find a door that could work for the door in the ceiling.\n\nFirst of all, we have to find the door itself. Then I'd have to install it.\n\nLet's talk about what happens when we're out of control..."
    show("reported-spacing", reported)
    let reportedRows = editor.visibleLineNumbers
    check(reportedRows.map(\.number) == [1, 2, 3, 4, 5]
          && zip(reportedRows, reportedRows.dropFirst()).allSatisfy { abs($1.baseline - $0.baseline - grid.rowHeight) < 0.01 },
          "the reported five-line description has evenly spaced numbers, including both blank lines")
    if let bitmap = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds) {
        scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/pa3-task-text-grid.png"))
    }
    let narrow = grid.textStartX
    show("many", (1...1200).map { "Line \($0)" }.joined(separator: "\n"))
    check(grid.lineStarts.count == 1200 && grid.textStartX > narrow, "reserved character columns expand for four-digit numbers")
    editor.scrollRangeToVisible(NSRange(location: (editor.string as NSString).length, length: 0))
    check(editor.visibleLineNumbers.last?.number == 1200 && editor.visibleLineNumbers.first?.number ?? 0 > 1,
          "scrolling to the bottom shows the corresponding high line numbers")
    show("edit", "Subject\nBody")
    check(grid.textStartX == narrow, "switching back to a short task restores the reserved character columns")
    editor.setMode(.insert)
    editor.insertText("\nMore", replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
    check(grid.lineStarts.count == 3 && editor.string == "Subject\nBody\nMore", "Insert updates numbers without putting them in the text")
    editor.setMode(.normal)
    editor.undoManager?.undo()
    check(grid.lineStarts.count == 2 && editor.string == "Subject\nBody", "undo updates numbering and restores exact plain text")
    editor.finishDictation(original: editor.string, body: "Subject\nBody\nDictated", cursorLocation: 21)
    check(grid.lineStarts.count == 3 && editor.selectedRange().location == 21,
          "finishing dictation refreshes numbers and preserves its final cursor")
    show("tab-stops", "Title\n\tprintf();\n    printf();")
    if let layout = editor.layoutManager, let container = editor.textContainer {
        layout.ensureLayout(for: container)
        let source = editor.string as NSString
        let tabP = source.range(of: "printf();").location
        let spaceP = source.range(of: "printf();", options: [], range: NSRange(location: tabP + 1, length: source.length - tabP - 1)).location
        let tabX = layout.location(forGlyphAt: layout.glyphIndexForCharacter(at: tabP)).x
        let spaceX = layout.location(forGlyphAt: layout.glyphIndexForCharacter(at: spaceP)).x
        check(abs(tabX - spaceX) < 0.5,
              "even pasted literal tabs align to the exact 4-space grid (tabX=\(tabX), spaceX=\(spaceX))")
    }
    return failures
}
