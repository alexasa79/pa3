import Foundation

enum SpeechRuntime {
    // Finder-launched apps do not inherit the interactive shell's Homebrew PATH.
    static func executable(_ name: String) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let directories = [environment["HOMEBREW_PREFIX"].map { $0 + "/bin" },
                           "/opt/homebrew/bin", "/usr/local/bin"].compactMap { $0 }
            + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return directories.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var models: URL {
        if let override = ProcessInfo.processInfo.environment["PA3_MODEL_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return userDataDirectory().appendingPathComponent("models")
    }
    static var whisperModel: URL {
        if let override = ProcessInfo.processInfo.environment["PA3_WHISPER_MODEL"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let installed = models.appendingPathComponent("whisper.ggml")
        if FileManager.default.fileExists(atPath: installed.path) { return installed }
        let legacy = appResourceDirectory().appendingPathComponent("models/whisper.ggml")
        return FileManager.default.fileExists(atPath: legacy.path) ? legacy : installed
    }
}
