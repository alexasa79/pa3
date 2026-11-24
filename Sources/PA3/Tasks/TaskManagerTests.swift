import AppKit
import Combine
import CSQLite
import SwiftUI

@MainActor
func runTaskManagerTests() async -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ name: String) { if !condition { failures.append("tasks: " + name) } }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pa3-tasks-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("pa3.sqlite")
    let backups = folder.appendingPathComponent("backups")
    let store = TaskStore(url: url, backups: backups)
    do {
        let initial = try await store.open()
        check(initial.categories.map(\.name) == ["Home", "Work"], "initial categories")
        check(initial.projects.isEmpty && initial.tasks.isEmpty, "no invented projects or tasks")
        let home = initial.categories[0].id
        let work = initial.categories[1].id
        let project = try await store.addProject(name: "Personal", categoryID: home, parentID: nil)
        let child = try await store.addProject(name: "House", categoryID: home, parentID: project)
        let grandchild = try await store.addProject(name: "Kitchen", categoryID: home, parentID: child)
        do {
            try await store.moveProject(project, to: grandchild, categoryID: home)
            check(false, "reject project cycle")
        } catch {}
        do {
            _ = try await store.addProject(name: "Invalid", categoryID: work, parentID: project)
            check(false, "reject category mismatch")
        } catch {}
        try await store.moveProject(project, to: nil, categoryID: work)
        let moved = try await store.load()
        check(moved.projects.count == 3 && moved.projects.allSatisfy { $0.categoryID == work }, "moving category includes every descendant")
        check(moved.projects.first { $0.id == grandchild }?.parentID == child, "moving preserves tree ancestry")
        do { try await store.deleteEmptyProject(project); check(false, "nonempty project is protected") } catch {}

        let body = "Fix kitchen\n\n  Preserve  spacing\tand שלום 👨‍👩‍👧‍👦.\n#due:2026-11-15 #priority:1\n#unknown:leave-it\n"
        let id = try await store.addTask(projectID: child, body: body)
        let reopened = TaskStore(url: url)
        let loaded = try await reopened.open()
        check(loaded.tasks.first?.body == body, "exact text survives a new database connection")
        check(loaded.tasks.first?.subject == "Fix kitchen", "subject derives from first line")
        try await store.saveTask(id, body: body + "Mac A", expectedBody: body)
        do {
            try await reopened.saveTask(id, body: body + "Mac B", expectedBody: body)
            check(false, "stale save is rejected")
        } catch TaskStoreError.conflict {} catch { check(false, "stale save reports a document conflict") }
        let afterConflict = try await store.load()
        check(afterConflict.tasks.first?.body == body + "Mac A", "conflicting save preserves latest database contents")
        try await store.moveTask(id, projectID: grandchild)
        let afterMove = try await store.load()
        check(afterMove.tasks.first?.projectID == grandchild, "move task between projects")
        do { try await store.deleteTask(id, expectedBody: body); check(false, "stale delete is rejected") } catch {}
        let backupFiles = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        check(backupFiles.filter { $0.pathExtension == "sqlite" }.count == 1, "writes create one snapshot per backup interval")

        var connection: OpaquePointer?
        sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil)
        func query(_ sql: String) -> [String] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            var result: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let value = sqlite3_column_text(statement, 0) { result.append(String(cString: value)) }
            }
            return result
        }
        check(query("PRAGMA journal_mode") == ["delete"], "database does not depend on a WAL file")
        check(query("PRAGMA integrity_check") == ["ok"], "database integrity after operations")
        let columns = query("SELECT name FROM pragma_table_info('tasks')")
        check(columns.contains("description") && !columns.contains("title") && !columns.contains("due_date") && !columns.contains("priority") && !columns.contains("status"), "task metadata has no duplicate database columns")
        sqlite3_close(connection)
        check(!FileManager.default.fileExists(atPath: url.path + "-wal"), "no WAL sidecar left after writes")

        let suite = "PA3TasksTests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(grandchild, forKey: "tasks.selectedProject")
        preferences.set(id, forKey: "tasks.selectedTask")
        let controller = DictationController(transcriber: TranscriberService(), preferences: preferences)
        let model = TaskManagerModel(dictation: controller, databaseURL: url, preferences: preferences)
        await model.open()
        model.editorMode = .insert
        await model.refresh()
        check(model.editorMode == .insert, "background refresh preserves insert mode")
        model.edit("A new subject\n#done\n")
        try await Task.sleep(for: .milliseconds(450))
        check(try await store.load().tasks.first?.body == body + "Mac A", "Insert keeps changes in memory past the old autosave delay")
        check(!(await model.flush()), "save requests cannot write an active Insert draft")
        model.escapeDescription()
        check(await model.flush(), "leaving Insert saves the draft")
        let modelSaved = try await store.load()
        check(modelSaved.tasks.first?.body == "A new subject\n#done\n", "model persists exact draft")
        try await store.saveTask(id, body: "External edit", expectedBody: "A new subject\n#done\n")
        model.edit("My unsaved draft")
        check(!(await model.flush()) && model.conflict, "model retains a conflicting draft")
        check(model.draft == "My unsaved draft" && model.selectedTaskID == id, "save failure retains editing destination")
        model.edit("A new subject\n#done\n")
        await model.refresh()
        check(model.conflict && !model.errorMessage.isEmpty, "refresh cannot hide an unresolved conflict even if the draft matches the old base")
        model.edit("My unsaved draft")
        model.selectProject(project)
        for _ in 0..<100 where model.busy { try await Task.sleep(for: .milliseconds(10)) }
        check(model.selectedProjectID == grandchild, "navigation cannot discard a failed save")
        model.saveConflictCopy()
        for _ in 0..<100 where model.busy { try await Task.sleep(for: .milliseconds(10)) }
        let kept = try await store.load()
        check(kept.tasks.contains { $0.id == id && $0.body == "External edit" }
              && kept.tasks.contains { $0.id != id && $0.body == "My unsaved draft" }, "save-copy preserves both conflicting versions")
        let dictatedTaskID = model.selectedTaskID
        controller.prepareModels = { false } // Exercise shared commands without opening a microphone.
        model.beginDictation()
        for _ in 0..<100 where model.busy { try await Task.sleep(for: .milliseconds(10)) }
        check(model.editorMode == .dictation, "task enters the shared dictation editor")
        controller.handleTranscription(TranscriptionUpdate(text: "Dictated addition.", language: "en"))
        check(model.draft == "My unsaved draft Dictated addition.", "validated speech is published into the original document")
        try await Task.sleep(for: .milliseconds(450))
        check(try await store.load().tasks.first { $0.id == dictatedTaskID }?.body == "My unsaved draft",
              "live dictation stays in memory past the old autosave delay")
        check(!(await model.flush()), "save requests cannot write during Dictation")
        model.selectProject(project)
        for _ in 0..<100 where model.busy { try await Task.sleep(for: .milliseconds(10)) }
        let afterDictation = try await store.load()
        check(model.selectedProjectID == project && model.editorMode == .normal, "navigation finishes dictation before changing projects")
        check(afterDictation.tasks.first { $0.id == dictatedTaskID }?.body == "My unsaved draft Dictated addition.", "dictation saves into its original task before navigation")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 720),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: TaskManagerView(model: model))
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        window.contentView?.layoutSubtreeIfNeeded()
        func findSplit(_ view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView, split.subviews.count == 3 { return split }
            return view.subviews.lazy.compactMap { findSplit($0) }.first
        }
        if let content = window.contentView, let split = findSplit(content) {
            let half = split.subviews[0].frame.width + split.subviews[1].frame.width
            check(abs(half / split.bounds.width - 0.5) < 0.03, "project and task panes initially occupy half the window")
            check(split.subviews[0].frame.width >= 180 && split.subviews[1].frame.width >= 200, "both leading panes remain visible")
        } else { check(false, "task window contains three native split panes") }
        model.stopMonitoring()

        let placeholderURL = folder.appendingPathComponent("unavailable.sqlite")
        try Data().write(to: folder.appendingPathComponent(".unavailable.sqlite.icloud"))
        do { _ = try await TaskStore(url: placeholderURL).open(); check(false, "placeholder is never replaced by an empty database") } catch {}
        check(!FileManager.default.fileExists(atPath: placeholderURL.path), "placeholder access does not create a database")
        let missingHome = folder.appendingPathComponent("missing-home")
        do { _ = try TaskDatabaseLocation.resolve(environment: [:], home: missingHome); check(false, "missing iCloud Drive is reported") } catch {}
    } catch { failures.append("tasks: unexpected storage error: \(error)") }

    let metadata = TaskMetadata("Subject\n#due:2026-02-28, #priority:2 #unknown:value")
    check(metadata.due == "2026-02-28" && metadata.priority == 2 && metadata.warnings.isEmpty, "parse tags anywhere in the body")
    check(TaskMetadata("#due:2026-02-30").due == nil && !TaskMetadata("#due:2026-02-30").warnings.isEmpty, "reject invalid calendar dates")
    check(TaskMetadata("#due:2028-02-29").due == "2028-02-29", "accept leap day")
    for level in 0...5 {
        check(TaskMetadata("#pri:\(level)").priority == level && TaskMetadata("#pri:\(level)").warnings.isEmpty, "accept #pri:\(level)")
        check(TaskMetadata("#prio:p\(level)").priority == level && TaskMetadata("#prio:p\(level)").warnings.isEmpty, "accept #prio:p\(level)")
        check(TaskMetadata("#priority:P\(level)").priority == level && TaskMetadata("#priority:P\(level)").warnings.isEmpty, "accept #priority:P\(level)")
    }
    check(TaskMetadata("#PRI:p0.").priority == 0 && TaskMetadata("#PRI:p0.").warnings.isEmpty, "accept case-insensitive #PRI:p0 with trailing punctuation")
    let duplicatePriority = TaskMetadata("#pri:4 #prio:p1")
    check(duplicatePriority.priority == 1 && !duplicatePriority.warnings.isEmpty, "multiple priority tags across aliases use last valid value and warn")
    for invalid in ["#priority:6", "#pri:p6", "#prio:-1", "#priority:p", "#pri:pp1", "#prio:01", "#priority:9"] {
        let parsed = TaskMetadata(invalid)
        check(parsed.priority == nil && !parsed.warnings.isEmpty, "reject invalid priority \(invalid)")
    }
    check(TaskMetadata("#due:2026-01-01 #due:2026-01-02").due == "2026-01-02", "duplicate tag rule is deterministic")
    check(TaskMetadata("Subject\n#done").done && TaskMetadata("#status:done").done, "completion lives in text")
    let completed = TaskMetadata.togglingCompletion(in: "Subject\n#due:2026-11-15 #unknown:x")
    check(TaskMetadata(completed).done && completed.contains("#unknown:x"), "completion preserves other tags")
    check(!TaskMetadata(TaskMetadata.togglingCompletion(in: completed)).done, "completion can be undone in text")

    let exact = "Subject\n\n  Before  HERE\tשלום\n#due:2026-11-15\n"
    let insertion = TaskDictationInsertion(text: exact, selection: (exact as NSString).range(of: "HERE"))
    check(insertion.applying("replacement") == exact.replacingOccurrences(of: "HERE", with: "replacement"), "dictation preserves surrounding whitespace and tags")
    check(insertion.applying("") == exact, "empty recognition never deletes the selection")
    check(TaskDictationInsertion(text: "beforeafter", selection: NSRange(location: 6, length: 0)).applying("words") == "before words after", "dictation insertion separates adjacent words")
    let joined = TaskDictationInsertion(text: "beforeafter", selection: NSRange(location: 6, length: 0)).result(for: "words")
    check(joined.body == "before words after" && joined.cursorLocation == 12,
          "cursor ends after dictated words, before the preserved suffix and its joining space")
    let spoken = "שלום 👨‍👩‍👧‍👦"
    let replaced = insertion.result(for: spoken)
    check(replaced.cursorLocation == (replaced.body as NSString).range(of: spoken).upperBound,
          "replacement cursor uses UTF-16 offsets through composed Unicode text")
    check(insertion.result(for: "").cursorLocation == insertion.range.location,
          "empty dictation keeps the original insertion point")

    failures += runTaskModalEditorTests()
    failures += runTaskEditorParityTests()
    failures += runTaskTextNavigationTests()
    failures += runTaskLineNumberTests()
    failures += runTaskSearchRankingTests()
    failures += await runTaskNavigationTests()
    failures += await runTaskListScrollingTests()
    failures += await runTaskSearchInteractionTests()
    return failures
}

private func runTaskSearchRankingTests() -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ name: String) { if !condition { failures.append("task search: " + name) } }
    func task(_ id: String, _ body: String) -> PersonalTask { PersonalTask(id: id, projectID: "p", body: body) }

    let sample = [
        task("unrelated", "Buy groceries\nMilk and eggs"),
        task("partial", "Fix bathroom door\nReplace hinges"),
        task("out-of-order", "Kitchen repair: fix faucet"),
        task("in-order", "Fix the broken kitchen sink"),
        task("exact-body", "Home repairs\nNeed to fix kitchen sink soon"),
        task("exact-subject", "Fix kitchen sink\nCall plumber")
    ]

    let ranked = TaskSearch.filter(sample, query: "fix kitchen")
    check(ranked.map(\.id) == ["exact-subject", "exact-body", "in-order", "out-of-order", "partial"],
          "ranks exact subject > exact body > in-order > out-of-order > partial and drops non-matches (got \(ranked.map(\.id)))")

    let emptyQuery = TaskSearch.filter(sample, query: "   ")
    check(emptyQuery.map(\.id) == sample.map(\.id), "whitespace query preserves original list order")

    let none = TaskSearch.filter(sample, query: "kubernetes")
    check(none.isEmpty, "non-matching query filters out every task")

    let boundary = [
        task("substring", "Hotfix deployment"),
        task("whole", "Fix login flow")
    ]
    check(TaskSearch.filter(boundary, query: "fix").map(\.id) == ["whole", "substring"],
          "whole-word subject match outranks mid-word substring")

    let fuzzy = [
        task("milk", "Buy milk"),
        task("kitchen", "Repair kitchen cabinets")
    ]
    check(TaskSearch.filter(fuzzy, query: "kchn").map(\.id) == ["kitchen"],
          "fuzzy subsequence matches compact word abbreviation")
    check(TaskSearch.filter(fuzzy, query: "kithcen").map(\.id) == ["kitchen"],
          "single transposition typo still matches")

    let partialCounts = [
        task("one", "Alpha task"),
        task("two", "Alpha beta task"),
        task("three", "Alpha beta gamma task")
    ]
    check(TaskSearch.filter(partialCounts, query: "alpha beta delta").map(\.id) == ["two", "three", "one"],
          "partial matches prefer tasks matching more query words")

    let tagged = [
        task("reverse", "Auth follow-up for JIRA-412"),
        task("forward", "JIRA-412 auth timeout #waiting")
    ]
    check(TaskSearch.filter(tagged, query: "jira-412 auth").map(\.id) == ["forward", "reverse"],
          "punctuation-bearing ticket IDs preserve word order accurately")
    check(TaskSearch.filter(tagged, query: "#waiting").map(\.id) == ["forward"],
          "hashtag queries match tags in body")

    return failures
}

@MainActor
private func runTaskSearchInteractionTests() async -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ name: String) { if !condition { failures.append("task search ui: " + name) } }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pa3-search-\(UUID().uuidString)")
    let suite = "PA3Search-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    defer { try? FileManager.default.removeItem(at: folder); preferences.removePersistentDomain(forName: suite) }
    let url = folder.appendingPathComponent("pa3.sqlite")
    let store = TaskStore(url: url)
    do {
        let snapshot = try await store.open()
        let work = snapshot.categories[1].id
        let projectA = try await store.addProject(name: "Project A", categoryID: work, parentID: nil)
        let projectB = try await store.addProject(name: "Project B", categoryID: work, parentID: nil)
        let t1 = try await store.addTask(projectID: projectA, body: "Setup laptop\nInstall tools")
        let t2 = try await store.addTask(projectID: projectA, body: "Kitchen repair: fix faucet")
        let t3 = try await store.addTask(projectID: projectA, body: "Fix kitchen sink\nCall plumber")
        let tOther = try await store.addTask(projectID: projectB, body: "Fix kitchen in project B")

        let controller = DictationController(transcriber: TranscriberService(), preferences: preferences)
        controller.prepareModels = { false }
        let model = TaskManagerModel(dictation: controller, databaseURL: url, preferences: preferences)
        await model.open()
        let manager = TaskManagerWindow(model: model)
        guard let window = manager.window as? TaskNavigationWindow else { return failures + ["task search ui: missing window"] }
        defer { window.orderOut(nil); model.stopMonitoring() }
        manager.present()
        window.contentView?.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(80))

        func event(_ key: String = "", code: UInt16 = 0, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                             windowNumber: window.windowNumber, context: nil, characters: key,
                             charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
        }

        // / in projects does not open task search.
        check(!window.handleTaskKey(event("/", code: 44)) && !model.isSearchingTasks,
              "/ in projects does not open task search")

        // Enter tasks pane and press / to open fuzzy search.
        check(window.handleTaskKey(event(code: 36)), "Return enters tasks pane")
        check(model.activePane == .tasks && model.selectedTaskID == t1, "tasks pane starts on first task")
        check(window.handleTaskKey(event("/", code: 44)), "/ opens task search in tasks pane")
        check(model.isSearchingTasks, "task search dialog state is active")
        try? await Task.sleep(for: .milliseconds(80))
        window.contentView?.layoutSubtreeIfNeeded()
        let focusedSearch = (window.firstResponder as? NSTextView)?.delegate as? NSView
        check(focusedSearch?.identifier?.rawValue == "tasks.search.field",
              "opening search focuses the search field (responder: \(String(describing: window.firstResponder)))")

        // Typing j/k/n/q/? stays in search field and never triggers list/window shortcuts.
        check(!window.handleTaskKey(event("q", code: 12)) && window.isVisible, "q does not close window while searching")
        check(!window.handleTaskKey(event("n", code: 45)) && model.tasks.count == 4, "n does not create a task while searching")
        check(!window.handleTaskKey(event("?", code: 44, flags: .shift)) && !model.showingShortcutHelp, "? does not open help while searching")
        check(!window.handleTaskKey(event("j", code: 38)) && !window.handleTaskKey(event("k", code: 40)), "j/k go to search text while searching")

        // Fuzzy query narrows to current project only, ranks exact above out-of-order, and auto-selects #1 with zero DB reads.
        let loadsBefore = await model.databaseLoadCount()
        model.updateSearch("fix kitchen")
        check(model.visibleTasks.map(\.id) == [t3, t2] && !model.visibleTasks.contains { $0.id == tOther },
              "fuzzy search filters current project only and ranks exact before out-of-order")
        check(model.selectedTaskID == t3, "typing query auto-selects top-ranked match")
        check(await model.databaseLoadCount() == loadsBefore, "live search performs zero database loads")

        // Down / Control-P step through matches while keeping search open.
        check(window.handleTaskKey(event(code: 125)) && model.selectedTaskID == t2 && model.isSearchingTasks,
              "Down selects next fuzzy match while keeping search open")
        check(window.handleTaskKey(event("p", code: 35, flags: .control)) && model.selectedTaskID == t3 && model.isSearchingTasks,
              "Control-P selects previous fuzzy match while keeping search open")

        // Return commits selection, clears search, and opens description.
        check(window.handleTaskKey(event(code: 125)) && model.selectedTaskID == t2, "move to second match before Return")
        check(window.handleTaskKey(event(code: 36)), "Return commits search")
        try? await Task.sleep(for: .milliseconds(60))
        check(!model.isSearchingTasks && model.search.isEmpty && model.selectedTaskID == t2
              && model.activePane == .description && window.firstResponder === model.editor,
              "Return opens selected match in description and clears search")

        // Return to tasks, open search via Command-F, verify no-match and Escape cancel restores pre-search task.
        check(window.handleTaskKey(event(code: 53)), "Escape returns from description to tasks")
        try? await Task.sleep(for: .milliseconds(60))
        check(model.activePane == .tasks && model.selectedTaskID == t2, "task t2 remains selected in full list")
        check(window.handleTaskKey(event("f", code: 3, flags: .command)) && model.isSearchingTasks,
              "Command-F opens task search in tasks pane")
        model.updateSearch("zzznomatch")
        check(model.visibleTasks.isEmpty && model.selectedTaskID == nil, "non-matching query empties visible tasks")
        check(window.handleTaskKey(event(code: 36)) && model.isSearchingTasks, "Return with zero matches keeps search open")
        check(window.handleTaskKey(event(code: 53)), "Escape cancels search")
        try? await Task.sleep(for: .milliseconds(60))
        check(!model.isSearchingTasks && model.search.isEmpty && model.selectedTaskID == t2
              && (window.firstResponder as? NSView)?.identifier?.rawValue == "tasks.pane.tasks",
              "Escape clears search, restores pre-search selection, and focuses tasks pane")

        // Switching projects clears active search cleanly.
        check(window.handleTaskKey(event("/", code: 44)), "/ opens search before switching projects")
        model.updateSearch("kitchen")
        model.selectProject(projectB)
        check(!model.isSearchingTasks && model.search.isEmpty && model.selectedProjectID == projectB
              && model.visibleTasks.map(\.id) == [tOther],
              "switching projects clears active search")
    } catch { failures.append("task search ui: \(error)") }
    return failures
}

@MainActor
private func runTaskListScrollingTests() async -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ name: String) { if !condition { failures.append("task scrolling: " + name) } }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pa3-scrolling-\(UUID().uuidString)")
    let suite = "PA3Scrolling-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    defer { try? FileManager.default.removeItem(at: folder); preferences.removePersistentDomain(forName: suite) }
    let url = folder.appendingPathComponent("pa3.sqlite")
    let store = TaskStore(url: url)
    do {
        let snapshot = try await store.open()
        let work = snapshot.categories[1].id
        var projectIDs: [String] = []
        for index in 1...40 {
            projectIDs.append(try await store.addProject(name: "Project \(index)", categoryID: work, parentID: nil))
        }
        let nestedProject = try await store.addProject(name: "Nested 36", categoryID: work, parentID: projectIDs[35])
        let targetProject = projectIDs[0]
        var taskIDs: [String] = []
        for index in 1...40 {
            taskIDs.append(try await store.addTask(projectID: targetProject, body: "Task \(index)\nBody for task \(index)"))
        }
        let controller = DictationController(transcriber: TranscriberService(), preferences: preferences)
        controller.prepareModels = { false }
        let model = TaskManagerModel(dictation: controller, databaseURL: url, preferences: preferences)
        await model.open()
        let manager = TaskManagerWindow(model: model)
        guard let window = manager.window as? TaskNavigationWindow else { return failures + ["task scrolling: missing window"] }
        defer { window.orderOut(nil); model.stopMonitoring() }
        window.setContentSize(NSSize(width: 1240, height: 480))
        manager.present()
        window.contentView?.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(120))
        window.contentView?.layoutSubtreeIfNeeded()

        func event(_ key: String = "", code: UInt16 = 0) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                             windowNumber: window.windowNumber, context: nil, characters: key,
                             charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
        }
        func findPane(_ pane: TaskPane, in view: NSView?) -> NSView? {
            guard let view else { return nil }
            if view.identifier?.rawValue == "tasks.pane.\(pane.rawValue)" { return view }
            return view.subviews.lazy.compactMap { findPane(pane, in: $0) }.first
        }
        func findTable(in view: NSView?) -> NSTableView? {
            guard let view else { return nil }
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { findTable(in: $0) }.first
        }
        func selectedRowVisible(in pane: TaskPane) -> (visible: Bool, detail: String) {
            window.contentView?.layoutSubtreeIfNeeded()
            guard let host = findPane(pane, in: window.contentView),
                  let table = findTable(in: host),
                  let scroll = table.enclosingScrollView else {
                return (false, "missing table view")
            }
            let row = table.selectedRow
            guard row >= 0 else { return (false, "no selected row (rows: \(table.numberOfRows))") }
            let rowRect = table.rect(ofRow: row)
            let visibleRect = scroll.documentVisibleRect
            let visible = visibleRect.intersects(rowRect) && rowRect.minY >= visibleRect.minY - 1 && rowRect.maxY <= visibleRect.maxY + 1
            return (visible, "row=\(row) rowRect=\(rowRect) visibleRect=\(visibleRect)")
        }

        // Rapid project navigation stays strictly in memory with zero DB reloads.
        let loadsBeforeProjects = await model.databaseLoadCount()
        for _ in 0..<35 {
            check(window.handleTaskKey(event("j")), "rapid j in projects")
            check(!model.busy, "rapid project navigation never sets busy")
        }
        check(model.selectedProjectID == projectIDs[35], "35 rapid j steps reach project 36 without dropping keys")
        check(await model.databaseLoadCount() == loadsBeforeProjects, "project navigation reads from memory with zero database loads")
        try? await Task.sleep(for: .milliseconds(120))
        let projectDown = selectedRowVisible(in: .projects)
        check(projectDown.visible, "projects list auto-scrolls down to selected project (\(projectDown.detail))")

        model.expandedProjects.insert(projectIDs[35])
        try? await Task.sleep(for: .milliseconds(60))
        check(window.handleTaskKey(event("j")), "j steps into expanded nested subproject")
        check(model.selectedProjectID == nestedProject, "nested subproject is selected")
        try? await Task.sleep(for: .milliseconds(120))
        let nestedVisible = selectedRowVisible(in: .projects)
        check(nestedVisible.visible, "projects list auto-scrolls to nested subproject (\(nestedVisible.detail))")

        for _ in 0..<36 {
            check(window.handleTaskKey(event("k")), "rapid k in projects")
        }
        check(model.selectedProjectID == projectIDs[0], "36 rapid k steps return to project 1")
        check(await model.databaseLoadCount() == loadsBeforeProjects, "upward project navigation performs zero database loads")
        try? await Task.sleep(for: .milliseconds(120))
        let projectUp = selectedRowVisible(in: .projects)
        check(projectUp.visible, "projects list auto-scrolls back up to first project (\(projectUp.detail))")

        // Switch to tasks pane and rapidly navigate through 40 tasks.
        check(window.handleTaskKey(event(code: 36)), "Return enters tasks pane")
        check(model.activePane == .tasks && model.selectedTaskID == taskIDs[0], "tasks pane starts on task 1")
        let loadsBeforeTasks = await model.databaseLoadCount()
        for _ in 0..<35 {
            check(window.handleTaskKey(event(code: 125)), "rapid Down in tasks")
            check(!model.busy, "rapid task navigation never sets busy")
        }
        check(model.selectedTaskID == taskIDs[35] && model.draft == "Task 36\nBody for task 36",
              "35 rapid Down steps reach task 36 and load its description from memory")
        check(await model.databaseLoadCount() == loadsBeforeTasks, "task navigation reads from memory with zero database loads")
        try? await Task.sleep(for: .milliseconds(120))
        let taskDown = selectedRowVisible(in: .tasks)
        check(taskDown.visible, "tasks list auto-scrolls down to selected task (\(taskDown.detail))")

        for _ in 0..<35 {
            check(window.handleTaskKey(event(code: 126)), "rapid Up in tasks")
        }
        check(model.selectedTaskID == taskIDs[0] && model.draft == "Task 1\nBody for task 1",
              "35 rapid Up steps return to task 1")
        check(await model.databaseLoadCount() == loadsBeforeTasks, "upward task navigation performs zero database loads")
        try? await Task.sleep(for: .milliseconds(120))
        let taskUp = selectedRowVisible(in: .tasks)
        check(taskUp.visible, "tasks list auto-scrolls back up to first task (\(taskUp.detail))")

        // Dirty edits still flush before switching tasks.
        model.editorMode = .insert
        model.edit("Task 1 edited\nUpdated body")
        model.selectTask(taskIDs[1])
        for _ in 0..<100 where model.busy { try? await Task.sleep(for: .milliseconds(10)) }
        check(model.selectedTaskID == taskIDs[1] && model.draft == "Task 2\nBody for task 2",
              "switching from a dirty task moves to the requested task after saving")
        let persisted = try await store.load()
        check(persisted.tasks.first { $0.id == taskIDs[0] }?.body == "Task 1 edited\nUpdated body",
              "dirty edit is persisted to SQLite before changing task selection")

        // Reopening with a restored deep selection scrolls the restored task into view.
        preferences.set(targetProject, forKey: "tasks.selectedProject")
        preferences.set(taskIDs[35], forKey: "tasks.selectedTask")
        let restoredModel = TaskManagerModel(dictation: DictationController(transcriber: TranscriberService(), preferences: preferences), databaseURL: url, preferences: preferences)
        await restoredModel.open()
        let restoredManager = TaskManagerWindow(model: restoredModel)
        if let restoredWindow = restoredManager.window as? TaskNavigationWindow {
            defer { restoredWindow.orderOut(nil); restoredModel.stopMonitoring() }
            restoredWindow.setContentSize(NSSize(width: 1240, height: 480))
            restoredManager.present()
            restoredWindow.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(150))
            restoredWindow.contentView?.layoutSubtreeIfNeeded()
            if let host = findPane(.tasks, in: restoredWindow.contentView),
               let table = findTable(in: host),
               let scroll = table.enclosingScrollView,
               table.selectedRow >= 0 {
                let rowRect = table.rect(ofRow: table.selectedRow)
                let visibleRect = scroll.documentVisibleRect
                let visible = visibleRect.intersects(rowRect) && rowRect.minY >= visibleRect.minY - 1 && rowRect.maxY <= visibleRect.maxY + 1
                check(visible, "initial open scrolls restored deep task into view (row=\(table.selectedRow) rowRect=\(rowRect) visibleRect=\(visibleRect))")
            } else { check(false, "restored window has selectable tasks table") }
        } else { check(false, "restored window exists") }
    } catch { failures.append("task scrolling: \(error)") }
    return failures
}

@MainActor
private final class TaskQuitProbe: NSObject {
    var invoked = false
    @objc func quit(_ sender: Any?) { invoked = true }
}

@MainActor
private func runTaskNavigationTests() async -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ name: String) { if !condition { failures.append("task navigation: " + name) } }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pa3-navigation-\(UUID().uuidString)")
    let suite = "PA3Navigation-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    defer { try? FileManager.default.removeItem(at: folder); preferences.removePersistentDomain(forName: suite) }
    let url = folder.appendingPathComponent("pa3.sqlite")
    let store = TaskStore(url: url)
    do {
        let snapshot = try await store.open()
        let home = snapshot.categories[0].id
        let work = snapshot.categories[1].id
        let root = try await store.addProject(name: "Home root", categoryID: home, parentID: nil)
        let child = try await store.addProject(name: "Child", categoryID: home, parentID: root)
        let workProject = try await store.addProject(name: "Work root", categoryID: work, parentID: nil)
        let first = try await store.addTask(projectID: root, body: "First")
        let second = try await store.addTask(projectID: root, body: "Second")
        let controller = DictationController(transcriber: TranscriberService(), preferences: preferences)
        controller.prepareModels = { false }
        let model = TaskManagerModel(dictation: controller, databaseURL: url, preferences: preferences)
        await model.open()
        check(model.activePane == .projects, "first launch starts in projects")
        model.expandedProjects.insert(root)
        check(model.visibleProjects.map(\.id) == [root, child, workProject], "keyboard order follows the visible project tree")
        model.collapsedCategories.insert(home)
        check(model.visibleProjects.map(\.id) == [workProject], "collapsed categories are skipped by keyboard navigation")
        await model.refresh()
        check(model.collapsedCategories.contains(home), "refresh preserves category collapse")
        model.collapsedCategories.remove(home)
        model.expandedProjects.remove(root)
        check(model.visibleProjects.map(\.id) == [root, workProject], "collapsed subprojects are skipped")
        model.addCategory(name: "Other")
        func settle() async {
            for _ in 0..<200 where model.busy { try? await Task.sleep(for: .milliseconds(10)) }
            try? await Task.sleep(for: .milliseconds(60))
        }
        await settle()
        check(model.categories.contains { $0.name == "Other" }, "new categories are saved and loaded")
        let manager = TaskManagerWindow(model: model)
        guard let window = manager.window as? TaskNavigationWindow else { return failures + ["task navigation: missing window router"] }
        defer { window.orderOut(nil); model.stopMonitoring() }
        manager.present()
        await settle()
        func event(_ key: String = "", code: UInt16 = 0, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                             windowNumber: window.windowNumber, context: nil, characters: key,
                             charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
        }
        func press(_ key: String = "", code: UInt16 = 0, flags: NSEvent.ModifierFlags = []) {
            check(window.handleTaskKey(event(key, code: code, flags: flags)), "window handles \(key.isEmpty ? String(code) : key)")
        }
        func waitForClose() async {
            for _ in 0..<200 where window.isVisible && !model.conflict {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        func waitForHelp(_ visible: Bool) async {
            for _ in 0..<200 where (window.attachedSheet != nil) != visible {
                try? await Task.sleep(for: .milliseconds(10))
            }
            await settle()
        }
        check((window.firstResponder as? NSView)?.identifier?.rawValue == "tasks.pane.projects", "initial native focus is the project pane")
        press("j"); await settle()
        check(model.selectedProjectID == workProject, "j selects the next visible project")
        press("k"); await settle()
        check(model.selectedProjectID == root, "k selects the previous visible project")
        let initialCount = model.tasks.count
        press("n", flags: .command); await settle()
        check(model.tasks.count == initialCount, "Command-N does nothing in projects")
        model.selectProject(workProject); await settle()
        let projectCount = model.projects.count
        press("n"); await waitForHelp(true)
        check(model.showingNewProjectPrompt && window.attachedSheet != nil && model.newProjectCategory?.id == work,
              "n in projects opens a name prompt in the selected project's category")
        check(!window.handleTaskKey(event("n")), "n belongs to the project name field while the prompt is open")
        func button(_ title: String, in view: NSView?) -> NSButton? {
            guard let view else { return nil }
            if let button = view as? NSButton, button.title == title { return button }
            return view.subviews.lazy.compactMap { button(title, in: $0) }.first
        }
        if let sheet = window.attachedSheet, let field = sheet.firstResponder as? NSTextView {
            field.insertText("New n project", replacementRange: field.selectedRange())
            await settle()
            if let save = button("Save", in: sheet.contentView) { save.performClick(nil) }
            else { check(false, "project prompt provides Save") }
        } else { check(false, "project prompt focuses the name field") }
        await waitForHelp(false)
        check(model.projects.count == projectCount + 1 && model.selectedProject?.name == "New n project"
              && model.selectedProject?.categoryID == work && model.selectedProject?.parentID == nil
              && model.activePane == .projects, "saving the n prompt creates and selects a top-level project")
        check(try await store.load().projects.contains { $0.name == "New n project" && $0.categoryID == work },
              "the keyboard-created project is persisted")
        model.showingNewProjectPrompt = false
        await waitForHelp(false)
        window.focusActivePane()
        press("n"); await waitForHelp(true)
        if let cancel = button("Cancel", in: window.attachedSheet?.contentView) { cancel.performClick(nil) }
        else { check(false, "project prompt provides Cancel"); model.showingNewProjectPrompt = false }
        await waitForHelp(false)
        check(model.projects.count == projectCount + 1 && !model.showingNewProjectPrompt
              && (window.firstResponder as? NSView)?.identifier?.rawValue == "tasks.pane.projects",
              "cancelling the project prompt creates nothing and restores project focus")
        model.selectProject(root); await settle()
        press(code: 36); await settle()
        check(model.activePane == .tasks && (window.firstResponder as? NSView)?.identifier?.rawValue == "tasks.pane.tasks", "Return focuses the task list")
        press(code: 125); await settle()
        check(model.selectedTaskID == second, "Down selects the next task")
        press(code: 126); await settle()
        check(model.selectedTaskID == first, "Up selects the previous task")
        press(code: 124); await settle()
        check(model.activePane == .description && window.firstResponder === model.editor, "Right focuses the selected description (pane: \(model.activePane), responder: \(String(describing: window.firstResponder)), editor: \(String(describing: model.editor)))")
        check(model.editor?.layoutManager?.delegate === model.editor?.textGrid
              && model.editor?.enclosingScrollView?.rulersVisible == false, "the task description uses shared grid columns for line numbers")
        if let editor = model.editor, let cursor = editor.normalCursorRect {
            check(cursor.width > 5 && cursor.height > cursor.width && !editor.shouldDrawInsertionPoint,
                  "Normal uses a character-width block and disables AppKit's blinking caret")
            func renderedEditor() -> Data? {
                guard let bitmap = editor.bitmapImageRepForCachingDisplay(in: editor.bounds) else { return nil }
                editor.cacheDisplay(in: editor.bounds, to: bitmap)
                return bitmap.representation(using: .png, properties: [:])
            }
            let normal = renderedEditor()
            try? normal?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("pa3-task-normal-cursor.png"))
            try? await Task.sleep(for: .milliseconds(650))
            check(normal != nil && renderedEditor() == normal, "the rendered Normal cursor stays visible across a blink interval")
            editor.setMode(.dictation, notify: false)
            check(renderedEditor() != normal, "the block is present in the rendered Normal editor")
            editor.setMode(.normal, notify: false)
            editor.setSelectedRange(NSRange(location: 1, length: 0))
            check(editor.normalCursorRect?.minX != cursor.minX, "the block follows native cursor movement")
            editor.setSelectedRange(NSRange(location: 0, length: 0))
        } else { check(false, "focused Normal editor has a visible block cursor") }
        check(!window.handleTaskKey(event("\u{f702}", code: 123))
              && !window.handleTaskKey(event("\u{f703}", code: 124)), "Normal-mode arrows belong to the description editor")
        window.sendEvent(event("\u{f703}", code: 124))
        check(model.editor?.selectedRange().location == 1 && model.activePane == .description
              && window.firstResponder === model.editor, "Right moves the Normal cursor without changing panes")
        window.sendEvent(event("\u{f702}", code: 123))
        window.sendEvent(event("\u{f702}", code: 123))
        check(model.editor?.selectedRange().location == 0 && model.activePane == .description,
              "Left moves the Normal cursor and stays in the description even at its beginning")
        for pane in TaskPane.allCases {
            model.activatePane(pane); await settle()
            let selectedTask = model.selectedTaskID
            press("?", code: 44, flags: .shift); await waitForHelp(true)
            check(model.showingShortcutHelp && window.attachedSheet != nil, "? opens the shortcut reference from \(pane)")
            if pane == .tasks { press(code: 53) }
            else { press("?", code: 44, flags: .shift) }
            await waitForHelp(false)
            let focused = pane == .description ? window.firstResponder === model.editor
                : (window.firstResponder as? NSView)?.identifier?.rawValue == "tasks.pane.\(pane.rawValue)"
            check(!model.showingShortcutHelp && window.attachedSheet == nil && model.activePane == pane
                  && model.selectedTaskID == selectedTask && focused, "closing help restores the same pane and selection in \(pane)")
        }
        press("n", flags: .command); await settle()
        check(model.tasks.count == initialCount, "Command-N does nothing in description")
        check(!window.handleTaskKey(event("n")) && !model.showingNewProjectPrompt,
              "plain n in the description does not create a task or project")
        model.editor?.setMode(.insert)
        check(model.editor?.normalCursorRect == nil && model.editor?.shouldDrawInsertionPoint == true,
              "Insert restores the native insertion caret")
        check(!window.handleTaskKey(event(code: 124)), "Insert mode retains native Right-arrow editing")
        model.edit("Edited before escape")
        press(code: 53); await settle()
        check(model.activePane == .description && model.editorMode == .normal && model.editor?.mode == .normal
              && window.firstResponder === model.editor, "Escape from Insert returns to Normal without leaving the description")
        let beforeNormalTyping = model.draft
        window.sendEvent(event("z", code: 6)); await settle()
        check(model.draft == beforeNormalTyping, "ordinary typing does not insert text in Normal mode")
        press(code: 53); await settle()
        check(model.activePane == .tasks, "Escape from Normal returns to tasks")
        let saved = try await store.load()
        check(saved.tasks.first { $0.id == first }?.body == "Edited before escape", "Escape saves the current description")
        press(code: 123); await settle()
        check(model.activePane == .projects, "Left returns from tasks to projects")
        press(code: 124); await settle()

        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 150, height: 24))
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        check(!window.handleTaskKey(event("j")) && !window.handleTaskKey(event(code: 36))
              && !window.handleTaskKey(event("q")) && !window.handleTaskKey(event("n"))
              && !window.handleTaskKey(event("?", code: 44, flags: .shift)),
              "native search and prompt fields retain typing, n, Q, ? and Return")
        field.removeFromSuperview()
        window.focusActivePane()

        var publishedModes: [TaskEditorMode] = []
        let modeSubscription = model.$editorMode.sink { publishedModes.append($0) }
        defer { modeSubscription.cancel() }
        press("n"); await settle()
        check(model.tasks.count == initialCount + 1 && model.activePane == .description && model.editorMode == .insert
              && window.firstResponder === model.editor && model.editor?.mode == .insert, "n in tasks opens a new description in Insert mode (pane: \(model.activePane), mode: \(model.editorMode), responder: \(String(describing: window.firstResponder)), editor: \(String(describing: model.editor)))")
        if let insertion = publishedModes.firstIndex(of: .insert) {
            check(publishedModes[insertion...].allSatisfy { $0 == .insert }, "rendering a new task never publishes a spurious Normal indicator")
        } else { check(false, "new task publishes Insert mode") }
        window.sendEvent(event("q", code: 12))
        window.sendEvent(event("Q", code: 12, flags: .shift))
        await settle()
        check(window.isVisible && model.draft == "qQ" && model.editorMode == .insert && model.editor?.mode == .insert,
              "q and Q insert literal text without closing or changing the Insert indicator")
        window.sendEvent(event("?", code: 44, flags: .shift)); await settle()
        check(model.draft == "qQ?" && !model.showingShortcutHelp && model.editorMode == .insert,
              "? inserts literal punctuation in Insert mode")
        try await Task.sleep(for: .milliseconds(450))
        window.sendEvent(event("s", code: 1, flags: .command)); await settle()
        check(try await store.load().tasks.first { $0.id == model.selectedTaskID }?.body == "",
              "typing and Command-S leave the database unchanged in Insert mode")
        model.edit(""); await settle()
        press(code: 53); await settle()
        check(model.activePane == .description && model.editor?.normalCursorRect != nil,
              "an empty description also shows the Normal block after Escape (key: \(window.isKeyWindow), focused: \(window.firstResponder === model.editor), editable: \(model.editor?.isEditable == true), mode: \(model.editorMode))")
        window.sendEvent(event("i", code: 34))
        window.sendEvent(event("q", code: 12))
        window.sendEvent(event(" ", code: 49, flags: .control)); await settle()
        let beforeSpeech = try await store.load()
        check(model.editorMode == .dictation && beforeSpeech.tasks.first { $0.id == model.selectedTaskID }?.body == "",
              "Insert to Dictation does not commit the typed prefix")
        controller.handleTranscription(TranscriptionUpdate(text: "Dictated task.", language: "en"))
        check(!window.handleTaskKey(event("?", code: 44, flags: .shift)), "Dictation keeps PA3's shared ? handler")
        window.sendEvent(event("?", code: 44, flags: .shift)); await settle()
        check(controller.showingShortcuts && !model.showingShortcutHelp && model.editorMode == .dictation,
              "? opens the shared dictation reference without leaving Dictation")
        window.sendEvent(event("?", code: 44, flags: .shift)); await settle()
        check(!controller.showingShortcuts && model.editorMode == .dictation, "? closes dictation help without ending the session")
        try await Task.sleep(for: .milliseconds(450))
        check(try await store.load().tasks.first { $0.id == model.selectedTaskID }?.body == "",
              "live speech and typed text both remain uncommitted during Dictation")
        let dictatedDraft = model.draft
        press(code: 53); await settle()
        check(model.activePane == .description && model.editorMode == .normal && model.draft == dictatedDraft
              && window.firstResponder === model.editor, "Escape finishes dictation into the same task and returns to Normal")
        let dictatedEnd = (dictatedDraft as NSString).range(of: "Dictated task.").upperBound
        check(model.editor?.selectedRange() == NSRange(location: dictatedEnd, length: 0),
              "finishing and saving dictation keeps the cursor after inserted text (cursor: \(String(describing: model.editor?.selectedRange())), expected: \(dictatedEnd), body: \(dictatedDraft))")
        check(try await store.load().tasks.first { $0.id == model.selectedTaskID }?.body == dictatedDraft,
              "returning from Dictation to Normal saves the completed edit")

        for pane in TaskPane.allCases {
            model.activatePane(pane)
            await settle()
            check(window.handleTaskKey(event("Q", code: 12, flags: .shift)), "plain Q closes from \(pane)")
            await waitForClose()
            check(!window.isVisible && model.activePane == pane, "plain Q hides only the window and remembers \(pane)")
            manager.present(); await settle()
            let responderMatches = pane == .description ? window.firstResponder === model.editor
                : (window.firstResponder as? NSView)?.identifier?.rawValue == "tasks.pane.\(pane.rawValue)"
            check(model.activePane == pane && responderMatches && model.editorMode != .dictation, "reopening restores native focus in \(pane) without dictation")
        }
        model.beginDictation(); await settle()
        controller.handleTranscription(TranscriptionUpdate(text: "More speech.", language: "en"))
        press("q"); await waitForClose()
        let closedDictation = try await store.load()
        check(!window.isVisible && model.activePane == .description && model.editorMode == .normal
              && closedDictation.tasks.first { $0.id == model.selectedTaskID }?.body == model.draft
              && model.draft.contains("More speech."), "plain q drains and saves dictation without changing the remembered pane (visible: \(window.isVisible), pane: \(model.activePane), mode: \(model.editorMode), draft: \(model.draft), error: \(model.errorMessage))")
        manager.present(); await settle()
        model.collapsedCategories.insert(work)
        let restored = TaskManagerModel(dictation: DictationController(transcriber: TranscriberService(), preferences: preferences), databaseURL: url, preferences: preferences)
        await restored.open()
        check(restored.activePane == .description && restored.selectedTaskID == model.selectedTaskID
              && restored.collapsedCategories.contains(work), "pane, selection and collapsed categories survive a new model")
        let originalMenu = NSApp.mainMenu
        let probe = TaskQuitProbe()
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit", action: #selector(TaskQuitProbe.quit(_:)), keyEquivalent: "q")
        quitItem.target = probe
        applicationMenu.addItem(quitItem)
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        NSApp.mainMenu = menu
        NSApp.sendEvent(event("q", flags: .command))
        await waitForClose()
        NSApp.mainMenu = originalMenu
        check(!window.isVisible && !probe.invoked, "application event routing closes Tasks before the Quit menu can run (visible: \(window.isVisible), quit: \(probe.invoked), error: \(model.errorMessage))")
        manager.present(); await settle()
        NSApp.sendEvent(event("w", flags: .command)); await waitForClose()
        check(!window.isVisible, "Command-W also closes only the task window through application routing")
        manager.present(); await settle()
        window.sendEvent(event("i", code: 34))
        window.sendEvent(event("q", code: 12))
        let closingDraft = model.draft
        NSApp.sendEvent(event("w", flags: .command)); await waitForClose()
        check(try await store.load().tasks.first { $0.id == model.selectedTaskID }?.body == closingDraft,
              "closing from Insert finishes the edit and saves its draft")
        manager.present(); await settle()
        model.beginDictation(); await settle()
        controller.handleTranscription(TranscriptionUpdate(text: "Discard this speech.", language: "en"))
        model.discardDraftAndReload(); await settle()
        check(try await store.load().tasks.first { $0.id == model.selectedTaskID }?.body == closingDraft,
              "discarding a dictation draft never commits it on the way out")
        check(model.draft == closingDraft && model.editorMode == .normal, "discard reloads the saved description")
        let taskID = model.selectedTaskID!
        try await store.saveTask(taskID, body: "Changed elsewhere", expectedBody: model.draft)
        model.edit("Unsaved conflicting draft")
        press("q"); await waitForClose()
        check(window.isVisible && model.conflict && model.draft == "Unsaved conflicting draft", "a failed close keeps the window and conflicting draft open")
    } catch { failures.append("task navigation: \(error)") }
    return failures
}

@MainActor
private func runTaskModalEditorTests() -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ name: String) { if !condition { failures.append("task editor: " + name) } }
    let pasteboard = NSPasteboard.general
    let originalItems = (pasteboard.pasteboardItems ?? []).map { original in
        let item = NSPasteboardItem()
        for type in original.types { if let data = original.data(forType: type) { item.setData(data, forType: type) } }
        return item
    }
    defer { pasteboard.clearContents(); pasteboard.writeObjects(originalItems) }
    let editor = TaskModalTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    editor.isRichText = false
    editor.allowsUndo = true
    func press(_ value: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                    windowNumber: 0, context: nil, characters: value, charactersIgnoringModifiers: value,
                                    isARepeat: false, keyCode: code)!
        editor.keyDown(with: event)
    }
    editor.display(documentID: "one", body: "hello_world next\n#due:2026-11-15\n")
    func bold(at index: Int) -> Bool {
        guard let font = editor.textStorage?.attribute(.font, at: index, effectiveRange: nil) as? NSFont else { return false }
        return NSFontManager.shared.traits(of: font).contains(.boldFontMask)
    }
    check(bold(at: 0) && !bold(at: (editor.string as NSString).range(of: "#due").location),
          "only the first line renders in bold while the task remains plain text")
    editor.setSelectedRange(NSRange(location: 4, length: 0))
    press("d"); press("w")
    check(editor.string == "next\n#due:2026-11-15\n", "dw removes the whole word as in Veda")
    press("u")
    check(editor.string == "hello_world next\n#due:2026-11-15\n", "undo restores exact text")
    press("U")
    check(editor.string == "next\n#due:2026-11-15\n", "U redoes edit")
    editor.display(documentID: "two", body: "A 👨‍👩‍👧‍👦 B")
    editor.setSelectedRange(NSRange(location: 2, length: 0))
    press("x")
    check(editor.string == "A  B", "x deletes one composed Unicode character")
    press("u")
    check(editor.string == "A 👨‍👩‍👧‍👦 B", "Unicode deletion undo")
    let original = editor.string
    let dictated = original + " dictated text"
    editor.finishDictation(original: original, body: dictated, cursorLocation: (dictated as NSString).length)
    check(editor.selectedRange() == NSRange(location: (dictated as NSString).length, length: 0), "dictation leaves the cursor after inserted text")
    press("u")
    check(editor.string == original, "dictation is one undoable document edit")
    var requests = 0
    editor.onDictation = { requests += 1 }
    press(" ", code: 49)
    check(requests == 1, "Space in Normal mode requests dictation")
    press("i")
    check(editor.mode == .insert, "i enters Insert mode")
    press("", code: 53)
    check(editor.mode == .normal, "Escape returns to Normal mode")
    press(" ", code: 49, flags: .control)
    check(requests == 2, "Control-Space requests dictation")
    pasteboard.clearContents()
    pasteboard.setString("Pasted subject\n\n  Preserve spacing.\n#due:2026-11-15", forType: .string)
    press("i")
    press("a", flags: .command)
    press("v", flags: .command)
    press("", code: 53)
    check(editor.string == "Pasted subject\n\n  Preserve spacing.\n#due:2026-11-15", "Command-V pastes exact multiline text without an application menu")
    press("u")
    check(editor.string == original, "native clipboard paste participates in modal undo")
    let passage = "Title\nBefore HERE after\n#due:2026-11-15"
    let spoken = "שלום 👨‍👩‍👧‍👦"
    let replacement = TaskDictationInsertion(text: passage, selection: (passage as NSString).range(of: "HERE")).result(for: spoken)
    editor.display(documentID: "dictation-middle", body: passage)
    editor.isEditable = false // The window is busy while finishing dictation.
    editor.finishDictation(original: passage, body: replacement.body, cursorLocation: replacement.cursorLocation)
    check(editor.string == replacement.body && editor.selectedRange().location == (replacement.body as NSString).range(of: spoken).upperBound,
          "the cursor follows a Unicode replacement in the middle of the description")
    check(!editor.isEditable, "finishing dictation preserves the editor's busy state")
    editor.isEditable = true
    press("u")
    check(editor.string == passage && bold(at: 0) && !bold(at: (passage as NSString).range(of: "#due").location),
          "dictation undo restores exact plain text and derived subject styling")
    editor.display(documentID: "subject-style", body: "Subject")
    editor.setMode(.insert)
    editor.insertText("\nBody", replacementRange: NSRange(location: 7, length: 0))
    check(editor.string == "Subject\nBody" && bold(at: 0) && !bold(at: 8),
          "typing a newline stops bold subject formatting from leaking into the body")
    press("", code: 53); press("u")
    check(editor.string == "Subject" && bold(at: 0), "subject styling does not add a separate undo step")
    let lineDeletions: [(name: String, body: String, point: Int, count: Int, result: String, cursor: Int)] = [
        ("middle", "Title\nAbove\nDelete\nBelow", 14, 1, "Title\nAbove\nBelow", 6),
        ("last", "Title\nAbove\nDelete", 14, 1, "Title\nAbove", 6),
        ("first", "Delete\nBelow", 3, 1, "Below", 0),
        ("only", "Delete", 3, 1, "", 0),
        ("empty", "", 0, 1, "", 0),
        ("blank", "Title\nAbove\n\nBelow", 12, 1, "Title\nAbove\nBelow", 6),
        ("counted", "Title\nAbove\nDelete\nDelete too\nBelow", 14, 2, "Title\nAbove\nBelow", 6),
        ("Unicode CRLF", "Title\r\n👨‍👩‍👧‍👦\r\nDelete\r\nBelow", 24, 1, "Title\r\n👨‍👩‍👧‍👦\r\nBelow", 7)
    ]
    for test in lineDeletions {
        editor.display(documentID: "dd-" + test.name, body: test.body)
        editor.setSelectedRange(NSRange(location: test.point, length: 0))
        if test.count > 1 { press(String(test.count)) }
        press("d"); press("d")
        check(editor.string == test.result && editor.selectedRange() == NSRange(location: test.cursor, length: 0)
              && editor.mode == .normal, "dd moves to the previous line: " + test.name)
        press("u")
        check(editor.string == test.body, "dd remains one undoable edit: " + test.name)
    }
    return failures
}
