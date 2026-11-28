import AppKit
import SwiftUI

private struct ProjectBranch: Identifiable {
    var id: String { project.id }
    let project: TaskProject
    var children: [ProjectBranch]?
}

private struct ProjectTreeRow: View {
    let branch: ProjectBranch
    @Binding var expanded: Set<String>
    let menu: (TaskProject) -> AnyView

    var body: some View {
        Group {
            if let children = branch.children {
                DisclosureGroup(isExpanded: Binding(
                    get: { expanded.contains(branch.id) },
                    set: { if $0 { expanded.insert(branch.id) } else { expanded.remove(branch.id) } }
                )) {
                    ForEach(children) { child in ProjectTreeRow(branch: child, expanded: $expanded, menu: menu) }
                } label: { label }
            } else { label }
        }.tag(branch.id)
    }

    private var label: some View {
        Label(branch.project.name, systemImage: "folder").id(branch.id).contextMenu { menu(branch.project) }
    }
}

private enum TaskNameAction {
    case project(categoryID: String, parentID: String?)
    case renameProject(String)
    case category
    case renameCategory(String)
}

struct TaskManagerView: View {
    @ObservedObject var model: TaskManagerModel
    @State private var nameAction: TaskNameAction = .category
    @State private var name = ""
    @State private var promptTitle = ""
    @State private var showingNamePrompt = false
    @State private var newProjectName = ""
    @State private var showingDelete = false
    @State private var showingDiscard = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.loaded {
                TaskPanes(projects: AnyView(projectsPane), tasks: AnyView(tasksPane), editor: AnyView(editorPane))
            } else {
                ContentUnavailableView {
                    Label(model.kind == .tasks ? "Task database" : "Notes folder", systemImage: "icloud")
                } description: {
                    let defaultMessage = model.kind == .tasks ? "Opening iCloud Drive/PA3/pa3.sqlite…" : "Opening iCloud Drive/PA3…"
                    Text(model.errorMessage.isEmpty ? defaultMessage : model.errorMessage)
                } actions: {
                    Button("Retry") { Task { await model.open() } }.disabled(model.busy)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.loaded, !model.errorMessage.isEmpty { errorBanner }
            Divider()
            HStack {
                Image(systemName: "icloud")
                Text(model.storageStatus).lineLimit(1).help(model.storageStatus)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button(model.kind.showStorageButtonTitle) {
                    model.revealStorageInFinder()
                }.buttonStyle(.plain).disabled(model.databaseURL == nil)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 8)
        }
        .background(Color(nsColor: PaperTheme.canvas))
        .foregroundStyle(Color(nsColor: PaperTheme.ink))
        .tint(Color(nsColor: PaperTheme.ink))
        .alert(promptTitle, isPresented: $showingNamePrompt) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") { saveName() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Delete this \(model.kind.itemSingular)?", isPresented: $showingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { model.deleteTask() }
        } message: {
            Text(model.selectedTask.map { $0.isUntitled ? model.kind.untitledTitle : $0.subject } ?? "")
        }
        .alert("New project in \(model.newProjectCategory?.name ?? model.kind.sectionSingular)", isPresented: $model.showingNewProjectPrompt) {
            TextField("Name", text: $newProjectName)
            Button("Cancel", role: .cancel) { model.onFocusRequested?() }
            Button("Save") {
                if let category = model.newProjectCategory {
                    model.addProject(name: newProjectName, categoryID: category.id, parentID: nil)
                }
            }.disabled(newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onChange(of: model.showingNewProjectPrompt) { _, showing in
            if showing { newProjectName = "" }
        }
        .alert("Discard this window's draft and reload?", isPresented: $showingDiscard) {
            Button("Cancel", role: .cancel) {}
            Button("Discard draft", role: .destructive) { model.discardDraftAndReload() }
        }
        .sheet(isPresented: $model.showingShortcutHelp, onDismiss: { model.onFocusRequested?() }) {
            TaskShortcutHelpView(model: model)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label(model.kind.headerTitle, systemImage: model.kind.headerIcon).font(.system(size: 19, weight: .semibold))
            Spacer()
            Button { model.addTask() } label: { Label(model.kind.newItemButtonTitle, systemImage: "plus") }
                .disabled(model.selectedProjectID == nil || model.busy || model.conflict)
            Menu {
                Button("\(model.kind.newSectionTitle)…") { prompt(model.kind.newSectionTitle, action: .category) }
                Menu(model.kind.renameSectionTitle) {
                    ForEach(model.categories) { category in
                        Button(category.name) { prompt(model.kind.renameSectionTitle, action: .renameCategory(category.id), current: category.name) }
                    }
                }
                Divider()
                Button("Refresh from disk") { Task { await model.refresh() } }
            } label: { Image(systemName: "gearshape") }.menuStyle(.borderlessButton).fixedSize()
                .disabled(!model.loaded || model.busy)
            Button {
                if model.editorMode == .dictation { model.dictation.toggleShortcuts() }
                else { model.showingShortcutHelp = true }
            } label: { Image(systemName: "questionmark.circle") }.help("Keyboard shortcuts (?)")
        }.padding(.horizontal, 16).padding(.vertical, 12).background(Color(nsColor: PaperTheme.paper))
    }

    private var projectsPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Projects").font(.headline)
                Spacer()
                Menu {
                    ForEach(model.categories) { category in
                        Button("New project in \(category.name)…") { prompt("New project", action: .project(categoryID: category.id, parentID: nil)) }
                    }
                } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).fixedSize().help("New project")
            }.padding(12).background(paneHighlight(.projects))
            ScrollViewReader { proxy in
                List(selection: Binding(get: { model.selectedProjectID }, set: { model.selectProject($0) })) {
                    ForEach(model.categories) { category in
                        Section {
                            if !model.collapsedCategories.contains(category.id) {
                                ForEach(branches(categoryID: category.id, parentID: nil)) { branch in
                                    ProjectTreeRow(branch: branch, expanded: $model.expandedProjects, menu: { AnyView(projectMenu($0)) })
                                }
                                if !model.projects.contains(where: { $0.categoryID == category.id }) {
                                    Button("Add project…") { prompt("New project", action: .project(categoryID: category.id, parentID: nil)) }
                                        .foregroundStyle(.secondary).buttonStyle(.borderless)
                                }
                            }
                        } header: {
                            Button {
                                if model.collapsedCategories.contains(category.id) { model.collapsedCategories.remove(category.id) }
                                else { model.collapsedCategories.insert(category.id) }
                            } label: {
                                HStack {
                                    Image(systemName: model.collapsedCategories.contains(category.id) ? "chevron.right" : "chevron.down")
                                    Text(category.name)
                                    Spacer()
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityLabel(category.name)
                                .accessibilityValue(model.collapsedCategories.contains(category.id) ? "Collapsed" : "Expanded")
                        }
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
                .onChange(of: model.selectedProjectID) { _, id in
                    if let id {
                        proxy.scrollTo(id)
                        model.onScrollSelectionRequested?(.projects)
                    }
                }
                .onAppear {
                    if let id = model.selectedProjectID {
                        proxy.scrollTo(id)
                        model.onScrollSelectionRequested?(.projects)
                    }
                }
            }
            HStack {
                Button("\(model.kind.newSectionTitle)…") { prompt(model.kind.newSectionTitle, action: .category) }
                Spacer()
                Button("Subproject…") {
                    if let project = model.selectedProject {
                        prompt("New subproject", action: .project(categoryID: project.categoryID, parentID: project.id))
                    }
                }.disabled(model.selectedProject == nil)
            }.font(.system(size: 11)).padding(10)
        }.disabled(model.busy || model.conflict)
    }

    private func branches(categoryID: String, parentID: String?, ancestors: Set<String> = []) -> [ProjectBranch] {
        model.projects.filter { $0.categoryID == categoryID && $0.parentID == parentID && !ancestors.contains($0.id) }.map { project in
            let children = branches(categoryID: categoryID, parentID: project.id, ancestors: ancestors.union([project.id]))
            return ProjectBranch(project: project, children: children.isEmpty ? nil : children)
        }
    }

    @ViewBuilder private func projectMenu(_ project: TaskProject) -> some View {
        Button("New subproject…") { prompt("New subproject", action: .project(categoryID: project.categoryID, parentID: project.id)) }
        Button("Rename…") { prompt("Rename project", action: .renameProject(project.id), current: project.name) }
        Menu("Move to \(model.kind.sectionSingular)") {
            ForEach(model.categories) { category in
                Button(category.name) { model.moveProject(project.id, parentID: nil, categoryID: category.id) }
            }
        }
        Menu("Move under project") {
            ForEach(model.projects.filter { $0.id != project.id }) { parent in
                Button(model.projectPath(parent)) { model.moveProject(project.id, parentID: parent.id, categoryID: parent.categoryID) }
            }
        }
        Divider()
        Button("Delete empty project", role: .destructive) { model.deleteProject(project.id) }
    }

    private var tasksPane: some View {
        let filtered = model.visibleTasks
        let total = model.projectTasks.count
        let hasQuery = !model.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(model.selectedProject?.name ?? model.kind.headerTitle).font(.headline).lineLimit(1)
                Spacer()
                Button {
                    model.activatePane(.tasks, requestFocus: false)
                    model.beginTaskSearch()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.isSearchingTasks ? Color.accentColor : .secondary)
                .help("Search this project (/)")
                .disabled(model.selectedProjectID == nil)
                Text(hasQuery ? "\(filtered.count)/\(total)" : "\(filtered.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }.padding(12).background(paneHighlight(.tasks))
            if model.isSearchingTasks {
                taskSearchDialog(matchCount: filtered.count, totalCount: total)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
            ScrollViewReader { proxy in
                List(selection: Binding(get: { model.selectedTaskID }, set: { model.selectTask($0) })) {
                    ForEach(filtered) { task in
                        let title = task.isUntitled ? model.kind.untitledTitle : task.subject
                        HStack(alignment: .top, spacing: 8) {
                            if model.kind.supportsTaskMetadata {
                                Button { model.toggleCompletion(task) } label: { Image(systemName: task.metadata.done ? "checkmark.circle.fill" : "circle") }
                                    .buttonStyle(.plain).help(task.metadata.done ? "Reopen task" : "Complete task with #done")
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(title).fontWeight(.bold).lineLimit(2)
                                    .strikethrough(model.kind.supportsTaskMetadata && task.metadata.done)
                                if model.kind.supportsTaskMetadata, (task.metadata.priority != nil || task.metadata.due != nil) {
                                    HStack(spacing: 6) {
                                        if let priority = task.metadata.priority { priorityBadge(priority) }
                                        if let due = task.metadata.due { Text(due) }
                                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                        }.padding(.vertical, 4).tag(task.id).id(task.id)
                            .contextMenu {
                                Menu("Move to project") {
                                    ForEach(model.projects) { project in
                                        Button(model.projectPath(project)) { model.moveTask(task.id, projectID: project.id) }
                                    }
                                }
                            }
                    }
                }.listStyle(.inset).scrollContentBackground(.hidden)
                    .overlay {
                        if filtered.isEmpty {
                            let message = model.selectedProjectID == nil
                                ? "Create or select a project."
                                : (hasQuery ? "No matching \(model.kind.itemPlural)." : "No \(model.kind.itemPlural) yet. Use \(model.kind.newItemButtonTitle).")
                            Text(message)
                                .font(.callout).foregroundStyle(.secondary).padding()
                        }
                    }
                    .onChange(of: model.selectedTaskID) { _, id in
                        if let id {
                            proxy.scrollTo(id)
                            model.onScrollSelectionRequested?(.tasks)
                        }
                    }
                    .onAppear {
                        if let id = model.selectedTaskID {
                            proxy.scrollTo(id)
                            model.onScrollSelectionRequested?(.tasks)
                        }
                    }
            }
            if model.kind.supportsTaskMetadata {
                Toggle("Show completed", isOn: $model.showCompleted).font(.system(size: 12)).padding(12)
            }
        }.disabled(model.busy || model.conflict)
    }

    private func taskSearchDialog(matchCount: Int, totalCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("/")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                TaskSearchField(
                    text: Binding(get: { model.search }, set: { model.updateSearch($0) }),
                    placeholder: "Filter \(model.kind.itemPlural)…",
                    onMove: { model.moveSelection($0) },
                    onCommit: { model.commitTaskSearch() },
                    onCancel: { model.cancelTaskSearch() }
                )
                .frame(height: 18)
                Button { model.cancelTaskSearch() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search (Esc)")
            }
            HStack {
                Text("↑↓ select · ⏎ open · esc clear")
                Spacer()
                Text("\(matchCount) of \(totalCount)")
                    .monospacedDigit()
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: PaperTheme.paper))
                .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: PaperTheme.ink).opacity(0.18), lineWidth: 1)
        )
    }

    private var editorPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(model.kind.editorHeading).font(.headline)
                Spacer()
                Text(model.editorMode.rawValue).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                Button("Type") { model.editor?.setMode(.insert); model.activatePane(.description) }
                    .disabled(model.selectedTaskID == nil || model.editorMode == .dictation || model.busy)
                Button { model.beginDictation() } label: { Image(systemName: "mic") }.help("Dictate at cursor or replace selected text")
                    .disabled(model.selectedTaskID == nil || model.editorMode == .dictation || model.busy || model.conflict)
                Button { showingDelete = true } label: { Image(systemName: "trash") }.help("Delete \(model.kind.itemSingular)")
                    .disabled(model.selectedTaskID == nil || model.busy || model.conflict)
            }.padding(12).background(paneHighlight(.description))
            Divider()
            ZStack {
                TaskEditorView(model: model).opacity(model.editorMode == .dictation ? 0 : 1)
                    .allowsHitTesting(model.editorMode != .dictation)
                if model.editorMode == .dictation {
                    DictationView(controller: model.dictation, embedded: true)
                } else if model.selectedTaskID == nil {
                    let subtitle = model.kind == .tasks
                        ? "The first line of its description becomes the subject."
                        : "The first line of a note becomes its title."
                    ContentUnavailableView("Select a \(model.kind.itemSingular)", systemImage: "text.alignleft", description: Text(subtitle))
                }
            }
        }
    }

    private var errorBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
            Text(model.errorMessage).font(.callout).textSelection(.enabled)
            Spacer()
            if model.conflict { Button("Save draft as new \(model.kind.itemSingular)") { model.saveConflictCopy() } }
            else { Button("Retry save") { Task { await model.flush() } } }
            Button("Reload…") { showingDiscard = true }
        }.padding(12).background(Color.orange.opacity(0.13)).disabled(model.busy)
    }

    private func prompt(_ title: String, action: TaskNameAction, current: String = "") {
        promptTitle = title; nameAction = action; name = current; showingNamePrompt = true
    }
    private func saveName() {
        switch nameAction {
        case .project(let category, let parent): model.addProject(name: name, categoryID: category, parentID: parent)
        case .renameProject(let id): model.renameProject(id, name: name)
        case .category: model.addCategory(name: name)
        case .renameCategory(let id): model.renameCategory(id, name: name)
        }
    }

    private func paneHighlight(_ pane: TaskPane) -> Color {
        model.activePane == pane ? Color.accentColor.opacity(0.12) : .clear
    }

    private func priorityBadge(_ priority: Int) -> some View {
        let tint: Color = switch priority {
        case 0: .red
        case 1: .orange
        case 2: .blue
        default: .secondary
        }
        return Text("P\(priority)")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// Native split views preserve the initial 25/25/50 proportions and let the
/// user resize each pane. HSplitView otherwise distributes flexible panes equally.
private struct TaskPanes: NSViewRepresentable {
    let projects: AnyView
    let tasks: AnyView
    let editor: AnyView

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSplitView {
        let split = TaskPaneSplitView(frame: NSRect(x: 0, y: 0, width: 1240, height: 600))
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = context.coordinator
        let widths: [CGFloat] = [309.5, 309.5, 619]
        var x: CGFloat = 0
        for (index, root) in [projects, tasks, editor].enumerated() {
            let host = TaskPaneHostingView(rootView: themed(root))
            host.identifier = NSUserInterfaceItemIdentifier("tasks.pane.\(TaskPane.allCases[index].rawValue)")
            host.sizingOptions = []
            host.frame = NSRect(x: x, y: 0, width: widths[index], height: 600)
            host.autoresizingMask = [.width, .height]
            split.addArrangedSubview(host)
            context.coordinator.hosts.append(host)
            x += widths[index] + 1
        }
        return split
    }

    func updateNSView(_ split: NSSplitView, context: Context) {
        for (host, root) in zip(context.coordinator.hosts, [projects, tasks, editor]) { host.rootView = themed(root) }
    }

    private func themed(_ view: AnyView) -> AnyView {
        AnyView(view.background(Color(nsColor: PaperTheme.canvas))
            .foregroundStyle(Color(nsColor: PaperTheme.ink)).tint(Color(nsColor: PaperTheme.ink)))
    }

    final class Coordinator: NSObject, NSSplitViewDelegate {
        var hosts: [NSHostingView<AnyView>] = []
        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            dividerIndex == 0 ? 180 : splitView.subviews[1].frame.minX + 200
        }
        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            dividerIndex == 0 ? splitView.subviews[1].frame.maxX - 200 : splitView.bounds.width - 400
        }
    }
}

private final class TaskPaneHostingView: NSHostingView<AnyView> {
    override var acceptsFirstResponder: Bool { true }
}

private struct TaskSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = "Filter tasks…"
    var onMove: (Int) -> Void
    var onCommit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.identifier = NSUserInterfaceItemIdentifier("tasks.search.field")
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = PaperTheme.ink
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TaskSearchField
        init(_ parent: TaskSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel(); return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onCommit(); return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1); return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1); return true
            default:
                return false
            }
        }
    }
}

private final class TaskPaneSplitView: NSSplitView {
    private var positioned = false

    override func layout() {
        super.layout()
        guard !positioned, bounds.width >= 780, subviews.count == 3 else { return }
        positioned = true
        let previousDelegate = delegate
        delegate = nil
        // Open the right divider first, since AppKit can initially collapse the
        // two leading hosting views while adding arranged subviews.
        setPosition(bounds.width * 0.5, ofDividerAt: 1)
        setPosition(bounds.width * 0.25, ofDividerAt: 0)
        delegate = previousDelegate
    }
}

@MainActor
final class TaskManagerWindow: NSWindowController, NSWindowDelegate {
    let model: TaskManagerModel
    private var keyMonitor: Any?
    private var closing = false

    init(model: TaskManagerModel) {
        self.model = model
        let window = TaskNavigationWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 720),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = model.kind.windowTitle
        window.minSize = NSSize(width: 900, height: 480)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName(model.kind.frameAutosaveName)
        window.contentView = NSHostingView(rootView: TaskManagerView(model: model))
        super.init(window: window)
        window.model = model
        model.onFocusRequested = { [weak window] in
            Task { @MainActor in
                await Task.yield()
                window?.focusActivePane()
            }
        }
        model.onScrollSelectionRequested = { [weak window] pane in
            Task { @MainActor in
                await Task.yield()
                window?.scrollSelectedRowToVisible(in: pane)
            }
        }
        model.onSearchFocusRequested = { [weak window] in
            Task { @MainActor in
                await Task.yield()
                window?.focusSearchField()
            }
        }
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        model.start()
        if keyMonitor == nil, let window = window as? TaskNavigationWindow {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
                guard let window, event.window === window || event.window?.sheetParent === window,
                      window.isKeyWindow || window.attachedSheet?.isKeyWindow == true else { return event }
                return window.handleTaskKey(event) ? nil : event
            }
        }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let window = window as? TaskNavigationWindow {
            window.focusActivePane()
            Task { @MainActor in
                await Task.yield()
                window.scrollSelectedRowToVisible(in: .projects)
                window.scrollSelectedRowToVisible(in: .tasks)
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !closing else { return false }
        closing = true
        Task {
            defer { closing = false }
            if await model.prepareToClose() {
                sender.orderOut(nil)
                if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
            }
        }
        return false
    }
}
