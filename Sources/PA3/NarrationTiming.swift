import Foundation
import Darwin

struct NarrationWordTiming: Codable, Sendable {
    let location: Int
    let length: Int
    let start: Double
    let end: Double
    var json: [String: Any] { ["location": location, "length": length, "start": start, "end": end] }
}
struct NarrationTimingEvent: Decodable, Sendable {
    var id: String?
    var chunk: Int?
    var words: [NarrationWordTiming]?
    var error: String?
}
protocol NarrationTimingWorker: AnyObject {
    var id: UUID { get }
    func start() throws
    func stop()
    func recognize(id: String, chunk: Int, segment: Int, paths: [URL], words: [NarrationWord], offset: Double, language: String)
}

// Recognition runs outside the app's main thread and owns a private Whisper instance.
final class NarrationTiming: NarrationTimingWorker, @unchecked Sendable {
    let id = UUID()
    private let writer = DispatchQueue(label: "pa3.narration.timing")
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var stopped = false
    private let onEvent: @Sendable (UUID, NarrationTimingEvent) -> Void
    init(onEvent: @escaping @Sendable (UUID, NarrationTimingEvent) -> Void) { self.onEvent = onEvent }

    func start() throws {
        guard let whisper = SpeechRuntime.executable("whisper-server"),
              FileManager.default.fileExists(atPath: SpeechRuntime.whisperModel.path) else {
            throw NarrationText.Invalid("Install the Whisper model and whisper-server for narration highlighting")
        }
        let script = Bundle.main.bundlePath.hasSuffix(".app")
            ? appResourceDirectory().appendingPathComponent("narration/timing.py")
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Narration/timing.py")
        let child = Process(), requests = Pipe(), responses = Pipe(), diagnostics = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-u", script.path, whisper.path, SpeechRuntime.whisperModel.path, "en"]
        child.standardInput = requests; child.standardOutput = responses; child.standardError = diagnostics
        child.terminationHandler = { [weak self] child in
            self?.emit(NarrationTimingEvent(error: "Narration recognition exited with status \(child.terminationStatus)"))
        }
        try child.run()
        lock.lock()
        process = child; input = requests.fileHandleForWriting
        lock.unlock()
        read(responses.fileHandleForReading, diagnostics: false)
        read(diagnostics.fileHandleForReading, diagnostics: true)
        Logger.info("Started narration recognition pid=\(child.processIdentifier)")
    }
    func recognize(id: String, chunk: Int, segment: Int, paths: [URL], words: [NarrationWord], offset: Double, language: String) {
        writer.async { [self] in
            do {
                let encodedWords = try JSONSerialization.jsonObject(with: JSONEncoder().encode(words))
                var data = try JSONSerialization.data(withJSONObject: ["id": id, "chunk": chunk,
                    "segment": "\(id):\(segment)", "paths": paths.map(\.path), "words": encodedWords,
                    "offset": offset, "language": TTSWorker.languages[language] ?? "en"])
                data.append(10)
                lock.lock()
                let handle = stopped ? nil : input
                lock.unlock()
                try handle?.write(contentsOf: data)
            } catch { emit(NarrationTimingEvent(error: "Could not request narration recognition: \(error)")) }
        }
    }
    private func emit(_ event: NarrationTimingEvent) {
        lock.lock(); let cancelled = stopped; lock.unlock()
        if !cancelled { onEvent(id, event) }
    }
    private func read(_ handle: FileHandle, diagnostics: Bool) {
        DispatchQueue.global(qos: .utility).async { [self] in
            var buffer = Data()
            while true {
                let bytes = handle.availableData
                if bytes.isEmpty { break }
                buffer.append(bytes)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                    if diagnostics { Logger.info("Narration ASR: \(String(decoding: line.prefix(8192), as: UTF8.self))") }
                    else {
                        do { emit(try JSONDecoder().decode(NarrationTimingEvent.self, from: line)) }
                        catch { emit(NarrationTimingEvent(error: "Invalid narration timing response: \(error)")) }
                    }
                }
                if buffer.count > 1_048_576 { emit(NarrationTimingEvent(error: "Narration timing response exceeds limit")); break }
            }
            try? handle.close()
        }
    }
    func stop() {
        lock.lock()
        stopped = true
        let child = process, handle = input
        input = nil
        lock.unlock()
        // Terminate before closing a pipe that the writer may be blocked on.
        if let child, child.isRunning { child.terminate() }
        try? handle?.close()
        if let child {
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
    }
}
