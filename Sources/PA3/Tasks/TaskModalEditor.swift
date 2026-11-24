import AppKit
import SwiftUI

enum TaskEditorMode: String { case normal = "NORMAL", insert = "INSERT", dictation = "DICTATION" }

struct TaskEditorView: NSViewRepresentable {
    @ObservedObject var model: TaskManagerModel

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.automaticallyAdjustsContentInsets = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let editor = TaskModalTextView(frame: scroll.contentView.bounds)
        editor.isRichText = false
        editor.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        editor.textColor = PaperTheme.ink
        editor.backgroundColor = PaperTheme.canvas
        editor.insertionPointColor = .clear
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.allowsUndo = true
        editor.usesFindBar = true
        editor.isIncrementalSearchingEnabled = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        editor.onChange = { [weak model] text in model?.edit(text) }
        editor.onMode = { [weak model] mode in model?.changeEditorMode(mode) }
        editor.onDictation = { [weak model] in model?.beginDictation() }
        editor.onSave = { [weak model] in Task { await model?.flush() } }
        editor.setAccessibilityLabel("Task description")
        scroll.documentView = editor
        model.editor = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? TaskModalTextView else { return }
        let desiredMode = model.editorMode
        if model.editorMode != .dictation { editor.display(documentID: model.selectedTaskID, body: model.draft) }
        editor.isEditable = model.selectedTaskID != nil && !model.busy && model.editorMode != .dictation
        editor.isSelectable = model.selectedTaskID != nil
        if desiredMode != .dictation, editor.mode != desiredMode { editor.setMode(desiredMode, notify: false) }
    }
}

/// Veda-style commands on native text storage. Native insertion preserves IME,
/// composed Unicode characters, exact whitespace, and bidirectional layout.
@MainActor
final class TaskModalTextView: NSTextView {
    let textGrid = TaskTextGrid()
    private(set) var mode: TaskEditorMode = .normal
    private var documentID: String?
    private var pending = ""
    private var pendingCount = 1
    private var countText = ""
    private var yank = ""
    private var histories: [String: UndoManager] = [:]
    private var documentTexts: [String: String] = [:]
    private var groupedInsertion = false
    var onChange: ((String) -> Void)?
    var onMode: ((TaskEditorMode) -> Void)?
    var onDictation: (() -> Void)?
    var onSave: (() -> Void)?
    override var undoManager: UndoManager? { documentID.flatMap { histories[$0] } }

    func display(documentID id: String?, body: String) {
        guard id != documentID || body != string else { return }
        let switching = id != documentID
        if let documentID { documentTexts[documentID] = string }
        // Rendering a document must not publish a mode change back into SwiftUI.
        // The model supplies the mode separately in updateNSView.
        setMode(.normal, notify: false)
        documentID = id
        if let id, histories[id] == nil {
            let history = UndoManager()
            history.groupsByEvent = false
            history.levelsOfUndo = 100
            histories[id] = history
        }
        // A cloud replacement invalidates older undo offsets. Dictation previews
        // are instead consolidated into one undoable edit by finishDictation.
        undoManager?.disableUndoRegistration()
        string = body
        undoManager?.enableUndoRegistration()
        applySubjectStyle()
        if !switching || id.flatMap({ documentTexts[$0] }) != body { undoManager?.removeAllActions() }
        if let id { documentTexts[id] = body }
        setSelectedRange(NSRange(location: 0, length: 0))
    }

    func setMode(_ next: TaskEditorMode, notify: Bool = true) {
        let changed = mode != next
        if groupedInsertion {
            undoManager?.endUndoGrouping()
            groupedInsertion = false
        }
        breakUndoCoalescing()
        mode = next
        insertionPointColor = next == .insert ? PaperTheme.ink : .clear
        pending = ""; pendingCount = 1; countText = ""
        if next == .insert, undoManager != nil {
            undoManager?.beginUndoGrouping()
            groupedInsertion = true
        }
        if notify, changed { onMode?(next) }
        updateInsertionPointStateAndRestartTimer(true)
        needsDisplay = true
    }

    func finishDictation(original: String, body: String, cursorLocation: Int) {
        // The model disables typing while draining dictation. AppKit otherwise
        // rejects the undoable replacement and a later refresh resets the caret.
        let editable = isEditable
        isEditable = true
        defer { isEditable = editable }
        undoManager?.disableUndoRegistration()
        string = original
        undoManager?.enableUndoRegistration()
        setMode(.normal)
        if body != original { replace(NSRange(location: 0, length: (original as NSString).length), with: body) }
        applySubjectStyle()
        let location = min(max(0, cursorLocation), (string as NSString).length)
        setSelectedRange(NSRange(location: location, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    override func didChangeText() {
        super.didChangeText()
        applySubjectStyle()
        if let documentID { documentTexts[documentID] = string }
        onChange?(string)
    }

    /// Presentation only: task contents and clipboard operations remain plain text.
    private func applySubjectStyle() {
        guard let storage = textStorage else { return }
        let source = string as NSString
        let newline = source.rangeOfCharacter(from: .newlines)
        let subjectLength = newline.location == NSNotFound ? source.length : newline.location
        let regular = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 16, weight: .bold)
        textGrid.update(body: string)
        let paragraph = textGrid.paragraphStyle
        layoutManager?.delegate = textGrid
        textContainer?.lineFragmentPadding = 0
        textContainerInset = NSSize(width: 0, height: textGrid.rowHeight)
        defaultParagraphStyle = paragraph
        let history = undoManager
        let registering = history?.isUndoRegistrationEnabled == true
        if registering { history?.disableUndoRegistration() }
        storage.beginEditing()
        storage.addAttribute(.font, value: regular, range: NSRange(location: 0, length: source.length))
        storage.addAttribute(.font, value: bold, range: NSRange(location: 0, length: subjectLength))
        storage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: source.length))
        storage.endEditing()
        if registering { history?.enableUndoRegistration() }
        typingAttributes[.font] = selectedRange().location <= subjectLength ? bold : regular
        typingAttributes[.paragraphStyle] = paragraph
        needsDisplay = true
    }

    override var shouldDrawInsertionPoint: Bool {
        mode == .insert && super.shouldDrawInsertionPoint
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        if mode == .insert { super.drawInsertionPoint(in: rect, color: color, turnedOn: flag) }
    }

    /// Draw with the text rather than AppKit's blinking insertion indicator,
    /// whose modern implementation can bypass drawInsertionPoint entirely.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawLineNumbers(in: dirtyRect)
        if let rect = normalCursorRect {
            (textColor ?? PaperTheme.ink).withAlphaComponent(0.45).setFill()
            rect.fill()
        }
    }

    var normalCursorRect: NSRect? {
        guard mode == .normal, isEditable, !hasMarkedText(), selectedRange().length == 0,
              let window, window.isKeyWindow, window.firstResponder === self else { return nil }
        let source = string as NSString
        let location = min(selectedRange().location, source.length)
        let caret = firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
        var rect = convert(window.convertFromScreen(caret), from: nil)
        guard rect.height > 0 else { return nil }
        let cursorFont = font ?? .monospacedSystemFont(ofSize: 16, weight: .regular)
        rect.size.width = ("M" as NSString).size(withAttributes: [.font: cursorFont]).width
        if location < source.length {
            let character = source.rangeOfComposedCharacterSequence(at: location)
            if source.substring(with: character).rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
                let glyph = firstRect(forCharacterRange: character, actualRange: nil)
                if glyph.width > 0 {
                    rect.origin.x = convert(window.convertFromScreen(glyph), from: nil).minX
                    rect.size.width = glyph.width
                }
            }
        }
        return rect
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        needsDisplay = true
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        needsDisplay = true
        return result
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.removeObserver(self, name: name, object: nil)
            if let window { NotificationCenter.default.addObserver(self, selector: #selector(refreshCursor), name: name, object: window) }
        }
    }

    @objc private func refreshCursor(_ notification: Notification) {
        needsDisplay = true
    }

    func replaceDocument(with body: String) {
        setMode(.normal)
        replace(NSRange(location: 0, length: (string as NSString).length), with: body)
    }

    private func replace(_ range: NSRange, with text: String) {
        let ownGroup = undoManager?.groupingLevel == 0
        if ownGroup { undoManager?.beginUndoGrouping() }
        defer { if ownGroup { undoManager?.endUndoGrouping() } }
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
        didChangeText()
    }

    @discardableResult
    func expandDueDateFormulas(referenceDate: Date = Date(), calendar: Calendar = .current) -> Bool {
        let replacements = TaskMetadata.dueFormulaReplacements(in: string, referenceDate: referenceDate, calendar: calendar)
        guard !replacements.isEmpty else { return false }
        let editable = isEditable
        isEditable = true
        defer { isEditable = editable }
        let originalSelection = selectedRange()
        var cursor = originalSelection.location
        let ownGroup = undoManager?.groupingLevel == 0
        if ownGroup { undoManager?.beginUndoGrouping() }
        defer { if ownGroup { undoManager?.endUndoGrouping() } }
        var changed = false
        for item in replacements.reversed() {
            guard shouldChangeText(in: item.range, replacementString: item.replacement) else { continue }
            textStorage?.replaceCharacters(in: item.range, with: item.replacement)
            changed = true
            let delta = (item.replacement as NSString).length - item.range.length
            if cursor >= NSMaxRange(item.range) {
                cursor += delta
            } else if cursor > item.range.location {
                cursor = item.range.location + (item.replacement as NSString).length
            }
        }
        guard changed else { return false }
        let clamped = min(max(0, cursor), (string as NSString).length)
        setSelectedRange(NSRange(location: clamped, length: 0))
        didChangeText()
        return true
    }

    func leaveInsertMode(notify: Bool = true) {
        if mode == .insert { expandDueDateFormulas() }
        let source = string as NSString
        let point = selectedRange().location
        if mode == .insert, point > TaskEditorText.line(source, at: point).range.location {
            setSelectedRange(NSRange(location: source.rangeOfComposedCharacterSequence(at: point - 1).location, length: 0))
        }
        setMode(.normal, notify: notify)
    }

    private func moveNormalHorizontally(forward: Bool) {
        let point = TaskEditorText.horizontal(string as NSString, at: selectedRange().location, forward: forward)
        setSelectedRange(NSRange(location: point, length: 0))
    }

    private func clampNormalCursor() {
        let source = string as NSString
        let point = min(selectedRange().location, source.length)
        setSelectedRange(NSRange(location: min(point, TaskEditorText.lastCharacter(source, at: point)), length: 0))
    }

    private func pasteModal(after: Bool, count: Int) {
        let content = NSPasteboard.general.string(forType: .string) ?? yank
        guard !content.isEmpty else { return }
        let source = string as NSString
        let point = selectedRange().location
        if selectedRange().length > 0 {
            replace(selectedRange(), with: String(repeating: content, count: count))
            let end = selectedRange().location
            setSelectedRange(NSRange(location: (string as NSString).rangeOfComposedCharacterSequence(at: end - 1).location, length: 0))
            return
        }
        let row = TaskEditorText.line(source, at: point)
        let linewise = content.last?.isNewline == true
        var text = String(repeating: content, count: count)
        var position = point
        if linewise {
            position = after ? NSMaxRange(row.range) : row.range.location
            if after, row.contentEnd == NSMaxRange(row.range), position > 0 { text = "\n" + text }
        } else if after, point < row.contentEnd {
            position = NSMaxRange(source.rangeOfComposedCharacterSequence(at: point))
        }
        replace(NSRange(location: position, length: 0), with: text)
        if linewise {
            // Match Veda's linewise cursor rule: retain the original line for
            // an interior paste; appending at EOF ends on its final empty line.
            let original = after && row.contentEnd == NSMaxRange(row.range)
                ? position + (text as NSString).length
                : row.range.location + (after ? 0 : (text as NSString).length)
            let updated = string as NSString
            let target = TaskEditorText.line(updated, at: original)
            var cursor = target.range.location
            while cursor < target.contentEnd, [9, 32].contains(updated.character(at: cursor)) { cursor += 1 }
            setSelectedRange(NSRange(location: cursor, length: 0))
        } else {
            let end = position + (text as NSString).length
            let cursor = (string as NSString).rangeOfComposedCharacterSequence(at: end - 1).location
            setSelectedRange(NSRange(location: cursor, length: 0))
        }
    }

    private func joinLines(count: Int) {
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }
        for _ in 0..<count {
            let source = string as NSString
            let row = TaskEditorText.line(source, at: selectedRange().location)
            let next = NSMaxRange(row.range)
            guard row.contentEnd < next else { break }
            let following = TaskEditorText.line(source, at: next)
            var content = next
            while content < following.contentEnd, [9, 32].contains(source.character(at: content)) { content += 1 }
            let needsSpace = row.contentEnd > row.range.location && source.character(at: row.contentEnd - 1) != 32
                && content < following.contentEnd
            replace(NSRange(location: row.contentEnd, length: content - row.contentEnd), with: needsSpace ? " " : "")
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isEditable else { return }
        if handleNavigation(event) { return }
        if event.modifierFlags.contains(.command) {
            if handleCommand(event) { return }
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53, !hasMarkedText() { leaveInsertMode(); return }
        if event.modifierFlags.contains(.control), event.keyCode == 49 {
            onDictation?(); return
        }
        if mode == .insert || hasMarkedText() {
            if mode == .insert, !hasMarkedText(), [36, 76].contains(event.keyCode) {
                let indent = TaskEditorText.indentation(string as NSString, at: selectedRange().location)
                replace(selectedRange(), with: "\n" + indent)
            } else { super.keyDown(with: event) }
            return
        }
        let key = event.charactersIgnoringModifiers ?? ""
        if event.modifierFlags.contains(.control) {
            if key == "r" {
                for _ in 0..<max(1, Int(countText) ?? 1) { undoManager?.redo() }
                pending = ""; pendingCount = 1; countText = ""
                scrollRangeToVisible(selectedRange())
            }
            return
        }
        // Unbound Option chords must not accidentally execute a plain Vim
        // command, such as treating Veda's Alt-U case conversion as undo.
        if event.modifierFlags.contains(.option) {
            pending = ""; pendingCount = 1; countText = ""
            return
        }
        if key.count == 1, key.first?.isASCII == true, key.first?.isNumber == true,
           key != "0" || !countText.isEmpty {
            countText = String((countText + key).prefix(3))
            return
        }
        let count = max(1, Int(countText) ?? 1) * (pending.isEmpty ? 1 : pendingCount)
        let source = string as NSString
        let point = min(selectedRange().location, source.length)
        if !pending.isEmpty {
            let operation = pending
            pending = ""; pendingCount = 1; countText = ""
            if operation == "g" { if key == "g" { moveToBeginningOfDocument(nil) }; return }
            var range: NSRange?
            var lineSelection: (range: NSRange, contentEnd: Int)?
            if key == operation {
                let lines = TaskEditorText.lines(source, at: point, count: count)
                lineSelection = lines
                if operation == "d" { range = TaskEditorText.deletionRange(source, lines: lines) }
                else if operation == "c" { range = NSRange(location: lines.range.location, length: lines.contentEnd - lines.range.location) }
                else { range = lines.range }
            } else if key == "w" || key == "W" {
                range = TaskEditorText.words(source, at: point, count: count, whole: key == "w",
                                             trailingSpace: key == "w" && operation != "c")
            } else if key == "$" { range = NSRange(location: point, length: lineEnd(point) - point) }
            if let range {
                yank = source.substring(with: lineSelection?.range ?? range)
                if operation == "y", let lines = lineSelection, lines.contentEnd == NSMaxRange(lines.range) {
                    yank += "\n" // yy remains linewise even on the last line.
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(yank, forType: .string)
                if operation != "y" {
                    let logicalStart = lineSelection?.range.location ?? range.location
                    let previousLine = logicalStart > 0
                        ? TaskEditorText.line(source, at: logicalStart - 1).range.location : 0
                    if operation == "c" { setMode(.insert) }
                    replace(range, with: "")
                    if operation == "d", key == "d" {
                        setSelectedRange(NSRange(location: min(previousLine, (string as NSString).length), length: 0))
                        scrollRangeToVisible(selectedRange())
                    }
                }
            }
            return
        }
        switch key {
        case " ": onDictation?()
        case "i": setMode(.insert)
        case "a":
            if point < lineEnd(point) { setSelectedRange(NSRange(location: NSMaxRange(source.rangeOfComposedCharacterSequence(at: point)), length: 0)) }
            setMode(.insert)
        case "I": setSelectedRange(NSRange(location: TaskEditorText.line(source, at: point).range.location, length: 0)); setMode(.insert)
        case "A": setSelectedRange(NSRange(location: lineEnd(point), length: 0)); setMode(.insert)
        case "o", "O":
            let start = source.lineRange(for: NSRange(location: point, length: 0)).location
            let position = key == "o" ? lineEnd(point) : start
            let indent = key == "o" ? TaskEditorText.indentation(source, at: point)
                : (start > 0 ? TaskEditorText.indentation(source, at: start - 1) : "")
            setMode(.insert)
            replace(NSRange(location: position, length: 0), with: key == "o" ? "\n" + indent : indent + "\n")
            if key == "O" { setSelectedRange(NSRange(location: start + (indent as NSString).length, length: 0)) }
        case "h", "\u{f702}": for _ in 0..<count { moveNormalHorizontally(forward: false) }
        case "l", "\u{f703}": for _ in 0..<count { moveNormalHorizontally(forward: true) }
        case "j", "\u{f701}": for _ in 0..<count { moveDown(nil) }
        case "k", "\u{f700}": for _ in 0..<count { moveUp(nil) }
        case "w", "W", "b", "B":
            var destination = point
            for _ in 0..<count {
                destination = key.lowercased() == "w"
                    ? TaskEditorText.nextWord(source, at: destination, underscore: key == "w")
                    : TaskEditorText.previousWord(source, at: destination, underscore: key == "b")
            }
            setSelectedRange(NSRange(location: destination, length: 0))
        case "0": setSelectedRange(NSRange(location: TaskEditorText.line(source, at: point).range.location, length: 0))
        case "$": setSelectedRange(NSRange(location: TaskEditorText.lastCharacter(source, at: point), length: 0))
        case "g": pending = "g"
        case "G":
            var last = TaskEditorText.line(source, at: source.length)
            if last.range.length == 0, last.range.location > 0 { last = TaskEditorText.line(source, at: last.range.location - 1) }
            setSelectedRange(NSRange(location: TaskEditorText.lastCharacter(source, at: last.range.location), length: 0))
        case "d", "c", "y": pending = key; pendingCount = count; countText = ""
        case "D", "C":
            if key == "C" { setMode(.insert) }
            replace(NSRange(location: point, length: lineEnd(point) - point), with: "")
            if key == "D" { clampNormalCursor() }
        case "x":
            if selectedRange().length > 0 { replace(selectedRange(), with: "") }
            else if point < source.length {
                var range = source.rangeOfComposedCharacterSequence(at: point)
                for _ in 1..<count where NSMaxRange(range) < source.length {
                    range = NSUnionRange(range, source.rangeOfComposedCharacterSequence(at: NSMaxRange(range)))
                }
                replace(range, with: "")
            }
        case "p", "P": pasteModal(after: key == "p", count: count)
        case "u": for _ in 0..<count { undoManager?.undo() }
        case "U": for _ in 0..<count { undoManager?.redo() }
        case "J": joinLines(count: count)
        case "/":
            let sender = NSMenuItem()
            sender.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
            performFindPanelAction(sender)
        default: break
        }
        if pending.isEmpty { countText = "" }
        scrollRangeToVisible(selectedRange())
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, handleNavigation(event) || handleCommand(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    private enum CursorMotion {
        case left, right, up, down, wordLeft, wordRight, lineStart, lineEnd
        case documentStart, documentEnd, paragraphStart, paragraphEnd, pageUp, pageDown

        var commands: (move: Selector, select: Selector) {
            switch self {
            case .left: (#selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveLeftAndModifySelection(_:)))
            case .right: (#selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveRightAndModifySelection(_:)))
            case .up: (#selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveUpAndModifySelection(_:)))
            case .down: (#selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveDownAndModifySelection(_:)))
            case .wordLeft: (#selector(NSResponder.moveWordLeft(_:)), #selector(NSResponder.moveWordLeftAndModifySelection(_:)))
            case .wordRight: (#selector(NSResponder.moveWordRight(_:)), #selector(NSResponder.moveWordRightAndModifySelection(_:)))
            case .lineStart: (#selector(NSResponder.moveToBeginningOfLine(_:)), #selector(NSResponder.moveToBeginningOfLineAndModifySelection(_:)))
            case .lineEnd: (#selector(NSResponder.moveToEndOfLine(_:)), #selector(NSResponder.moveToEndOfLineAndModifySelection(_:)))
            case .documentStart: (#selector(NSResponder.moveToBeginningOfDocument(_:)), #selector(NSResponder.moveToBeginningOfDocumentAndModifySelection(_:)))
            case .documentEnd: (#selector(NSResponder.moveToEndOfDocument(_:)), #selector(NSResponder.moveToEndOfDocumentAndModifySelection(_:)))
            case .paragraphStart: (#selector(NSResponder.moveToBeginningOfParagraph(_:)), #selector(NSResponder.moveToBeginningOfParagraphAndModifySelection(_:)))
            case .paragraphEnd: (#selector(NSResponder.moveToEndOfParagraph(_:)), #selector(NSResponder.moveToEndOfParagraphAndModifySelection(_:)))
            case .pageUp: (#selector(NSResponder.pageUp(_:)), #selector(NSResponder.pageUpAndModifySelection(_:)))
            case .pageDown: (#selector(NSResponder.pageDown(_:)), #selector(NSResponder.pageDownAndModifySelection(_:)))
            }
        }
    }

    /// Conventional navigation is shared by Normal and Insert. Use AppKit's
    /// movements to preserve native word boundaries, selection anchors and bidi.
    private func handleNavigation(_ event: NSEvent) -> Bool {
        guard isEditable, mode != .dictation, !hasMarkedText() else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let primary = flags.subtracting(.shift)
        var code = event.keyCode
        switch event.charactersIgnoringModifiers {
        case "\u{f729}": code = 115 // Home, including keyboards translating Fn+arrows.
        case "\u{f72b}": code = 119
        case "\u{f72c}": code = 116
        case "\u{f72d}": code = 121
        default: break
        }
        let word = primary == .control || primary == .option
        let motion: CursorMotion
        switch code {
        case 123 where primary.isEmpty: motion = .left
        case 124 where primary.isEmpty: motion = .right
        case 125 where primary.isEmpty: motion = .down
        case 126 where primary.isEmpty: motion = .up
        case 123 where word: motion = .wordLeft
        case 124 where word: motion = .wordRight
        case 123 where primary == .command: motion = .lineStart
        case 124 where primary == .command: motion = .lineEnd
        case 126 where primary == .command: motion = .documentStart
        case 125 where primary == .command: motion = .documentEnd
        case 126 where word: motion = .paragraphStart
        case 125 where word: motion = .paragraphEnd
        case 115 where primary.isEmpty: motion = .lineStart
        case 119 where primary.isEmpty: motion = .lineEnd
        case 115 where primary == .control || primary == .command: motion = .documentStart
        case 119 where primary == .control || primary == .command: motion = .documentEnd
        case 116 where primary.isEmpty: motion = .pageUp
        case 121 where primary.isEmpty: motion = .pageDown
        default:
            guard primary == .control else { return false }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": motion = .lineStart
            case "e": motion = .lineEnd
            case "b": motion = .left
            case "f": motion = .right
            case "p": motion = .up
            case "n": motion = .down
            case "v": motion = .pageDown
            default: return false
            }
        }
        let count = mode == .normal && primary.isEmpty ? max(1, Int(countText) ?? 1) : 1
        pending = ""; countText = ""
        let commands = motion.commands
        for _ in 0..<count {
            if mode == .normal, primary.isEmpty, !flags.contains(.shift), selectedRange().length == 0,
               motion == .left || motion == .right {
                moveNormalHorizontally(forward: motion == .right)
            } else { doCommand(by: flags.contains(.shift) ? commands.select : commands.move) }
        }
        scrollRangeToVisible(selectedRange())
        return true
    }

    private func handleCommand(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "s": onSave?()
        case "a": selectAll(nil)
        case "c": copy(nil)
        case "z":
            setMode(.normal)
            if event.modifierFlags.contains(.shift) { undoManager?.redo() } else { undoManager?.undo() }
        case "v", "x":
            guard isEditable else { return true }
            let ownGroup = undoManager?.groupingLevel == 0
            if ownGroup { undoManager?.beginUndoGrouping() }
            if event.charactersIgnoringModifiers?.lowercased() == "v" { paste(nil) } else { cut(nil) }
            if ownGroup { undoManager?.endUndoGrouping() }
        case "f":
            let sender = NSMenuItem()
            sender.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
            performFindPanelAction(sender)
        default: return false
        }
        return true
    }

    private func lineEnd(_ point: Int) -> Int {
        TaskEditorText.line(string as NSString, at: point).contentEnd
    }
}
