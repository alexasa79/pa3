import CryptoKit
import Darwin
import Foundation
import SwiftUI

struct SpeechModel: Identifiable, Sendable {
    let id: String
    let name: String
    let detail: String
    let relativePath: String
    let bytes: Int64
    let sha256: String
    let url: URL

    static let all: [SpeechModel] = [
        SpeechModel(id: "whisper", name: "Dictation", detail: "Whisper large-v3-turbo", relativePath: "whisper.ggml", bytes: 1_624_555_275,
                    sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
                    url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin")!),
        SpeechModel(id: "qwen", name: "Narration", detail: "Qwen3 TTS", relativePath: "qwen3-tts/Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf", bytes: 1_847_874_400,
                    sha256: "ac7931aeb2e7aad1a6ed6602d353a5679c9d096b18ce8204ac730a8408d572e1",
                    url: URL(string: "https://huggingface.co/ggml-org/Qwen3-TTS-12Hz-1.7B-Base-GGUF/resolve/ca27d74bc954b73dadab5b71ca265d87fc861a7c/Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf")!),
        SpeechModel(id: "audio", name: "Voice processing", detail: "Qwen3 audio model", relativePath: "qwen3-tts/mmproj-Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf", bytes: 446_422_912,
                    sha256: "6fd65188839bcd6ecc91b277ad471e22a0edfada4699a0fe82f1165c18cfcce2",
                    url: URL(string: "https://huggingface.co/ggml-org/Qwen3-TTS-12Hz-1.7B-Base-GGUF/resolve/ca27d74bc954b73dadab5b71ca265d87fc861a7c/mmproj-Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf")!)
    ]

    func destination(in directory: URL) -> URL { directory.appendingPathComponent(relativePath) }
    func isInstalled(in directory: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: destination(in: directory).path)
        return (attributes?[.size] as? NSNumber)?.int64Value == bytes
    }
}

/// Streams to disk, checks the pinned size and SHA-256, then atomically publishes the model.
/// The delegate queue does all file hashing; the main thread only receives progress updates.
final class ModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let model: SpeechModel
    private let destination: URL
    private let configuration: URLSessionConfiguration
    private let progress: @Sendable (Int64, Bool) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var outcome: Error?
    private var installed = false
    private var lastProgress = Date.distantPast

    init(model: SpeechModel, directory: URL, configuration: URLSessionConfiguration = .ephemeral,
         progress: @escaping @Sendable (Int64, Bool) -> Void) {
        self.model = model
        self.destination = model.destination(in: directory)
        self.configuration = configuration
        self.progress = progress
    }

    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                defer { lock.unlock() }
                if cancelled { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 24 * 60 * 60
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                var request = URLRequest(url: model.url)
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let task = session.downloadTask(with: request)
                self.task = task
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    private func checkCancellation() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw CancellationError() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > model.bytes {
            outcome = DownloadError("The downloaded file is larger than expected. Please retry.")
            downloadTask.cancel()
        }
        if Date().timeIntervalSince(lastProgress) >= 0.1 {
            lastProgress = Date()
            progress(min(totalBytesWritten, model.bytes), false)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try checkCancellation()
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
                throw DownloadError("The model server returned HTTP \((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0). Please retry.")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
            guard (attributes[.size] as? NSNumber)?.int64Value == model.bytes else {
                throw DownloadError("The download was incomplete. Please retry.")
            }
            progress(model.bytes, true)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: staging)
            let file = try FileHandle(forReadingFrom: staging)
            defer { try? file.close() }
            var hash = SHA256()
            while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty {
                try checkCancellation()
                hash.update(data: bytes)
            }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == model.sha256 else {
                throw DownloadError("The downloaded model did not pass verification. Please retry.")
            }
            // Cancel and publish are serialized so cancellation cannot publish partial data.
            lock.lock()
            defer { lock.unlock() }
            if cancelled { throw CancellationError() }
            guard rename(staging.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            installed = true
        } catch { outcome = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        let failure = cancelled ? CancellationError() : (outcome ?? error)
        self.task = nil
        self.session = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        if let failure { continuation?.resume(throwing: failure) }
        else if installed { continuation?.resume() }
        else { continuation?.resume(throwing: DownloadError("The download did not produce a model. Please retry.")) }
    }

    struct DownloadError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

@MainActor
final class ModelDownloadManager: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var installed: Set<String> = []
    @Published private(set) var currentID: String?
    @Published private(set) var currentBytes: Int64 = 0
    @Published private(set) var completedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var verifying = false
    @Published private(set) var error: String?
    @Published private(set) var wasCancelled = false
    let models: [SpeechModel]
    let directory: URL
    private var work: Task<Void, Never>?
    var onPresent: (() -> Void)?

    init(models: [SpeechModel] = SpeechModel.all, directory: URL = SpeechRuntime.models) {
        self.models = models
        self.directory = directory
        refresh()
    }

    var ready: Bool { models.allSatisfy { installed.contains($0.id) } }
    var fraction: Double { totalBytes > 0 ? min(1, Double(completedBytes + currentBytes) / Double(totalBytes)) : (ready ? 1 : 0) }
    var status: String {
        if let error { return error }
        if wasCancelled { return "Download cancelled. You can retry whenever you're ready." }
        if ready { return "Your speech models are ready to use." }
        if verifying { return "Verifying \(models.first { $0.id == currentID }?.name.lowercased() ?? "model")…" }
        return "Downloading \(models.first { $0.id == currentID }?.name.lowercased() ?? "speech models")…"
    }

    func refresh() {
        installed = Set(models.filter { model in
            // Keep an explicitly configured custom Whisper model or an existing legacy model.
            if model.id == "whisper", directory == SpeechRuntime.models,
               SpeechRuntime.whisperModel != model.destination(in: directory),
               FileManager.default.fileExists(atPath: SpeechRuntime.whisperModel.path) { return true }
            return model.isInstalled(in: directory)
        }.map(\.id))
    }

    @discardableResult func ensureModels() -> Bool {
        if running { onPresent?(); return false }
        refresh()
        if ready { return true }
        start()
        onPresent?()
        return false
    }

    func ensure(_ ids: Set<String>) -> Bool {
        refresh()
        if ids.isSubset(of: installed) { return true }
        ensureModels()
        return false
    }

    var health: [String: Any] {
        ["state": running ? (verifying ? "verifying" : "downloading") : ready ? "ready" : error != nil ? "failed" : "missing",
         "progress": fraction, "error": error as Any? ?? NSNull()]
    }

    func start() {
        guard !running else { return }
        refresh()
        let missing = models.filter { !installed.contains($0.id) }
        guard !missing.isEmpty else { return }
        running = true
        error = nil
        wasCancelled = false
        totalBytes = missing.reduce(0) { $0 + $1.bytes }
        completedBytes = 0
        currentBytes = 0
        work = Task { [weak self] in
            guard let self else { return }
            do {
                for model in missing {
                    try Task.checkCancellation()
                    currentID = model.id
                    currentBytes = 0
                    verifying = false
                    let transfer = ModelDownload(model: model, directory: directory) { [weak self] bytes, verifying in
                        Task { @MainActor in
                            guard let self, self.running, self.currentID == model.id else { return }
                            self.currentBytes = bytes
                            self.verifying = verifying
                        }
                    }
                    try await transfer.run()
                    installed.insert(model.id)
                    completedBytes += model.bytes
                    currentBytes = 0
                }
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    wasCancelled = true
                } else {
                    self.error = error.localizedDescription
                    Logger.error("Speech model download failed: \(error)")
                }
            }
            currentID = nil
            verifying = false
            running = false
            work = nil
            refresh()
        }
    }

    func cancel() { work?.cancel() }
}
