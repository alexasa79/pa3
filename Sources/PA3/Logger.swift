import Foundation

enum Logger {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handle: FileHandle?

    static func setup() {
        let path = userDataDirectory().appendingPathComponent("pa3.log")
        FileManager.default.createFile(atPath: path.path, contents: nil)
        handle = try? FileHandle(forWritingTo: path)
        try? handle?.truncate(atOffset: 0)
        info("First log at \(Date())")
    }

    static func close() {
        try? handle?.close()
        handle = nil
    }

    static func trace(_ message: String) { write("TRACE", message) }
    static func debug(_ message: String) { write("DEBUG", message) }
    static func info(_ message: String) { write("INFO", message) }
    static func warn(_ message: String) { write("WARN", message) }
    static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(Self.timestamp()) \(level) \(message)\n"
        if let data = line.data(using: .utf8) {
            try? handle?.write(contentsOf: data)
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSSSSS"
        return formatter.string(from: Date())
    }
}

func appResourceDirectory() -> URL {
    if let resourceURL = Bundle.main.resourceURL,
       Bundle.main.bundlePath.hasSuffix(".app") {
        return resourceURL
    }
    let exe = URL(fileURLWithPath: CommandLine.arguments.first ?? FileManager.default.currentDirectoryPath)
    return exe.deletingLastPathComponent()
}

func userDataDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    let dir = base.appendingPathComponent("PA3", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
