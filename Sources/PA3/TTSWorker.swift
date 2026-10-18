import Darwin
import Foundation

struct TTSWorkerEvent: Codable, Sendable {
    let event: String
    var id: String?
    var path: String?
    var error: String?
    var retryable: Bool?
    var chunk: Int?
    var samples: Int?
    var sampleRate: Int?
}

protocol NarrationWorker: AnyObject {
    var id: UUID { get }
    func start() throws
    func stop()
    func generate(id: String, text: String, voice: String, language: String, instruct: String?, path: URL, pause: Double, seed: Int, stream: Bool)
}

final class TTSWorker: NarrationWorker, @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var stopped = false
    private var streamingPaths: Set<String> = [] // accessed only on writer
    private var pauses: [String: Double] = [:] // accessed only on writer
    private let writer = DispatchQueue(label: "pa3.tts.native")
    private let onEvent: @Sendable (UUID, TTSWorkerEvent) -> Void

    init(onEvent: @escaping @Sendable (UUID, TTSWorkerEvent) -> Void) { self.onEvent = onEvent }

    static var modelDirectory: URL { SpeechRuntime.models.appendingPathComponent("qwen3-tts") }
    static var model: URL { modelDirectory.appendingPathComponent("Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf") }
    static var projector: URL { modelDirectory.appendingPathComponent("mmproj-Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf") }
    static var reference: URL { appResourceDirectory().appendingPathComponent("tts-voices/\(NarrationVoice.defaultVoice).wav") }
    static let modelIDs: Set<String> = ["qwen", "audio"]
    static func modelsInstalled(in directory: URL) -> Bool {
        SpeechModel.all.filter { modelIDs.contains($0.id) }.allSatisfy { $0.isInstalled(in: directory) }
    }
    static var executable: URL {
        if Bundle.main.bundlePath.hasSuffix(".app"), let directory = Bundle.main.executableURL?.deletingLastPathComponent() {
            return directory.appendingPathComponent("pa3-narrator")
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/native/pa3-narrator")
    }
    static var configured: Bool {
        FileManager.default.isExecutableFile(atPath: executable.path)
            && SpeechRuntime.executable("llama-tts") != nil
            && modelsInstalled(in: SpeechRuntime.models)
            && FileManager.default.fileExists(atPath: reference.path)
    }
    static let languages = ["English": "en", "Russian": "ru", "Chinese": "zh", "Japanese": "ja",
                            "Korean": "ko", "German": "de", "French": "fr", "Portuguese": "pt",
                            "Spanish": "es", "Italian": "it"]

    func start() throws {
        guard Self.configured else { throw NarrationText.Invalid("Install speech tools and models, then rebuild PA3") }
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        let child = Process()
        let requests = Pipe(), responses = Pipe(), diagnostics = Pipe()
        child.executableURL = Self.executable
        child.arguments = [Self.model.path, Self.projector.path, Self.reference.path]
        child.standardInput = requests
        child.standardOutput = responses
        child.standardError = diagnostics
        child.terminationHandler = { [weak self] child in
            guard let self else { return }
            self.writer.async { [self] in
                lock.lock()
                let cancelled = stopped
                lock.unlock()
                if !cancelled { onEvent(id, TTSWorkerEvent(event: "exit", error: "Native narrator exited with status \(child.terminationStatus). Check the PA3 log.")) }
            }
        }
        try child.run()
        process = child
        input = requests.fileHandleForWriting
        Logger.info("Started persistent native TTS pid=\(child.processIdentifier)")
        readLines(diagnostics.fileHandleForReading, diagnostics: true)
        readLines(responses.fileHandleForReading, diagnostics: false)
    }

    func generate(id requestID: String, text: String, voice: String, language: String, instruct: String?, path: URL, pause: Double, seed: Int = 7, stream: Bool = false) {
        writer.async { [self] in
            do {
                lock.lock()
                defer { lock.unlock() }
                guard !stopped else { return }
                guard voice == NarrationVoice.defaultVoice, let languageCode = Self.languages[language],
                      (instruct ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let input else {
                    throw NarrationText.Invalid("Invalid native narration request")
                }
                if stream { streamingPaths.insert(path.path) } else { pauses[path.path] = pause }
                var data = try JSONSerialization.data(withJSONObject: ["id": requestID, "text": text, "language": languageCode, "path": path.path, "seed": seed, "stream": stream])
                data.append(10)
                try input.write(contentsOf: data)
            } catch { onEvent(id, TTSWorkerEvent(event: "error", error: "Could not send narration request: \(error)")) }
        }
    }

    private func readLines(_ handle: FileHandle, diagnostics: Bool) {
        DispatchQueue.global(qos: .utility).async { [self] in
            var buffer = Data()
            while true {
                let bytes = handle.availableData
                if bytes.isEmpty { break }
                buffer.append(bytes)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    if diagnostics { Logger.info("TTS: \(String(decoding: line.prefix(8192), as: UTF8.self))") }
                    else { writer.async { [self] in receive(line) } }
                }
                if buffer.count > 65_536 { buffer.removeAll() }
            }
            try? handle.close()
        }
    }

    private func receive(_ line: Data) {
        lock.lock()
        let cancelled = stopped
        lock.unlock()
        guard !cancelled else { return }
        do {
            let event = try JSONDecoder().decode(TTSWorkerEvent.self, from: line)
            if event.event == "audio", let path = event.path, streamingPaths.remove(path) == nil {
                guard let pause = pauses.removeValue(forKey: path) else { throw NarrationText.Invalid("Unexpected audio path") }
                try NarrationAudio.trim(URL(fileURLWithPath: path), pause: pause)
            }
            onEvent(id, event)
        } catch NarrationAudio.Invalid.silence {
            onEvent(id, TTSWorkerEvent(event: "error", error: "The speech model returned silence.", retryable: true))
        } catch { onEvent(id, TTSWorkerEvent(event: "error", error: "Invalid narrator output: \(error)")) }
    }

    func stop() {
        lock.lock()
        stopped = true
        let child = process
        try? input?.close()
        input = nil
        if let child, child.isRunning { child.terminate() }
        lock.unlock()
        guard let child else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if child.isRunning {
                Logger.warn("Native TTS did not exit after SIGTERM; killing owned process")
                kill(child.processIdentifier, SIGKILL)
            }
        }
    }
}
