import Foundation

// Optional local diagnostics. Disk writes stay off the narration/main thread.
final class NarrationCapture: @unchecked Sendable {
    let directory: URL
    private let queue = DispatchQueue(label: "pa3.narration.capture", qos: .utility)
    private let maxJobs: Int
    private let maxBytes: Int

    init(directory: URL, maxJobs: Int = 20, maxBytes: Int = 128 * 1024 * 1024) {
        self.directory = directory
        self.maxJobs = maxJobs
        self.maxBytes = maxBytes
    }

    func begin(_ id: String, request: Data, plan: [[String: Any]]) {
        guard let plan = try? JSONSerialization.data(withJSONObject: plan, options: [.prettyPrinted, .sortedKeys]) else { return }
        queue.async { [self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let folder = directory.appendingPathComponent(id)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                try write(request, to: folder.appendingPathComponent("request.json"))
                try write(plan, to: folder.appendingPathComponent("plan.json"))
                try write(wavHeader(samples: 0), to: folder.appendingPathComponent("audio.wav"))
                try prune()
            } catch { Logger.warn("Narration capture could not start: \(error)") }
        }
        event(id, "accepted")
    }

    func event(_ id: String, _ name: String, fields: [String: Any] = [:]) {
        var value = fields
        value["event"] = name
        value["timestamp"] = Date().timeIntervalSince1970
        value["uptime"] = ProcessInfo.processInfo.systemUptime
        guard var data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        data.append(10)
        let line = data
        queue.async { [self] in
            let folder = directory.appendingPathComponent(id)
            guard FileManager.default.fileExists(atPath: folder.path) else { return }
            do {
                let path = folder.appendingPathComponent("events.jsonl")
                if !FileManager.default.fileExists(atPath: path.path) { try write(Data(), to: path) }
                let handle = try FileHandle(forWritingTo: path)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try prune()
            } catch { Logger.warn("Narration capture event failed: \(error)") }
        }
    }

    func append(_ id: String, pcm: Data) {
        queue.async { [self] in
            let path = directory.appendingPathComponent(id).appendingPathComponent("audio.wav")
            guard FileManager.default.fileExists(atPath: path.path) else { return }
            do {
                let handle = try FileHandle(forUpdating: path)
                defer { try? handle.close() }
                let size = try handle.seekToEnd()
                try handle.write(contentsOf: pcm)
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: wavHeader(samples: Int(size - 44 + UInt64(pcm.count)) / 4))
                try prune()
            } catch { Logger.warn("Narration audio capture failed: \(error)") }
        }
    }

    // A barrier for orderly shutdown and deterministic diagnostic tests.
    func flush() { queue.sync {} }

    private func write(_ data: Data, to path: URL) throws {
        try data.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    private func wavHeader(samples: Int) -> Data {
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(36 + samples * 4)); ascii("WAVEfmt "); u32(16)
        u16(3); u16(1); u32(24000); u32(96000); u16(4); u16(32)
        ascii("data"); u32(UInt32(samples * 4))
        return data
    }

    private func prune() throws {
        let fm = FileManager.default
        let folders = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) <
                      ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
        let sizes = folders.map { folder -> Int in
            guard let files = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
            return files.compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } }.reduce(0, +)
        }
        var total = sizes.reduce(0, +), count = folders.count
        for (index, folder) in folders.enumerated() {
            guard count > maxJobs || total > maxBytes else { break }
            try fm.removeItem(at: folder)
            total -= sizes[index]; count -= 1
        }
    }
}
