import AppKit

/// Window-local routing keeps list navigation out of native text fields and
/// intercepts close shortcuts before PA3's application-wide Quit menu item.
@MainActor
final class TaskNavigationWindow: NSWindow {
    weak var model: TaskManagerModel?

    func focusActivePane() {
        guard let model, isVisible, attachedSheet == nil, model.loaded else { return }
        contentView?.layoutSubtreeIfNeeded()
        if model.isSearchingTasks {
            focusSearchField()
            return
        }
        if model.activePane == .description, model.editorMode != .dictation, let editor = model.editor {
            makeFirstResponder(editor)
        } else if model.activePane != .description, let contentView,
                  let host = paneView(model.activePane, in: contentView) {
            makeFirstResponder(host)
        }
    }

    func focusSearchField() {
        guard isVisible, attachedSheet == nil, let contentView else { return }
        contentView.layoutSubtreeIfNeeded()
        if let field = view(identifiedAs: "tasks.search.field", in: contentView) {
            makeFirstResponder(field)
        }
    }

    func scrollSelectedRowToVisible(in pane: TaskPane) {
        guard pane != .description, isVisible, let contentView,
              let host = paneView(pane, in: contentView),
              let table = tableView(in: host) else { return }
        contentView.layoutSubtreeIfNeeded()
        let row = table.selectedRow
        if row >= 0 { table.scrollRowToVisible(row) }
    }

    private func paneView(_ pane: TaskPane, in view: NSView) -> NSView? {
        self.view(identifiedAs: "tasks.pane.\(pane.rawValue)", in: view)
    }

    private func view(identifiedAs identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier { return view }
        for child in view.subviews {
            if let found = self.view(identifiedAs: identifier, in: child) { return found }
        }
        return nil
    }

    private func tableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews {
            if let found = tableView(in: child) { return found }
        }
        return nil
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleTaskKey(event) { return }
        if event.type == .leftMouseDown, let model, let contentView,
           let hit = contentView.hitTest(contentView.convert(event.locationInWindow, from: nil)) {
            var view: NSView? = hit
            while let current = view {
                if let id = current.identifier?.rawValue,
                   let pane = TaskPane.allCases.first(where: { id == "tasks.pane.\($0.rawValue)" }) {
                    model.activatePane(pane, requestFocus: false)
                    break
                }
                view = current.superview
            }
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleTaskKey(event) || super.performKeyEquivalent(with: event)
    }

    @discardableResult
    func handleTaskKey(_ event: NSEvent) -> Bool {
        guard let model else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command, key == "q" || key == "w" {
            performClose(nil)
            return true
        }
        let question = (event.characters == "?" || key == "?") && (flags.isEmpty || flags == .shift)
        if model.showingShortcutHelp {
            if question || (flags.isEmpty && event.keyCode == 53) {
                model.showingShortcutHelp = false
                return true
            }
            return false
        }
        guard attachedSheet == nil else { return false }
        if flags == .command {
            switch key {
            case "n":
                if model.activePane == .tasks { model.addTask() }
                return true
            case "f":
                if model.activePane == .tasks, model.loaded, !model.busy, !model.conflict {
                    model.beginTaskSearch()
                    return true
                }
                return false
            default: return false
            }
        }
        if model.isSearchingTasks {
            if flags.isEmpty {
                switch event.keyCode {
                case 53: model.cancelTaskSearch(); return true
                case 36, 76: model.commitTaskSearch(); return true
                case 125: model.moveSelection(1); return true
                case 126: model.moveSelection(-1); return true
                default: break
                }
            } else if flags == .control {
                if key == "n" || key == "j" { model.moveSelection(1); return true }
                if key == "p" || key == "k" { model.moveSelection(-1); return true }
            }
            return false
        }
        // Search fields, rename prompts, and the editor's Find bar own their
        // typing and arrows. The modal description itself is routed below.
        if let text = firstResponder as? NSTextView, !(text is TaskModalTextView) {
            if text.isFieldEditor || model.editorMode != .dictation { return false }
        }
        if question, model.activePane != .description || model.editorMode == .normal {
            model.showingShortcutHelp = true
            return true
        }
        if key == "q", flags.isEmpty || flags == .shift,
           model.activePane != .description || model.editorMode != .insert {
            performClose(nil)
            return true
        }
        guard flags.isEmpty else { return false }
        if model.activePane == .description {
            if event.keyCode == 53 {
                if model.editor?.hasMarkedText() == true { return false }
                model.escapeDescription()
                return true
            }
            if model.editorMode == .normal {
                if [36, 76].contains(event.keyCode) { return true }
            }
            return false
        }
        switch event.keyCode {
        case 36, 76, 124: model.enterPane(); return true
        case 53, 123: model.leavePane(); return true
        case 125: model.moveSelection(1); return true
        case 126: model.moveSelection(-1); return true
        default:
            if key == "/", model.activePane == .tasks {
                model.beginTaskSearch()
                return true
            }
            if key == "n" {
                guard model.loaded, !model.busy, !model.conflict else { return true }
                if model.activePane == .tasks { model.addTask() }
                else if model.newProjectCategory != nil { model.showingNewProjectPrompt = true }
                return true
            }
            if key == "j" { model.moveSelection(1); return true }
            if key == "k" { model.moveSelection(-1); return true }
            return false
        }
    }
}
