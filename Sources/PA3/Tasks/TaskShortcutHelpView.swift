import SwiftUI

struct TaskShortcutHelpView: View {
    @ObservedObject var model: TaskManagerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.kind == .tasks ? "Task manager shortcuts" : "Note manager shortcuts").font(.title2)
            Text("Space starts dictation from Normal mode. Close this reference with ? or Escape.")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title).font(.headline)
                            ForEach(section.bindings, id: \.self) { binding in
                                let parts = binding.split(separator: ":", maxSplits: 1)
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(String(parts[0]))
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                        .frame(width: 155, alignment: .leading)
                                    Text(parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "")
                                        .font(.system(size: 13)).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.kind.supportsTaskMetadata ? "Saving and text tags" : "Saving and files").font(.headline)
                        Text("Insert and Dictation keep edits in memory. Returning to Normal saves. Switching \(model.kind.itemPlural) or closing the window finishes and saves first. Normal-mode edits save automatically.")
                        if model.kind.supportsTaskMetadata {
                            Text("The first line is the subject. Metadata stays in the text:")
                            Text("#due:2026-11-15   #due:11/15/2026   #due:tomorrow   #due:+2w3d")
                                .font(.system(size: 12, design: .monospaced))
                            Text("#pri:p1   #prio:2   #priority:0   #done")
                                .font(.system(size: 12, design: .monospaced))
                            Text("Relative #due: keywords and formulas (today, tomorrow, today+1w, +2w3d, +1m) expand to YYYY-MM-DD when leaving Insert mode.")
                        } else {
                            Text("The first line is the note title. Each note is stored as a plain markdown file (`YYYY-MM-DDTHH-MM-SS.md`) inside `iCloud Drive/PA3/<Section>/<Project>/`.")
                        }
                        Text("In the projects list, n creates a project in the selected project's \(model.kind.sectionSingular). Subprojects and \(model.kind.sectionPlural) use the mouse controls.")
                    }.font(.system(size: 13)).foregroundStyle(.secondary)
                }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
            }.scrollIndicators(.visible)
            Divider()
            HStack {
                Text("? remains text in Insert mode and text fields.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { model.showingShortcutHelp = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 640, height: 600)
    }

    private var sections: [(title: String, bindings: [String])] {
        let item = model.kind.itemSingular
        let items = model.kind.itemPlural
        let editor = model.kind.editorHeading
        let editorLower = editor.lowercased()
        let windowName = model.kind.headerTitle
        let taskSections: [(title: String, bindings: [String])] = [
            ("Lists and window", [
                "?: show / hide shortcuts", "j/k or Up/Down: select a project or \(item)",
                "/: fuzzy-search \(items) in the current project", "Command-F: also opens \(item) search from the \(item) list",
                "Return or Right: projects → \(items) → \(editorLower)", "Left: \(items) → projects",
                "Escape: close search, or \(editorLower) in Normal → \(items) → projects", "n: new \(item) in \(items), new project in projects",
                "Command-N: also creates a \(item) from the \(item) list",
                "q / Q: save and close \(windowName) from lists or Normal mode", "Command-Q / W: save and close \(windowName), keeping PA3 running"
            ]),
            ("\(editor) · navigation in Normal and Insert", [
                "arrows: move the cursor", "Home / End: beginning / end of line",
                "Ctrl/Option + ←/→: move by words", "⌘← / ⌘→: beginning / end of line",
                "Ctrl-Home/End: beginning / end of \(editorLower)", "⌘↑ / ⌘↓: beginning / end of \(editorLower)",
                "Ctrl/Option + ↑/↓: beginning / end of paragraph", "Page Up / Down: move by a page",
                "Shift + navigation: extend the text selection", "Control-A / E: beginning / end of line",
                "Control-B / F: move left / right", "Control-P / N: move up / down", "Control-V: page down"
            ]),
            ("\(editor) · Normal mode", [
                "Space: start dictation at the cursor or replace selected text", "i / a: type before / after the cursor",
                "I / A: type at the beginning / end of the line", "o / O: insert a line below / above",
                "h/j/k/l or arrows: move the cursor", "w/b: next / previous word; W/B also split at underscores", "0 / $: beginning / last character of logical line",
                "gg / G: beginning / end of \(editorLower)", "number + motion: repeat a movement or edit",
                "x / D / C: delete character / delete to line end / change to line end",
                "dd: delete a line", "cc / yy: change / copy a line",
                "dw / cw: delete / change the whole word under the cursor",
                "dW / cW: delete / change from the cursor to word end",
                "d$ / c$ / y$: delete / change / copy to line end", "p / P: paste after / before; whole-line copies paste as lines",
                "G, A, Control-Space: append dictation at the end",
                "J: join lines", ".: repeat the last change", "u / U / Control-R: undo / redo / redo", "/ or Command-F: find text",
                "Command-S: retry saving in Normal mode"
            ]),
            ("\(editor) · Insert mode", [
                "Escape: save and return to Normal, keeping the \(editorLower) focused",
                "Control-Space: switch to Dictation without saving yet", "arrows: move the text cursor",
                "Command-A/C/X/V: select all / copy / cut / paste", "⌘Z / ⇧⌘Z: undo / redo"
            ])
        ]
        // Reuse PA3's reference so task dictation gains new command descriptions
        // along with the shared dictation implementation.
        return taskSections + model.dictation.shortcutSections().map { section in
            (section.title == "From any app" ? section.title : "Dictation · \(section.title)", section.bindings)
        }
    }
}
