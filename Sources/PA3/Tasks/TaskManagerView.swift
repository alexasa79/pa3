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
        Label(branch.project.name, systemImage: "folder").contextMenu { menu(branch.project) }
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
                    Label("Task database", systemImage: "icloud")
                } description: {
                    Text(model.errorMessage.isEmpty ? "Opening iCloud Drive/PA3/pa3.sqlite…" : model.errorMessage)
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
                Button("Show database") {
                    if let url = model.databaseURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
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
        .alert("Delete this task?", isPresented: $showingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { model.deleteTask() }
        } message: { Text(model.selectedTask?.subject ?? "") }
        .alert("New project in \(model.newProjectCategory?.name ?? "category")", isPresented: $model.showingNewProjectPrompt) {
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
            Label("Tasks", systemImage: "checklist").font(.system(size: 19, weight: .semibold))
            Spacer()
            Button { model.addTask() } label: { Label("New task", systemImage: "plus") }
                .disabled(model.selectedProjectID == nil || model.busy || model.conflict)
            Menu {
                Button("New category…") { prompt("New category", action: .category) }
                Menu("Rename category") {
                    ForEach(model.categories) { category in
                        Button(category.name) { prompt("Rename category", action: .renameCategory(category.id), current: category.name) }
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
            HStack {
                Button("New category…") { prompt("New category", action: .category) }
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
        Menu("Move to category") {
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
        VStack(spacing: 0) {
            HStack { Text(model.selectedProject?.name ?? "Tasks").font(.headline).lineLimit(1); Spacer(); Text("\(model.visibleTasks.count)").foregroundStyle(.secondary) }.padding(12).background(paneHighlight(.tasks))
            TextField("Search this project", text: $model.search).textFieldStyle(.roundedBorder).padding(.horizontal, 10).padding(.bottom, 8)
            List(selection: Binding(get: { model.selectedTaskID }, set: { model.selectTask($0) })) {
                ForEach(model.visibleTasks) { task in
                    HStack(alignment: .top, spacing: 8) {
                        Button { model.toggleCompletion(task) } label: { Image(systemName: task.metadata.done ? "checkmark.circle.fill" : "circle") }
                            .buttonStyle(.plain).help(task.metadata.done ? "Reopen task" : "Complete task with #done")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(task.subject).fontWeight(.bold).lineLimit(2).strikethrough(task.metadata.done)
                            HStack {
                                if let due = task.metadata.due { Text(due) }
                                if let priority = task.metadata.priority { Text("P\(priority)") }
                            }.font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4).tag(task.id)
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
                    if model.visibleTasks.isEmpty {
                        Text(model.selectedProjectID == nil ? "Create or select a project." : "No tasks yet. Use New task.")
                            .font(.callout).foregroundStyle(.secondary).padding()
                    }
                }
            Toggle("Show completed", isOn: $model.showCompleted).font(.system(size: 12)).padding(12)
        }.disabled(model.busy || model.conflict)
    }

    private var editorPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Description").font(.headline)
                Spacer()
                Text(model.editorMode.rawValue).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                Button("Type") { model.editor?.setMode(.insert); model.activatePane(.description) }
                    .disabled(model.selectedTaskID == nil || model.editorMode == .dictation || model.busy)
                Button { model.beginDictation() } label: { Image(systemName: "mic") }.help("Dictate at cursor or replace selected text")
                    .disabled(model.selectedTaskID == nil || model.editorMode == .dictation || model.busy || model.conflict)
                Button { showingDelete = true } label: { Image(systemName: "trash") }.help("Delete task")
                    .disabled(model.selectedTaskID == nil || model.busy || model.conflict)
            }.padding(12).background(paneHighlight(.description))
            Divider()
            ZStack {
                TaskEditorView(model: model).opacity(model.editorMode == .dictation ? 0 : 1)
                    .allowsHitTesting(model.editorMode != .dictation)
                if model.editorMode == .dictation {
                    DictationView(controller: model.dictation, embedded: true)
                } else if model.selectedTaskID == nil {
                    ContentUnavailableView("Select a task", systemImage: "text.alignleft", description: Text("The first line of its description becomes the subject."))
                }
            }
            if let warning = TaskMetadata(model.draft).warnings.first {
                Text(warning).font(.system(size: 11)).foregroundStyle(.orange).padding(8)
            }
        }
    }

    private var errorBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
            Text(model.errorMessage).font(.callout).textSelection(.enabled)
            Spacer()
            if model.conflict { Button("Save draft as new task") { model.saveConflictCopy() } }
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
        window.title = "PA3 Tasks"
        window.minSize = NSSize(width: 900, height: 480)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("PA3Tasks")
        window.contentView = NSHostingView(rootView: TaskManagerView(model: model))
        super.init(window: window)
        window.model = model
        model.onFocusRequested = { [weak window] in
            Task { @MainActor in
                await Task.yield()
                window?.focusActivePane()
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
        (window as? TaskNavigationWindow)?.focusActivePane()
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
