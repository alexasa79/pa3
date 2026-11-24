import AppKit
import Combine
import Foundation

enum TaskPane: String, CaseIterable { case projects, tasks, description }

@MainActor
final class TaskManagerModel: ObservableObject {
    @Published private(set) var categories: [TaskCategory] = []
    @Published private(set) var projects: [TaskProject] = []
    @Published private(set) var tasks: [PersonalTask] = []
    @Published private(set) var selectedProjectID: String?
    @Published private(set) var selectedTaskID: String?
    @Published private(set) var draft = ""
    @Published var editorMode: TaskEditorMode = .normal {
        didSet {
            if editorMode != .normal { saveDebounce?.cancel(); saveDebounce = nil }
        }
    }
    @Published private(set) var busy = false
    @Published private(set) var loaded = false
    @Published private(set) var storageStatus = "Opening task database…"
    @Published private(set) var errorMessage = ""
    @Published private(set) var conflict = false
    @Published var showCompleted = false
    @Published var search = ""
    @Published var isSearchingTasks = false
    @Published var showingShortcutHelp = false
    @Published var showingNewProjectPrompt = false
    @Published private(set) var activePane: TaskPane
    @Published var expandedProjects: Set<String> = []
    @Published var collapsedCategories: Set<String> {
        didSet { preferences.set(Array(collapsedCategories), forKey: "tasks.collapsedCategories") }
    }
    let dictation: DictationController
    weak var editor: TaskModalTextView?
    var onFocusRequested: (() -> Void)?
    var onScrollSelectionRequested: ((TaskPane) -> Void)?
    var onSearchFocusRequested: (() -> Void)?
    var beforeDictation: (() async -> Void)?
    private(set) var databaseURL: URL?
    private var store: TaskStore?
    private var savedBody = ""
    private var displayedTaskID: String?
    private var revealedProjectID: String?
    private var preSearchTaskID: String?
    private var saveDebounce: Task<Void, Never>?
    private var saving: Task<Bool, Never>?
    private var monitor: Task<Void, Never>?
    private var textSubscription: AnyCancellable?
    private var insertion: TaskDictationInsertion?
    private var endingDictation: Task<Void, Never>?
    private let preferences: UserDefaults

    init(dictation: DictationController, databaseURL: URL? = nil, preferences: UserDefaults = .standard) {
        self.dictation = dictation
        self.preferences = preferences
        activePane = preferences.string(forKey: "tasks.activePane").flatMap(TaskPane.init(rawValue:)) ?? .projects
        collapsedCategories = Set(preferences.stringArray(forKey: "tasks.collapsedCategories") ?? [])
        if let databaseURL {
            self.databaseURL = databaseURL
            store = TaskStore(url: databaseURL)
        }
        selectedProjectID = preferences.string(forKey: "tasks.selectedProject")
        selectedTaskID = preferences.string(forKey: "tasks.selectedTask")
        dictation.onFinishEmbeddedSession = { [weak self] in Task { await self?.finishDictation() } }
        textSubscription = dictation.$text.dropFirst().sink { [weak self] text in
            guard let self, self.editorMode == .dictation, let insertion = self.insertion else { return }
            self.edit(insertion.applying(text))
        }
    }

    var selectedProject: TaskProject? { projects.first { $0.id == selectedProjectID } }
    var newProjectCategory: TaskCategory? {
        categories.first { $0.id == selectedProject?.categoryID } ?? categories.first
    }
    var selectedTask: PersonalTask? { tasks.first { $0.id == selectedTaskID } }
    var dirty: Bool { draft != savedBody }
    var projectTasks: [PersonalTask] {
        tasks.filter { task in
            task.projectID == selectedProjectID
                && (showCompleted || !task.metadata.done || task.id == selectedTaskID)
        }
    }

    var visibleTasks: [PersonalTask] {
        TaskSearch.filter(projectTasks, query: search)
    }

    var visibleProjects: [TaskProject] {
        func children(_ parent: String?, category: String, ancestors: Set<String> = []) -> [TaskProject] {
            projects.filter { $0.categoryID == category && $0.parentID == parent && !ancestors.contains($0.id) }.flatMap { project in
                [project] + (expandedProjects.contains(project.id)
                    ? children(project.id, category: category, ancestors: ancestors.union([project.id])) : [])
            }
        }
        return categories.filter { !collapsedCategories.contains($0.id) }.flatMap { children(nil, category: $0.id) }
    }

    func activatePane(_ pane: TaskPane, requestFocus: Bool = true) {
        if pane != .tasks, isSearchingTasks {
            isSearchingTasks = false
            preSearchTaskID = nil
            search = ""
        }
        if activePane != pane {
            activePane = pane
            preferences.set(pane.rawValue, forKey: "tasks.activePane")
        }
        if requestFocus { onFocusRequested?() }
    }

    func beginTaskSearch() {
        guard activePane == .tasks, loaded, !busy, !conflict else { return }
        if !isSearchingTasks {
            preSearchTaskID = selectedTaskID
            isSearchingTasks = true
        }
        onSearchFocusRequested?()
    }

    func updateSearch(_ query: String) {
        guard search != query else { return }
        search = query
        let matches = visibleTasks
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let pre = preSearchTaskID, matches.contains(where: { $0.id == pre }) {
                selectTask(pre)
            } else if selectedTaskID == nil || !matches.contains(where: { $0.id == selectedTaskID }) {
                selectTask(matches.first?.id)
            }
        } else {
            selectTask(matches.first?.id)
        }
    }

    func commitTaskSearch() {
        guard isSearchingTasks else { return }
        let matches = visibleTasks
        let matched = selectedTaskID.flatMap { id in matches.first { $0.id == id } } ?? matches.first
        guard let matched else { return }
        isSearchingTasks = false
        preSearchTaskID = nil
        search = ""
        selectTask(matched.id)
        activatePane(.description)
        onScrollSelectionRequested?(.tasks)
    }

    func cancelTaskSearch() {
        guard isSearchingTasks || !search.isEmpty else { return }
        let restore = preSearchTaskID
        isSearchingTasks = false
        preSearchTaskID = nil
        search = ""
        let remaining = visibleTasks
        if let restore, remaining.contains(where: { $0.id == restore }) {
            selectTask(restore)
        } else if !remaining.contains(where: { $0.id == selectedTaskID }) {
            selectTask(remaining.first?.id)
        }
        activatePane(.tasks)
        onScrollSelectionRequested?(.tasks)
    }

    func enterPane() {
        guard !busy else { return }
        switch activePane {
        case .projects:
            guard selectedProject != nil else { return }
            activatePane(.tasks)
        case .tasks:
            guard selectedTask != nil else { return }
            activatePane(.description)
        case .description: break
        }
    }

    func leavePane() {
        guard !busy else { return }
        if activePane == .tasks { activatePane(.projects) }
        else if activePane == .description {
            busy = true
            Task { [self] in
                let saved = await finishEditing()
                busy = false
                if saved { activatePane(.tasks) }
            }
        }
    }

    func escapeDescription() {
        guard !busy else { return }
        switch editorMode {
        case .normal: leavePane()
        case .insert:
            editor?.leaveInsertMode(notify: false)
            changeEditorMode(.normal)
        case .dictation:
            if dictation.showingShortcuts { dictation.toggleShortcuts(); return }
            busy = true
            Task { [self] in
                await finishDictation()
                busy = false
                activatePane(.description)
            }
        }
    }

    func changeEditorMode(_ mode: TaskEditorMode) {
        let previous = editorMode
        if previous == .insert, mode == .normal {
            expandDueFormulas()
        }
        editorMode = mode
        if previous == .insert, mode == .normal {
            saveDebounce?.cancel()
            saveDebounce = Task { [weak self] in
                guard !Task.isCancelled else { return }
                await self?.flush()
            }
        }
    }

    private func expandDueFormulas() {
        if let editor {
            editor.expandDueDateFormulas()
        } else {
            let expanded = TaskMetadata.expandingDueFormulas(in: draft).text
            if expanded != draft { edit(expanded) }
        }
    }

    private func finishEditing() async -> Bool {
        await finishDictation()
        if editorMode == .insert { expandDueFormulas() }
        editor?.setMode(.normal, notify: false)
        editorMode = .normal
        return await flush()
    }

    func moveSelection(_ offset: Int) {
        guard !busy, !conflict else { return }
        let ids = activePane == .projects ? visibleProjects.map(\.id) : visibleTasks.map(\.id)
        let current = activePane == .projects ? selectedProjectID : selectedTaskID
        guard !ids.isEmpty else { return }
        let index = current.flatMap { ids.firstIndex(of: $0) }
        let next = ids[min(max((index ?? (offset > 0 ? -1 : ids.count)) + offset, 0), ids.count - 1)]
        if activePane == .projects { selectProject(next) }
        else if activePane == .tasks { selectTask(next) }
    }

    func start() {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            guard let self else { return }
            if !self.loaded { await self.open() }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(4)) } catch { break }
                if !self.loaded { await self.open() }
                else { await self.refresh() }
            }
        }
    }

    func stopMonitoring() { monitor?.cancel(); monitor = nil }

    func open() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            if store == nil {
                let url = try TaskDatabaseLocation.resolve()
                databaseURL = url
                store = TaskStore(url: url, backups: userDataDirectory().appendingPathComponent("task-backups", isDirectory: true))
            }
            guard let store else { return }
            install(try await store.open())
            loaded = true
            onFocusRequested?()
            errorMessage = ""
            storageStatus = await store.status()
            Logger.info("Task database opened: \(databaseURL?.path ?? "")")
        } catch {
            errorMessage = error.localizedDescription
            storageStatus = "Task database unavailable"
        }
    }

    func refresh() async {
        guard let store, !busy, saving == nil, !conflict else { return }
        storageStatus = dirty ? "Unsaved changes" : await store.status()
        guard !dirty, editorMode == .normal else { return }
        do {
            let snapshot = try await store.load()
            guard !busy, saving == nil, !conflict, !dirty, editorMode == .normal else { return }
            install(snapshot)
            errorMessage = ""
        } catch { errorMessage = error.localizedDescription }
    }

    func databaseLoadCount() async -> Int { await store?.loadCount ?? 0 }

    private func install(_ snapshot: TaskSnapshot) {
        categories = snapshot.categories
        projects = snapshot.projects
        tasks = snapshot.tasks
        if !projects.contains(where: { $0.id == selectedProjectID }) { selectedProjectID = projects.first?.id }
        if !tasks.contains(where: { $0.id == selectedTaskID && $0.projectID == selectedProjectID }) {
            selectedTaskID = defaultTaskID(for: selectedProjectID)
        }
        revealSelectedProject()
        loadSelection()
    }

    private func defaultTaskID(for projectID: String?) -> String? {
        guard let projectID else { return nil }
        return tasks.first { $0.projectID == projectID && !$0.metadata.done }?.id
            ?? (showCompleted ? tasks.first { $0.projectID == projectID }?.id : nil)
    }

    private func revealSelectedProject() {
        guard revealedProjectID != selectedProjectID else { return }
        var parent = selectedProject?.parentID
        var seen = Set<String>()
        while let id = parent, seen.insert(id).inserted {
            expandedProjects.insert(id)
            parent = projects.first { $0.id == id }?.parentID
        }
        revealedProjectID = selectedProjectID
    }

    private func loadSelection() {
        let body = selectedTask?.body ?? ""
        let changed = displayedTaskID != selectedTaskID || draft != body
        draft = body
        savedBody = draft
        if changed, editorMode != .normal { editorMode = .normal }
        displayedTaskID = selectedTaskID
        preferences.set(selectedProjectID, forKey: "tasks.selectedProject")
        preferences.set(selectedTaskID, forKey: "tasks.selectedTask")
    }

    func edit(_ body: String) {
        guard selectedTaskID != nil else { return }
        draft = body
        if let index = tasks.firstIndex(where: { $0.id == selectedTaskID }) { tasks[index].body = body }
        storageStatus = dirty ? "Unsaved changes" : storageStatus
        saveDebounce?.cancel()
        guard !conflict, editorMode == .normal else { return }
        saveDebounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await self?.flush()
        }
    }

    @discardableResult
    func flush() async -> Bool {
        guard editorMode == .normal else { return !dirty }
        saveDebounce?.cancel()
        saveDebounce = nil
        if let saving { return await saving.value }
        guard !conflict else { return false }
        guard let store, let id = selectedTaskID, dirty else { return !dirty }
        let operation = Task { [self] in
            defer { saving = nil }
            while dirty, editorMode == .normal {
                let body = draft
                let expected = savedBody
                storageStatus = "Saving…"
                do {
                    try await store.saveTask(id, body: body, expectedBody: expected)
                    savedBody = body
                    errorMessage = ""
                    let status = await store.status()
                    storageStatus = dirty ? "Unsaved changes" : status
                } catch {
                    if case TaskStoreError.conflict = error { conflict = true }
                    errorMessage = error.localizedDescription
                    storageStatus = "Draft kept in this window · save failed"
                    return false
                }
            }
            return !dirty
        }
        saving = operation
        return await operation.value
    }

    private var needsSaveBeforeSelectionChange: Bool {
        dirty || editorMode != .normal || saving != nil
    }

    func selectProject(_ id: String?) {
        guard id != selectedProjectID, !busy, !conflict else { return }
        if needsSaveBeforeSelectionChange {
            saveAndSelect { [self] in applyProjectSelection(id) }
        } else {
            applyProjectSelection(id)
        }
    }

    func selectTask(_ id: String?) {
        guard id != selectedTaskID, !busy, !conflict else { return }
        if needsSaveBeforeSelectionChange {
            saveAndSelect { [self] in applyTaskSelection(id) }
        } else {
            applyTaskSelection(id)
        }
    }

    private func saveAndSelect(_ apply: @escaping @MainActor () -> Void) {
        guard !busy, store != nil else { return }
        busy = true
        Task { [self] in
            defer { busy = false }
            guard await finishEditing() else { return }
            apply()
        }
    }

    private func applyProjectSelection(_ id: String?) {
        if isSearchingTasks || !search.isEmpty {
            isSearchingTasks = false
            preSearchTaskID = nil
            search = ""
        }
        selectedProjectID = id
        selectedTaskID = defaultTaskID(for: id)
        revealSelectedProject()
        loadSelection()
    }

    private func applyTaskSelection(_ id: String?) {
        selectedTaskID = id
        loadSelection()
    }

    func addProject(name: String, categoryID: String, parentID: String?) {
        perform(after: { [self] in
            collapsedCategories.remove(categoryID)
            activatePane(.projects)
        }) { [self] store in
            selectedProjectID = try await store.addProject(name: name, categoryID: categoryID, parentID: parentID)
            selectedTaskID = nil
        }
    }
    func addCategory(name: String) { perform { _ = try await $0.addCategory(name: name) } }
    func renameCategory(_ id: String, name: String) { perform { try await $0.renameCategory(id, name: name) } }
    func renameProject(_ id: String, name: String) { perform { try await $0.renameProject(id, name: name) } }
    func moveProject(_ id: String, parentID: String?, categoryID: String) { perform { try await $0.moveProject(id, to: parentID, categoryID: categoryID) } }
    func deleteProject(_ id: String) { perform { try await $0.deleteEmptyProject(id) } }
    func moveTask(_ id: String, projectID: String) { perform { try await $0.moveTask(id, projectID: projectID) } }

    func addTask() {
        guard let project = selectedProjectID else { return }
        perform(after: { [self] in
            isSearchingTasks = false
            preSearchTaskID = nil
            search = ""
            editorMode = .insert
            activatePane(.description)
        }) { [self] store in selectedTaskID = try await store.addTask(projectID: project) }
    }

    func deleteTask() {
        guard let id = selectedTaskID else { return }
        perform { [self] store in
            try await store.deleteTask(id, expectedBody: savedBody)
            selectedTaskID = nil
        }
    }

    func toggleCompletion(_ task: PersonalTask) {
        perform { [self] store in
            let current = tasks.first { $0.id == task.id } ?? task
            try await store.saveTask(current.id, body: TaskMetadata.togglingCompletion(in: current.body), expectedBody: current.body)
        }
    }

    /// Selection and structural changes are serialized after the current draft
    /// has saved. A failed save never changes the editing destination.
    private func perform(after: (@MainActor () -> Void)? = nil, _ operation: @escaping @MainActor (TaskStore) async throws -> Void) {
        guard !busy, let store else { return }
        busy = true
        Task { [self] in
            defer { busy = false }
            guard await finishEditing() else { return }
            do {
                try await operation(store)
                install(try await store.load())
                after?()
                storageStatus = await store.status()
                errorMessage = ""
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func saveConflictCopy() {
        guard conflict, let store, let projectID = selectedProjectID else { return }
        busy = true
        Task { [self] in
            defer { busy = false }
            await finishDictation(save: false)
            if let saving { _ = await saving.value }
            do {
                selectedTaskID = try await store.addTask(projectID: projectID, body: draft)
                conflict = false
                install(try await store.load())
                errorMessage = ""
                storageStatus = await store.status()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func discardDraftAndReload() {
        guard !busy, let store else { return }
        busy = true
        Task { [self] in
            defer { busy = false }
            await finishDictation(save: false)
            if let saving { _ = await saving.value }
            saveDebounce?.cancel()
            do {
                let snapshot = try await store.load()
                conflict = false
                install(snapshot)
                errorMessage = ""
                storageStatus = await store.status()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func beginDictation() {
        guard !busy, !conflict, selectedTaskID != nil, editorMode != .dictation else { return }
        busy = true
        Task { [self] in
            defer { busy = false }
            await beforeDictation?()
            let selection = editor?.selectedRange() ?? NSRange(location: (draft as NSString).length, length: 0)
            editor?.setMode(.normal, notify: false)
            insertion = TaskDictationInsertion(text: draft, selection: selection)
            activatePane(.description, requestFocus: false)
            dictation.beginNewSession()
            editorMode = .dictation
            dictation.startDictation()
        }
    }

    func finishDictation(save: Bool = true) async {
        if let endingDictation { await endingDictation.value; return }
        guard editorMode == .dictation, let insertion else { return }
        let operation = Task { [self] in
            let text = await dictation.finishForDocument()
            let result = insertion.result(for: text)
            let expanded = TaskMetadata.expandingDueFormulas(in: result.body, cursorLocation: result.cursorLocation)
            edit(expanded.text)
            self.insertion = nil
            editorMode = .normal
            editor?.finishDictation(original: insertion.original, body: expanded.text, cursorLocation: expanded.cursorLocation)
            editor?.window?.makeFirstResponder(editor)
            if save { _ = await flush() }
            else { saveDebounce?.cancel(); saveDebounce = nil }
            endingDictation = nil
        }
        endingDictation = operation
        await operation.value
    }

    func prepareToClose() async -> Bool {
        while busy { try? await Task.sleep(for: .milliseconds(20)) }
        let saved = await finishEditing()
        if saved { stopMonitoring() }
        return saved
    }

    func projectPath(_ project: TaskProject) -> String {
        var names = [project.name]
        var parent = project.parentID
        var seen: Set<String> = [project.id]
        while let id = parent, seen.insert(id).inserted, let item = projects.first(where: { $0.id == id }) {
            names.insert(item.name, at: 0)
            parent = item.parentID
        }
        return names.joined(separator: " / ")
    }
}
