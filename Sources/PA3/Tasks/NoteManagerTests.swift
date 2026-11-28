import AppKit
import Foundation

@MainActor
func runNoteManagerTests() async -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ name: String) { if !condition { failures.append("notes: " + name) } }

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pa3-notes-\(UUID().uuidString)", isDirectory: true)
    let suite = "PA3NotesTests-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    defer {
        try? FileManager.default.removeItem(at: root)
        preferences.removePersistentDomain(forName: suite)
    }

    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Coexist cleanly with pa3.sqlite and hidden files in the shared PA3 folder.
        try Data("sqlite-placeholder".utf8).write(to: root.appendingPathComponent("pa3.sqlite"))
        try Data().write(to: root.appendingPathComponent(".DS_Store"))

        let store = NoteDirectoryStore(rootURL: root)
        let initial = try await store.open()
        check(initial.categories.map(\.name) == ["Personal", "Work"], "initial sections are Personal and Work")
        check(initial.projects.isEmpty && initial.tasks.isEmpty, "no invented projects or notes")

        // Verify timestamp filename matches PKB's YYYY-MM-DDTHH-MM-SS.md convention.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let sampleDate = utc.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 19, minute: 54, second: 5))!
        check(NoteDirectoryStore.timestampFilename(for: sampleDate, calendar: utc) == "2026-11-27T19-54-05.md",
              "note filename matches PKB timestamp convention")

        // Folder structure: section -> project -> subproject -> nested subproject.
        let onboarding = try await store.addProject(name: "Onboarding", categoryID: "Work", parentID: nil)
        let setup = try await store.addProject(name: "Setup", categoryID: "Work", parentID: onboarding)
        let laptop = try await store.addProject(name: "Laptop", categoryID: "Work", parentID: setup)
        check(onboarding == "Work/Onboarding" && setup == "Work/Onboarding/Setup" && laptop == "Work/Onboarding/Setup/Laptop",
              "projects map directly to nested directories")

        // Reject invalid folder names and cycles.
        do { _ = try await store.addProject(name: "bad/name", categoryID: "Work", parentID: nil); check(false, "reject slash in folder name") } catch {}
        do { _ = try await store.addProject(name: ".hidden", categoryID: "Work", parentID: nil); check(false, "reject hidden folder name") } catch {}
        do { _ = try await store.moveProject(onboarding, to: laptop, categoryID: "Work"); check(false, "reject moving project into descendant") } catch {}
        do { try await store.deleteEmptyProject(onboarding); check(false, "refuse deleting non-empty project") } catch {}

        // Create notes, verify .md files on disk, collision handling, exact UTF-8 round-trip.
        let body = "# Architecture Notes\n\n  Preserve  spacing\tand שלום 👨‍👩‍👧‍👦.\n#due:tomorrow #done\n"
        let note1 = try await store.addTask(projectID: setup, body: body)
        let note2 = try await store.addTask(projectID: setup, body: "Second note\nCreated in same second")
        check(note1.hasPrefix("Work/Onboarding/Setup/") && note1.hasSuffix(".md"), "note stored as .md inside project directory")
        check(note1 != note2 && note2.hasSuffix(".md"), "rapid note creation avoids filename collision")
        let diskText = try String(contentsOf: root.appendingPathComponent(note1), encoding: .utf8)
        check(diskText == body, "note file on disk preserves exact UTF-8 bytes")

        // Optimistic conflict detection on external file edits.
        try await store.saveTask(note1, body: body + "Edit A", expectedBody: body)
        do {
            try await store.saveTask(note1, body: body + "Edit B", expectedBody: body)
            check(false, "stale save reports conflict")
        } catch TaskStoreError.conflict {} catch { check(false, "stale save throws TaskStoreError.conflict") }
        do {
            try await store.deleteTask(note1, expectedBody: body)
            check(false, "stale delete reports conflict")
        } catch TaskStoreError.conflict {} catch { check(false, "stale delete throws TaskStoreError.conflict") }

        // Move note across nested projects and move project subtree across sections.
        let movedNote = try await store.moveTask(note1, projectID: laptop)
        check(movedNote.hasPrefix("Work/Onboarding/Setup/Laptop/"), "moving note relocates markdown file")
        let movedProject = try await store.moveProject(onboarding, to: nil, categoryID: "Personal")
        check(movedProject == "Personal/Onboarding", "moving project moves subtree to another section")
        let afterMove = try await store.load()
        check(afterMove.projects.contains { $0.id == "Personal/Onboarding/Setup/Laptop" && $0.categoryID == "Personal" },
              "moved project subtree updates section and ancestry")
        check(afterMove.tasks.contains { $0.projectID == "Personal/Onboarding/Setup/Laptop" && $0.body == body + "Edit A" },
              "notes travel with their moved project folder")

        // Empty project deletion succeeds once empty.
        let emptyProject = try await store.addProject(name: "Temp", categoryID: "Work", parentID: nil)
        try await store.deleteEmptyProject(emptyProject)
        check(!(try await store.load().projects.contains { $0.id == emptyProject }), "empty project folder can be deleted")

        // Full model + window integration for .notes workspace.
        let controller = DictationController(transcriber: TranscriberService(), preferences: preferences)
        controller.prepareModels = { false }
        let model = TaskManagerModel(kind: .notes, dictation: controller, databaseURL: root, preferences: preferences)
        await model.open()
        check(model.loaded && model.kind == .notes, "notes model opens directory store")
        check(model.categories.map(\.name) == ["Personal", "Work"], "notes model loads sections")
        // Notes containing #done must remain visible (no task-completion filtering in notes).
        model.selectProject("Personal/Onboarding/Setup/Laptop")
        check(model.visibleTasks.count == 1 && model.selectedTask?.body == body + "Edit A",
              "notes with #done stay visible in note list")

        // Notes editor does NOT rewrite #due:tomorrow on leaving Insert mode.
        let manager = TaskManagerWindow(model: model)
        guard let window = manager.window as? TaskNavigationWindow else { return failures + ["notes: missing window"] }
        defer { window.orderOut(nil); model.stopMonitoring() }
        check(window.title == "PA3 Notes", "notes window uses PA3 Notes title")
        manager.present()
        window.contentView?.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(80))
        model.activatePane(.description)
        model.editor?.setMode(.insert)
        model.editor?.insertText("\nKeep #due:tomorrow literal", replacementRange: NSRange(location: (model.draft as NSString).length, length: 0))
        model.escapeDescription()
        _ = await model.flush()
        check(model.draft.contains("#due:tomorrow"), "notes preserve #due:tomorrow literally without date expansion")

        // Pressing q in Dictation mode discards dictated text without closing the Notes window.
        let noteBeforeDictation = model.draft
        model.beginDictation()
        for _ in 0..<200 where model.busy { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(60))
        controller.handleTranscription(TranscriptionUpdate(text: "Dictated note text.", language: "en"))
        check(model.draft.contains("Dictated note text."), "notes dictation previews live speech before discard")
        let qEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: "q",
                                      charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12)!
        check(!window.handleTaskKey(qEvent), "q passes through to Dictation in notes")
        window.sendEvent(qEvent)
        for _ in 0..<200 where model.editorMode == .dictation || model.busy || model.dirty { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(60))
        let persistedNote = try await store.load().tasks.first { $0.id == model.selectedTaskID }?.body
        check(window.isVisible && model.editorMode == .normal && model.activePane == .description
              && model.draft == noteBeforeDictation && persistedNote == noteBeforeDictation
              && !model.draft.contains("Dictated note text."),
              "q in notes Dictation discards dictated text and returns to Normal without closing the window")

        // Fuzzy search (/) works in notes pane with zero extra disk loads.
        model.activatePane(.tasks)
        let loadsBefore = await model.databaseLoadCount()
        check(window.handleTaskKey(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, characters: "/",
                                                    charactersIgnoringModifiers: "/", isARepeat: false, keyCode: 44)!),
              "/ opens fuzzy search in notes pane")
        model.updateSearch("architecture")
        let loadsAfter = await model.databaseLoadCount()
        check(model.visibleTasks.count == 1 && loadsAfter == loadsBefore,
              "fuzzy search filters notes in memory with zero disk reloads")
        model.cancelTaskSearch()

        // Renaming a section remaps selected project & note paths seamlessly.
        model.renameCategory("Personal", name: "Private")
        for _ in 0..<200 where model.busy { try? await Task.sleep(for: .milliseconds(10)) }
        check(model.selectedProjectID == "Private/Onboarding/Setup/Laptop"
              && model.selectedTaskID?.hasPrefix("Private/Onboarding/Setup/Laptop/") == true,
              "renaming a section preserves selection across updated directory paths")

        // Preferences namespace is separate from tasks.*
        check(preferences.string(forKey: "notes.selectedProject") == "Private/Onboarding/Setup/Laptop"
              && preferences.string(forKey: "tasks.selectedProject") == nil,
              "notes preferences do not collide with tasks preferences")

        // Reopening with custom sections never re-creates deleted/renamed default sections.
        let reopened = try await store.open()
        check(reopened.categories.map(\.name) == ["Private", "Work"],
              "reopening does not re-create renamed default sections")

        // iCloud placeholder for a note file reports downloading instead of silently ignoring/overwriting.
        let placeholderDir = root.appendingPathComponent("Private/Onboarding", isDirectory: true)
        try Data().write(to: placeholderDir.appendingPathComponent(".2026-11-27T00-00-00.md.icloud"))
        do {
            _ = try await store.load()
            check(false, "iCloud note placeholder triggers downloading error")
        } catch TaskStoreError.downloading {} catch { check(false, "iCloud placeholder throws TaskStoreError.downloading") }

        // Missing iCloud Drive error check.
        let missingHome = root.appendingPathComponent("no-icloud-home")
        do { _ = try NoteDirectoryLocation.resolve(environment: [:], home: missingHome); check(false, "missing iCloud Drive is reported for notes") } catch {}
    } catch {
        failures.append("notes: unexpected error: \(error)")
    }
    return failures
}
