import Foundation

enum NoteDirectoryLocation {
    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        if let override = environment["PA3_NOTES_DIRECTORY"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        // Notes share the iCloud Drive/PA3 folder alongside pa3.sqlite,
        // organized directly as Section/Project/Subproject/<timestamp>.md.
        let drive = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: drive.path) else {
            throw TaskStoreError.message("iCloud Drive is unavailable. Enable iCloud Drive in System Settings, then retry.")
        }
        return drive.appendingPathComponent("PA3", isDirectory: true)
    }
}

/// Filesystem-backed note store with no database. Top-level directories are
/// sections, nested subdirectories are projects/subprojects, and `.md` files
/// inside projects are notes named with PKB's `YYYY-MM-DDTHH-MM-SS.md` format.
actor NoteDirectoryStore: TaskWorkspaceStore {
    let rootURL: URL
    nonisolated var locationURL: URL { rootURL }
    private(set) var loadCount = 0

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    func open() throws -> TaskSnapshot {
        try TaskDatabaseLocation.requireDownloaded(rootURL)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let existingSections = try visibleSubdirectories(in: rootURL)
        if existingSections.isEmpty {
            for name in ["Personal", "Work"] {
                try createDirectoryCoordinated(at: rootURL.appendingPathComponent(name, isDirectory: true))
            }
        }
        return try snapshot()
    }

    func load() throws -> TaskSnapshot {
        loadCount += 1
        return try snapshot()
    }

    func status(selectedItemID: String?) -> String {
        if let selectedItemID, !selectedItemID.isEmpty {
            let fileURL = url(for: selectedItemID)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                return uploadStatus(fileURL)
            }
        }
        return uploadStatus(rootURL)
    }

    func revealURL(selectedItemID: String?, selectedProjectID: String?) -> URL {
        if let selectedItemID, !selectedItemID.isEmpty {
            let fileURL = url(for: selectedItemID)
            if FileManager.default.fileExists(atPath: fileURL.path) { return fileURL }
        }
        if let selectedProjectID, !selectedProjectID.isEmpty {
            let dirURL = url(for: selectedProjectID, isDirectory: true)
            if FileManager.default.fileExists(atPath: dirURL.path) { return dirURL }
        }
        return rootURL
    }

    func addCategory(name: String) throws -> String {
        let valid = try Self.validFolderName(name)
        try ensureSiblingAvailable(valid, in: rootURL)
        let destination = rootURL.appendingPathComponent(valid, isDirectory: true)
        try createDirectoryCoordinated(at: destination)
        return valid
    }

    func renameCategory(_ id: String, name: String) throws -> String {
        let valid = try Self.validFolderName(name)
        let source = url(for: id, isDirectory: true)
        guard directoryExists(at: source) else { throw TaskStoreError.message("The section no longer exists.") }
        if valid == id { return id }
        try ensureSiblingAvailable(valid, in: rootURL, ignoring: id)
        let destination = rootURL.appendingPathComponent(valid, isDirectory: true)
        try moveCoordinated(from: source, to: destination)
        return valid
    }

    func addProject(name: String, categoryID: String, parentID: String?) throws -> String {
        let valid = try Self.validFolderName(name)
        let parentPath = parentID ?? categoryID
        let parentURL = url(for: parentPath, isDirectory: true)
        guard directoryExists(at: parentURL) else { throw TaskStoreError.message("The parent folder no longer exists.") }
        if let parentID {
            guard Self.sectionName(of: parentID) == categoryID else {
                throw TaskStoreError.message("A subproject must have the same section as its parent.")
            }
        }
        try ensureSiblingAvailable(valid, in: parentURL)
        let destination = parentURL.appendingPathComponent(valid, isDirectory: true)
        try createDirectoryCoordinated(at: destination)
        return "\(parentPath)/\(valid)"
    }

    func renameProject(_ id: String, name: String) throws -> String {
        let valid = try Self.validFolderName(name)
        let source = url(for: id, isDirectory: true)
        guard directoryExists(at: source) else { throw TaskStoreError.message("The project no longer exists.") }
        let parentURL = source.deletingLastPathComponent()
        let currentName = source.lastPathComponent
        if valid == currentName { return id }
        try ensureSiblingAvailable(valid, in: parentURL, ignoring: currentName)
        let destination = parentURL.appendingPathComponent(valid, isDirectory: true)
        try moveCoordinated(from: source, to: destination)
        return relativePath(of: destination)
    }

    func moveProject(_ id: String, to parentID: String?, categoryID: String) throws -> String {
        let source = url(for: id, isDirectory: true)
        guard directoryExists(at: source) else { throw TaskStoreError.message("The project no longer exists.") }
        let targetParentPath = parentID ?? categoryID
        if targetParentPath == id || targetParentPath.hasPrefix(id + "/") {
            throw TaskStoreError.message("A project cannot be moved into itself or one of its subprojects.")
        }
        let targetParentURL = url(for: targetParentPath, isDirectory: true)
        guard directoryExists(at: targetParentURL) else {
            throw TaskStoreError.message("The destination folder no longer exists. Reload and try again.")
        }
        let folderName = source.lastPathComponent
        let destination = targetParentURL.appendingPathComponent(folderName, isDirectory: true)
        let newID = relativePath(of: destination)
        if newID == id { return id }
        try ensureSiblingAvailable(folderName, in: targetParentURL)
        try moveCoordinated(from: source, to: destination)
        return newID
    }

    func deleteEmptyProject(_ id: String) throws {
        let target = url(for: id, isDirectory: true)
        guard directoryExists(at: target) else { return }
        let subdirs = try visibleSubdirectories(in: target)
        let notes = try noteEntries(in: target)
        guard subdirs.isEmpty && notes.isEmpty else {
            throw TaskStoreError.message("Move or delete this project's notes and subprojects first.")
        }
        try removeCoordinated(at: target)
    }

    func addTask(projectID: String, body: String = "") throws -> String {
        let projectURL = url(for: projectID, isDirectory: true)
        guard directoryExists(at: projectURL) else { throw TaskStoreError.message("The project no longer exists.") }
        let filename = nextTimestampFilename(in: projectURL, date: Date())
        let destination = projectURL.appendingPathComponent(filename, isDirectory: false)
        try writeCoordinated(body, to: destination)
        return "\(projectID)/\(filename)"
    }

    func saveTask(_ id: String, body: String, expectedBody: String) throws {
        let fileURL = url(for: id)
        try TaskDatabaseLocation.requireDownloaded(fileURL)
        try coordinateWrite(at: fileURL) { coordinatedURL in
            guard FileManager.default.fileExists(atPath: coordinatedURL.path) else { throw TaskStoreError.conflict }
            let current = try String(contentsOf: coordinatedURL, encoding: .utf8)
            guard current == expectedBody else { throw TaskStoreError.conflict }
            try body.write(to: coordinatedURL, atomically: true, encoding: .utf8)
        }
    }

    func moveTask(_ id: String, projectID: String) throws -> String {
        let source = url(for: id)
        try TaskDatabaseLocation.requireDownloaded(source)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw TaskStoreError.message("The note no longer exists.")
        }
        let targetDir = url(for: projectID, isDirectory: true)
        guard directoryExists(at: targetDir) else { throw TaskStoreError.message("The destination project no longer exists.") }
        let currentParent = relativePath(of: source.deletingLastPathComponent())
        if currentParent == projectID { return id }
        let filename = uniqueFilename(preferred: source.lastPathComponent, in: targetDir)
        let destination = targetDir.appendingPathComponent(filename, isDirectory: false)
        try moveCoordinated(from: source, to: destination)
        return "\(projectID)/\(filename)"
    }

    func deleteTask(_ id: String, expectedBody: String) throws {
        let fileURL = url(for: id)
        try TaskDatabaseLocation.requireDownloaded(fileURL)
        try coordinateWrite(at: fileURL, options: .forDeleting) { coordinatedURL in
            guard FileManager.default.fileExists(atPath: coordinatedURL.path) else { throw TaskStoreError.conflict }
            let current = try String(contentsOf: coordinatedURL, encoding: .utf8)
            guard current == expectedBody else { throw TaskStoreError.conflict }
            try FileManager.default.removeItem(at: coordinatedURL)
        }
    }

    // MARK: - Timestamp naming (matches PKB's `YYYY-MM-DDTHH-MM-SS.md`)

    static func timestampFilename(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02dT%02d-%02d-%02d.md",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    private func nextTimestampFilename(in directory: URL, date: Date) -> String {
        uniqueFilename(preferred: Self.timestampFilename(for: date), in: directory)
    }

    private func uniqueFilename(preferred: String, in directory: URL) -> String {
        let ext = (preferred as NSString).pathExtension
        let stem = (preferred as NSString).deletingPathExtension
        var candidate = preferred
        var counter = 1
        while fileOrPlaceholderExists(named: candidate, in: directory) {
            candidate = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
            counter += 1
        }
        return candidate
    }

    private func fileOrPlaceholderExists(named filename: String, in directory: URL) -> Bool {
        let direct = directory.appendingPathComponent(filename).path
        let placeholder = directory.appendingPathComponent(".\(filename).icloud").path
        return FileManager.default.fileExists(atPath: direct) || FileManager.default.fileExists(atPath: placeholder)
    }

    // MARK: - Snapshot & Directory Scanning

    private func snapshot() throws -> TaskSnapshot {
        try TaskDatabaseLocation.requireDownloaded(rootURL)
        guard directoryExists(at: rootURL) else {
            throw TaskStoreError.message("The notes folder is unavailable.")
        }
        let sectionURLs = try visibleSubdirectories(in: rootURL)
        var categories: [TaskCategory] = []
        var projects: [TaskProject] = []
        var notes: [PersonalTask] = []

        for sectionURL in sectionURLs {
            let sectionName = sectionURL.lastPathComponent
            categories.append(TaskCategory(id: sectionName, name: sectionName))
            let topProjects = try visibleSubdirectories(in: sectionURL)
            for projectURL in topProjects {
                try collectProjectTree(at: projectURL, categoryID: sectionName, parentID: nil,
                                       projects: &projects, notes: &notes)
            }
        }
        return TaskSnapshot(categories: categories, projects: projects, tasks: notes)
    }

    private func collectProjectTree(at directoryURL: URL, categoryID: String, parentID: String?,
                                    projects: inout [TaskProject], notes: inout [PersonalTask]) throws {
        let projectID = relativePath(of: directoryURL)
        projects.append(TaskProject(id: projectID, parentID: parentID, categoryID: categoryID, name: directoryURL.lastPathComponent))

        let entries = try noteEntries(in: directoryURL)
        for fileURL in entries {
            let noteID = relativePath(of: fileURL)
            let body = try readCoordinated(from: fileURL)
            notes.append(PersonalTask(id: noteID, projectID: projectID, body: body))
        }

        let subprojects = try visibleSubdirectories(in: directoryURL)
        for childURL in subprojects {
            try collectProjectTree(at: childURL, categoryID: categoryID, parentID: projectID,
                                   projects: &projects, notes: &notes)
        }
    }

    private func visibleSubdirectories(in directory: URL) throws -> [URL] {
        let items = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        return items.filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func noteEntries(in directory: URL) throws -> [URL] {
        let items = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: []
        )
        var files: [URL] = []
        for item in items {
            let name = item.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".md.icloud") {
                let realName = String(name.dropFirst().dropLast(".icloud".count))
                let realURL = directory.appendingPathComponent(realName)
                try? FileManager.default.startDownloadingUbiquitousItem(at: realURL)
                throw TaskStoreError.downloading
            }
            guard !name.hasPrefix("."), item.pathExtension.lowercased() == "md" else { continue }
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory != true else { continue }
            files.append(item)
        }
        // Sort newest timestamp first (reverse chronological for YYYY-MM-DDTHH-MM-SS.md).
        return files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
    }

    // MARK: - Path & Validation Helpers

    private static func validFolderName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TaskStoreError.message("Enter a name.") }
        guard trimmed != ".", trimmed != "..", !trimmed.hasPrefix("."),
              !trimmed.contains("/"), !trimmed.contains(":") else {
            throw TaskStoreError.message("Folder names cannot start with '.' or contain '/' or ':'.")
        }
        return trimmed
    }

    private static func sectionName(of relativePath: String) -> String {
        String(relativePath.split(separator: "/", maxSplits: 1).first ?? "")
    }

    private func url(for relativeID: String, isDirectory: Bool = false) -> URL {
        var current = rootURL
        let components = relativeID.split(separator: "/").map(String.init)
        for (index, part) in components.enumerated() {
            current.appendPathComponent(part, isDirectory: isDirectory || index < components.count - 1)
        }
        return current
    }

    private func relativePath(of target: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if targetPath.hasPrefix(prefix) { return String(targetPath.dropFirst(prefix.count)) }
        return target.lastPathComponent
    }

    private func directoryExists(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func ensureSiblingAvailable(_ name: String, in parent: URL, ignoring currentName: String? = nil) throws {
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        let lowered = name.lowercased()
        let ignoredLowered = currentName?.lowercased()
        if existing.contains(where: { item in
            let itemLowered = item.lowercased()
            if let ignoredLowered, itemLowered == ignoredLowered { return false }
            return itemLowered == lowered
        }) {
            throw TaskStoreError.message("An item named \"\(name)\" already exists here.")
        }
    }

    private func uploadStatus(_ location: URL) -> String {
        let raw = TaskDatabaseLocation.uploadStatus(location)
        return raw.replacingOccurrences(of: "custom database location", with: "custom notes folder")
    }

    // MARK: - NSFileCoordinator wrappers

    private func readCoordinated(from fileURL: URL) throws -> String {
        try TaskDatabaseLocation.requireDownloaded(fileURL)
        var coordinationError: NSError?
        var result: Result<String, Error>?
        NSFileCoordinator().coordinate(readingItemAt: fileURL, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try String(contentsOf: coordinatedURL, encoding: .utf8) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw TaskStoreError.message("Could not read \(fileURL.lastPathComponent).") }
        return try result.get()
    }

    private func writeCoordinated(_ body: String, to fileURL: URL) throws {
        try coordinateWrite(at: fileURL) { coordinatedURL in
            try body.write(to: coordinatedURL, atomically: true, encoding: .utf8)
        }
    }

    private func coordinateWrite(at fileURL: URL, options: NSFileCoordinator.WritingOptions = [],
                                 _ operation: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: options, error: &coordinationError) { coordinatedURL in
            result = Result { try operation(coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw TaskStoreError.message("Could not write \(fileURL.lastPathComponent).") }
        try result.get()
    }

    private func createDirectoryCoordinated(at url: URL) throws {
        try coordinateWrite(at: url) { coordinatedURL in
            try FileManager.default.createDirectory(at: coordinatedURL, withIntermediateDirectories: false)
        }
    }

    private func removeCoordinated(at url: URL) throws {
        try coordinateWrite(at: url, options: .forDeleting) { coordinatedURL in
            try FileManager.default.removeItem(at: coordinatedURL)
        }
    }

    private func moveCoordinated(from source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: source, options: .forMoving,
                               writingItemAt: destination, options: .forReplacing,
                               error: &coordinationError) { src, dst in
            result = Result {
                coordinator.item(at: src, willMoveTo: dst)
                try FileManager.default.moveItem(at: src, to: dst)
                coordinator.item(at: src, didMoveTo: dst)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw TaskStoreError.message("Could not move \(source.lastPathComponent).") }
        try result.get()
    }
}
