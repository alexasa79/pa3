import Foundation

enum Logger {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handle: FileHandle?

    static func setup(path: URL? = nil) {
        let path = path ?? userDataDirectory().appendingPathComponent("pa3.log")
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
    if let override = ProcessInfo.processInfo.environment["PA3_INSTALL_DIR"], !override.isEmpty {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
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

/// Where full session recordings go. Outside the app bundle so `make app` cannot wipe them.
/// `PA3_RECORDING_DIR` overrides it; otherwise `$XDG_CACHE_HOME/pa3/rec` or `~/.cache/pa3/rec`.
func recordingDirectory() -> URL {
    let environment = ProcessInfo.processInfo.environment
    if let override = environment["PA3_RECORDING_DIR"], !override.isEmpty {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    let cache: URL
    if let xdg = environment["XDG_CACHE_HOME"], !xdg.isEmpty {
        cache = URL(fileURLWithPath: xdg, isDirectory: true)
    } else {
        cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache", isDirectory: true)
    }
    return cache.appendingPathComponent("pa3/rec", isDirectory: true)
}
