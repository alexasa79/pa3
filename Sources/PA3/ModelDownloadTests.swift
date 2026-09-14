import AppKit
import CryptoKit
import Foundation
@preconcurrency import Network
import SwiftUI

private final class ModelTestServer: @unchecked Sendable {
    let payload = Data(repeating: 65, count: 4 * 1024 * 1024)
    let listener: NWListener
    let queue = DispatchQueue(label: "pa3.model-test.server")

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [self] connection in
                connection.start(queue: queue)
                receive(connection, prefix: Data())
            }
            listener.start(queue: queue)
        }
    }
    private func receive(_ connection: NWConnection, prefix: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] data, _, complete, error in
            let request = prefix + (data ?? Data())
            guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete || error != nil { connection.cancel() }
                else { receive(connection, prefix: request) }
                return
            }
            let text = String(decoding: request, as: UTF8.self)
            let failed = text.hasPrefix("GET /failed ")
            let short = text.hasPrefix("GET /short ")
            let bad = text.hasPrefix("GET /bad ")
            let body = failed ? Data("unavailable".utf8) : bad ? Data(repeating: 66, count: payload.count) : short ? payload.prefix(payload.count / 2) : payload
            let header = "HTTP/1.1 \(failed ? "503 Unavailable" : "200 OK")\r\nContent-Length: \(failed ? body.count : payload.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { [self] error in
                if error != nil { connection.cancel() }
                else { send(connection, body: body, offset: 0) }
            })
        }
    }
    private func send(_ connection: NWConnection, body: Data, offset: Int) {
        guard offset < body.count else { connection.cancel(); return }
        let end = min(offset + 65536, body.count)
        connection.send(content: body[offset..<end], completion: .contentProcessed { [self] error in
            if error != nil { connection.cancel(); return }
            queue.asyncAfter(deadline: .now() + 0.015) { [self] in send(connection, body: body, offset: end) }
        })
    }
}

@MainActor
func runModelDownloadTests() async -> Int32 {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pa3-model-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    func require(_ value: Bool, _ message: String) throws {
        if !value { throw ModelDownload.DownloadError(message) }
    }
    do {
        let server = try ModelTestServer()
        let port = try await server.start()
        defer { server.listener.cancel() }
        let hash = SHA256.hash(data: server.payload).map { String(format: "%02x", $0) }.joined()
        func model(_ path: String, id: String = "fixture") -> SpeechModel {
            SpeechModel(id: id, name: "Dictation", detail: "Whisper large-v3-turbo", relativePath: id + ".gguf",
                        bytes: Int64(server.payload.count), sha256: hash, url: URL(string: "http://127.0.0.1:\(port)/\(path)")!)
        }
        let good = model("good")
        try await ModelDownload(model: good, directory: directory) { _, _ in }.run()
        try require(try Data(contentsOf: good.destination(in: directory)) == server.payload, "Downloaded data changed")
        for path in ["bad", "short", "failed"] {
            do {
                try await ModelDownload(model: model(path), directory: directory) { _, _ in }.run()
                throw ModelDownload.DownloadError("Invalid download accepted: \(path)")
            } catch let error as ModelDownload.DownloadError where error.message.hasPrefix("Invalid download accepted") { throw error }
            catch {}
            try require(try Data(contentsOf: good.destination(in: directory)) == server.payload, "Failed download replaced an existing model")
        }
        print("PASS verified download, corrupt hash, short transfer, HTTP error, atomic replacement")

        let cancelModel = model("good", id: "cancelled")
        let transfer = ModelDownload(model: cancelModel, directory: directory) { _, _ in }
        let download = Task { try await transfer.run() }
        try await Task.sleep(for: .milliseconds(180))
        download.cancel()
        do { try await download.value; throw ModelDownload.DownloadError("Cancellation was ignored") }
        catch is CancellationError {}
        catch let error as URLError where error.code == .cancelled {}
        try require(!cancelModel.isInstalled(in: directory), "Cancelled file was installed")
        try await ModelDownload(model: cancelModel, directory: directory) { _, _ in }.run()
        try require(cancelModel.isInstalled(in: directory), "Retry failed")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        try require(!remaining.contains { $0.hasPrefix(".download-") }, "Staging file leaked")
        print("PASS cancellation, retry, and staging cleanup")

        let models = SpeechModel.all.map { source in
            SpeechModel(id: source.id, name: source.name, detail: source.detail, relativePath: source.relativePath,
                        bytes: Int64(server.payload.count), sha256: hash, url: good.url)
        }
        let manager = ModelDownloadManager(models: models, directory: directory.appendingPathComponent("manager"))
        var presentations = 0
        manager.onPresent = { presentations += 1 }
        try require(!manager.ensureModels() && manager.running && presentations == 1, "Missing models did not start setup")
        _ = manager.ensureModels()
        let deadline = Date().addingTimeInterval(15)
        var sawProgress = false
        while manager.running && Date() < deadline {
            if manager.fraction > 0 && manager.fraction < 1, !sawProgress {
                sawProgress = true
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory)
                let hosting = NSHostingView(rootView: ModelDownloadView(manager: manager, close: {}))
                hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
                hosting.layoutSubtreeIfNeeded()
                if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/pa3-model-download-preview.png"))
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        try require(manager.ready && !manager.running && manager.error == nil && sawProgress, "Manager did not finish or report progress: \(manager.status)")
        try require(manager.ensureModels() && !manager.running, "Installed models downloaded again")
        print("PASS automatic setup, byte progress, sequential models, and installed-model skip")

        let controller = DictationController(transcriber: TranscriberService())
        var askedForModels = false
        controller.prepareModels = { askedForModels = true; return false }
        controller.startDictation()
        try require(askedForModels && !controller.dictating && !controller.narrationIsBlocked,
                    "Dictation opened audio before models were ready")
        controller.shutdown()
        print("PASS missing-model guard leaves microphone and audio output untouched")
        return 0
    } catch {
        print("FAIL model download: \(error)")
        return 1
    }
}
