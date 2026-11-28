import CSQLite
import Foundation

enum WorkspaceKind: String, Sendable {
    case tasks
    case notes

    var windowTitle: String { self == .tasks ? "PA3 Tasks" : "PA3 Notes" }
    var frameAutosaveName: String { self == .tasks ? "PA3Tasks" : "PA3Notes" }
    var preferencesPrefix: String { rawValue }
    var headerTitle: String { self == .tasks ? "Tasks" : "Notes" }
    var headerIcon: String { self == .tasks ? "checklist" : "doc.text" }
    var itemSingular: String { self == .tasks ? "task" : "note" }
    var itemPlural: String { self == .tasks ? "tasks" : "notes" }
    var newItemButtonTitle: String { self == .tasks ? "New task" : "New note" }
    var sectionSingular: String { self == .tasks ? "category" : "section" }
    var sectionPlural: String { self == .tasks ? "categories" : "sections" }
    var newSectionTitle: String { self == .tasks ? "New category" : "New section" }
    var renameSectionTitle: String { self == .tasks ? "Rename category" : "Rename section" }
    var untitledTitle: String { self == .tasks ? "Untitled task" : "Untitled note" }
    var editorHeading: String { self == .tasks ? "Description" : "Note" }
    var showStorageButtonTitle: String { self == .tasks ? "Show database" : "Show in Finder" }
    var supportsTaskMetadata: Bool { self == .tasks }
    var conflictMessage: String {
        self == .tasks
            ? "This task changed outside this window. Your draft has been kept. Reload or save it as a separate task."
            : "This note changed outside this window. Your draft has been kept. Reload or save it as a separate note."
    }
}

protocol TaskWorkspaceStore: Sendable {
    var locationURL: URL { get }
    var loadCount: Int { get async }
    func open() async throws -> TaskSnapshot
    func load() async throws -> TaskSnapshot
    func status(selectedItemID: String?) async -> String
    func revealURL(selectedItemID: String?, selectedProjectID: String?) async -> URL
    func addCategory(name: String) async throws -> String
    func renameCategory(_ id: String, name: String) async throws -> String
    func addProject(name: String, categoryID: String, parentID: String?) async throws -> String
    func renameProject(_ id: String, name: String) async throws -> String
    func moveProject(_ id: String, to parentID: String?, categoryID: String) async throws -> String
    func deleteEmptyProject(_ id: String) async throws
    func addTask(projectID: String, body: String) async throws -> String
    func saveTask(_ id: String, body: String, expectedBody: String) async throws
    func moveTask(_ id: String, projectID: String) async throws -> String
    func deleteTask(_ id: String, expectedBody: String) async throws
}

enum TaskStoreError: LocalizedError {
    case message(String)
    case downloading
    case conflict

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .downloading: return "Downloading the task database from iCloud…"
        case .conflict: return "This task changed outside this window. Your draft has been kept. Reload or save it as a separate task."
        }
    }
}

enum TaskDatabaseLocation {
    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        if let override = environment["PA3_TASK_DATABASE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        // PA3 is a locally signed, non-sandboxed Mac app. Use the user's visible
        // iCloud Drive folder rather than an entitlement-only app container.
        let drive = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: drive.path) else {
            throw TaskStoreError.message("iCloud Drive is unavailable. Enable iCloud Drive in System Settings, then retry.")
        }
        return drive.appendingPathComponent("PA3", isDirectory: true).appendingPathComponent("pa3.sqlite")
    }

    static func requireDownloaded(_ location: URL) throws {
        var url = location
        url.removeAllCachedResourceValues()
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if FileManager.default.fileExists(atPath: placeholder.path)
            || (values?.isUbiquitousItem == true && values?.ubiquitousItemDownloadingStatus == .notDownloaded) {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw TaskStoreError.downloading
        }
    }

    static func uploadStatus(_ location: URL) -> String {
        var url = location
        // Foundation caches these values on URL objects. iCloud errors and
        // uploading flags must be fetched again on each status poll.
        url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey,
                                                           .ubiquitousItemIsUploadingKey, .ubiquitousItemUploadingErrorKey]) else {
            return "Saved locally · iCloud status unavailable"
        }
        if let error = values.ubiquitousItemUploadingError { return "Saved locally · iCloud: \(error.localizedDescription)" }
        guard values.isUbiquitousItem == true else {
            return url.path.contains("/com~apple~CloudDocs/") ? "Saved locally · waiting for iCloud status" : "Saved locally · custom database location"
        }
        if values.ubiquitousItemIsUploading == true { return "Saved locally · uploading to iCloud…" }
        return values.ubiquitousItemIsUploaded == true ? "Saved locally · uploaded to iCloud" : "Saved locally · waiting for iCloud upload"
    }
}

/// All SQLite work runs off the UI actor. Connections are closed before file
/// coordination ends, so iCloud never replaces a file with an open connection.
actor TaskStore: TaskWorkspaceStore {
    let url: URL
    nonisolated var locationURL: URL { url }
    private let backups: URL?
    private(set) var loadCount = 0

    init(url: URL, backups: URL? = nil) {
        self.url = url
        self.backups = backups
    }

    func open() throws -> TaskSnapshot {
        try TaskDatabaseLocation.requireDownloaded(url.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try access(writing: true, create: true) { db in
            let version = Int(try db.scalar("PRAGMA user_version") ?? "0") ?? 0
            guard version <= 1 else { throw TaskStoreError.message("This database needs a newer version of PA3.") }
            if version == 0 {
                try db.transaction {
                    try db.execute("CREATE TABLE categories (id TEXT PRIMARY KEY, name TEXT NOT NULL COLLATE NOCASE UNIQUE, position INTEGER NOT NULL)")
                    try db.execute("CREATE TABLE projects (id TEXT PRIMARY KEY, parent_id TEXT REFERENCES projects(id) ON DELETE RESTRICT, category_id TEXT NOT NULL REFERENCES categories(id) ON DELETE RESTRICT, name TEXT NOT NULL, position INTEGER NOT NULL)")
                    try db.execute("CREATE TABLE tasks (id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE RESTRICT, description TEXT NOT NULL, position INTEGER NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)")
                    try db.execute("CREATE INDEX projects_parent ON projects(parent_id)")
                    try db.execute("CREATE INDEX tasks_project ON tasks(project_id)")
                    try db.execute("INSERT INTO categories VALUES (?, 'Home', 0)", [UUID().uuidString])
                    try db.execute("INSERT INTO categories VALUES (?, 'Work', 1)", [UUID().uuidString])
                    try db.execute("PRAGMA user_version = 1")
                }
            }
            return try Self.snapshot(db)
        }
    }

    func load() throws -> TaskSnapshot {
        loadCount += 1
        return try access { try Self.snapshot($0) }
    }
    func status() -> String { TaskDatabaseLocation.uploadStatus(url) }
    func status(selectedItemID: String?) -> String { status() }
    func revealURL(selectedItemID: String?, selectedProjectID: String?) -> URL { url }

    func addCategory(name: String) throws -> String {
        let name = try Self.validName(name)
        return try mutate { db in
            let id = UUID().uuidString
            try db.execute("INSERT INTO categories VALUES (?, ?, (SELECT COALESCE(MAX(position), -1) + 1 FROM categories))", [id, name])
            return id
        }
    }

    @discardableResult
    func renameCategory(_ id: String, name: String) throws -> String {
        let name = try Self.validName(name)
        try mutate { try $0.execute("UPDATE categories SET name = ? WHERE id = ?", [name, id]) }
        return id
    }

    func addProject(name: String, categoryID: String, parentID: String?) throws -> String {
        let name = try Self.validName(name)
        return try mutate { db in
            if let parentID {
                guard try db.scalar("SELECT category_id FROM projects WHERE id = ?", [parentID]) == categoryID else {
                    throw TaskStoreError.message("A subproject must have the same category as its parent.")
                }
            }
            let id = UUID().uuidString
            try db.execute("INSERT INTO projects VALUES (?, ?, ?, ?, (SELECT COALESCE(MAX(position), -1) + 1 FROM projects))", [id, parentID, categoryID, name])
            return id
        }
    }

    @discardableResult
    func renameProject(_ id: String, name: String) throws -> String {
        let name = try Self.validName(name)
        try mutate { try $0.execute("UPDATE projects SET name = ? WHERE id = ?", [name, id]) }
        return id
    }

    @discardableResult
    func moveProject(_ id: String, to parentID: String?, categoryID: String) throws -> String {
        try mutate { db in
            let descendants = try db.rows("WITH RECURSIVE tree(id) AS (SELECT id FROM projects WHERE id = ? UNION ALL SELECT p.id FROM projects p JOIN tree t ON p.parent_id = t.id) SELECT id FROM tree", [id]).compactMap { $0["id"] }
            guard !descendants.isEmpty else { throw TaskStoreError.message("The project no longer exists.") }
            if let parentID {
                guard !descendants.contains(parentID) else { throw TaskStoreError.message("A project cannot be moved into itself or one of its subprojects.") }
                guard try db.scalar("SELECT category_id FROM projects WHERE id = ?", [parentID]) == categoryID else {
                    throw TaskStoreError.message("The destination category changed. Reload and try again.")
                }
            }
            try db.execute("UPDATE projects SET parent_id = ? WHERE id = ?", [parentID, id])
            for descendant in descendants { try db.execute("UPDATE projects SET category_id = ? WHERE id = ?", [categoryID, descendant]) }
        }
        return id
    }

    func deleteEmptyProject(_ id: String) throws {
        try mutate { db in
            guard try db.scalar("SELECT COUNT(*) FROM tasks WHERE project_id = ?", [id]) == "0",
                  try db.scalar("SELECT COUNT(*) FROM projects WHERE parent_id = ?", [id]) == "0" else {
                throw TaskStoreError.message("Move or delete this project's tasks and subprojects first.")
            }
            try db.execute("DELETE FROM projects WHERE id = ?", [id])
        }
    }

    func addTask(projectID: String, body: String = "") throws -> String {
        try mutate { db in
            let id = UUID().uuidString
            let now = ISO8601DateFormatter().string(from: Date())
            try db.execute("INSERT INTO tasks VALUES (?, ?, ?, (SELECT COALESCE(MAX(position), -1) + 1 FROM tasks), ?, ?)", [id, projectID, body, now, now])
            return id
        }
    }

    func saveTask(_ id: String, body: String, expectedBody: String) throws {
        try mutate { db in
            try db.execute("UPDATE tasks SET description = ?, updated_at = ? WHERE id = ? AND description = ?", [body, ISO8601DateFormatter().string(from: Date()), id, expectedBody])
            guard db.changedRows == 1 else { throw TaskStoreError.conflict }
        }
    }

    @discardableResult
    func moveTask(_ id: String, projectID: String) throws -> String {
        try mutate { try $0.execute("UPDATE tasks SET project_id = ? WHERE id = ?", [projectID, id]) }
        return id
    }

    func deleteTask(_ id: String, expectedBody: String) throws {
        try mutate { db in
            try db.execute("DELETE FROM tasks WHERE id = ? AND description = ?", [id, expectedBody])
            guard db.changedRows == 1 else { throw TaskStoreError.conflict }
        }
    }

    private static func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TaskStoreError.message("Enter a name.") }
        return trimmed
    }

    private static func snapshot(_ db: TaskSQL) throws -> TaskSnapshot {
        TaskSnapshot(
            categories: try db.rows("SELECT * FROM categories ORDER BY position, id").map { TaskCategory(id: $0["id"]!, name: $0["name"]!) },
            projects: try db.rows("SELECT * FROM projects ORDER BY position, id").map { TaskProject(id: $0["id"]!, parentID: $0["parent_id"], categoryID: $0["category_id"]!, name: $0["name"]!) },
            tasks: try db.rows("SELECT * FROM tasks ORDER BY position, id").map { PersonalTask(id: $0["id"]!, projectID: $0["project_id"]!, body: $0["description"]!) })
    }

    private func mutate<T>(_ action: (TaskSQL) throws -> T) throws -> T {
        try access(writing: true) { db in
            try backupIfNeeded(db)
            return try db.transaction { try action(db) }
        }
    }

    private func access<T>(writing: Bool = false, create: Bool = false, _ action: (TaskSQL) throws -> T) throws -> T {
        try TaskDatabaseLocation.requireDownloaded(url)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        let accessor: (URL) -> Void = { coordinatedURL in
            result = Result {
                let db = try TaskSQL(url: coordinatedURL, writable: writing, create: create)
                defer { db.close() }
                return try action(db)
            }
        }
        let coordinator = NSFileCoordinator()
        if writing { coordinator.coordinate(writingItemAt: url, options: [], error: &coordinationError, byAccessor: accessor) }
        else { coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError, byAccessor: accessor) }
        if let coordinationError { throw coordinationError }
        guard let result else { throw TaskStoreError.message("Could not access the task database.") }
        return try result.get()
    }

    private func backupIfNeeded(_ db: TaskSQL) throws {
        guard let backups else { return }
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let interval = Int(Date().timeIntervalSince1970 / 900)
        let destination = backups.appendingPathComponent("pa3-\(interval).sqlite")
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        let temporary = backups.appendingPathComponent("\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try db.backup(to: temporary)
        try FileManager.default.moveItem(at: temporary, to: destination)
        let files = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "sqlite" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in files.dropFirst(16) { try FileManager.default.removeItem(at: old) }
    }
}

private final class TaskSQL {
    private var connection: OpaquePointer?
    var changedRows: Int32 { sqlite3_changes(connection) }

    init(url: URL, writable: Bool, create: Bool = false) throws {
        let flags = writable ? SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0) : SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(url.path, &connection, flags, nil) == SQLITE_OK else {
            let error = failure()
            close()
            throw error
        }
        do {
            sqlite3_busy_timeout(connection, 2000)
            try execute("PRAGMA foreign_keys = ON")
            if writable {
                let mode = try scalar("PRAGMA journal_mode = DELETE")
                guard mode?.lowercased() == "delete" else { throw TaskStoreError.message("Could not enable single-file database journaling.") }
                try execute("PRAGMA synchronous = FULL")
            }
        } catch { close(); throw error }
    }

    deinit { close() }
    func close() { if let connection { sqlite3_close(connection); self.connection = nil } }

    func rows(_ sql: String, _ values: [String?] = []) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let result: Int32
            if let value { result = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, Int32(value.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } }
            else { result = sqlite3_bind_null(statement, Int32(index + 1)) }
            guard result == SQLITE_OK else { throw failure() }
        }
        var rows: [[String: String]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw failure() }
            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                if let text = sqlite3_column_text(statement, index) {
                    let bytes = UnsafeBufferPointer(start: text, count: Int(sqlite3_column_bytes(statement, index)))
                    row[String(cString: sqlite3_column_name(statement, index))] = String(decoding: bytes, as: UTF8.self)
                }
            }
            rows.append(row)
        }
    }
    func scalar(_ sql: String, _ values: [String?] = []) throws -> String? { try rows(sql, values).first?.values.first }
    func execute(_ sql: String, _ values: [String?] = []) throws { _ = try rows(sql, values) }
    func transaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try operation()
            try execute("COMMIT")
            return result
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func backup(to url: URL) throws {
        let target = try TaskSQL(url: url, writable: true, create: true)
        defer { target.close() }
        guard let backup = sqlite3_backup_init(target.connection, "main", connection, "main") else { throw target.failure() }
        let result = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finish == SQLITE_OK else { throw target.failure() }
    }
    private func failure() -> TaskStoreError { .message(connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open SQLite database.") }
}
