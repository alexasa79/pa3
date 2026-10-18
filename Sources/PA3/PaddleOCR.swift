import Foundation
import Darwin

/// Local image recognition. The private server has no external listener or UI.
@MainActor
final class PaddleOCR {
    static let shared = PaddleOCR()
    static let modelIDs: Set<String> = ["paddleocr", "paddleocr-vision"]
    private var process: Process?
    private var session: URLSession?
    private var endpoint: URL?
    private var key = ""
    private var generation = UUID()
    private var idle: Task<Void, Never>?
    private var busy = false

    func recognize(_ image: URL) async throws -> String {
        guard !busy else { throw NarrationText.Invalid("Screen recognition is already running. Try again.") }
        busy = true
        idle?.cancel()
        let current = generation
        defer {
            busy = false
            if generation == current {
                idle = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(60)); self?.stop() } catch {}
                }
            }
        }
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try await prepare()
                try Task.checkCancellation()
                guard let endpoint, let session else { throw NarrationText.Invalid("Screen recognition stopped.") }
                let bytes = try Data(contentsOf: image)
                guard bytes.count <= 20_000_000 else { throw NarrationText.Invalid("Select a smaller screen area.") }
                var request = URLRequest(url: endpoint.appendingPathComponent("v1/chat/completions"))
                request.timeoutInterval = 60
                request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpMethod = "POST"
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "messages": [["role": "user", "content": [
                        ["type": "image_url", "image_url": ["url": "data:image/png;base64," + bytes.base64EncodedString()]],
                        ["type": "text", "text": "OCR:"]]]],
                    "temperature": 0, "seed": 1, "max_tokens": 4096, "stream": false, "cache_prompt": false
                ])
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choice = (body["choices"] as? [[String: Any]])?.first,
                      choice["finish_reason"] as? String == "stop",
                      let message = choice["message"] as? [String: Any], let text = message["content"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 100_000 else {
                    throw NarrationText.Invalid("Could not read the complete screen text. Try a smaller rectangle.")
                }
                return text
            } catch {
                stop()
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if self?.generation == current { self?.stop() }
            }
        }
    }

    private func prepare() async throws {
        if process?.isRunning == true { return }
        guard let executable = SpeechRuntime.executable("llama-server") else {
            throw NarrationText.Invalid("Install llama.cpp to recognize screen text.")
        }
        let models = SpeechModel.all.filter { Self.modelIDs.contains($0.id) }
        guard models.count == 2, models.allSatisfy({ $0.isInstalled(in: SpeechRuntime.models) }) else {
            throw NarrationText.Invalid("Download the screen recognition models from PA3’s Models menu, then try again.")
        }
        let port = try Self.availablePort()
        let endpoint = URL(string: "http://127.0.0.1:\(port)")!
        key = UUID().uuidString
        let child = Process(), diagnostics = Pipe()
        child.executableURL = executable
        child.arguments = ["-m", models.first { $0.id == "paddleocr" }!.destination(in: SpeechRuntime.models).path,
            "--mmproj", models.first { $0.id == "paddleocr-vision" }!.destination(in: SpeechRuntime.models).path,
            "--host", "127.0.0.1", "--port", String(port), "--api-key", key,
            "--ctx-size", "8192", "--parallel", "1", "--n-gpu-layers", "99", "--temp", "0", "--no-webui"]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = diagnostics
        child.standardError = diagnostics
        try child.run()
        process = child
        self.endpoint = endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 70
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        self.session = session
        DispatchQueue.global(qos: .utility).async {
            let handle = diagnostics.fileHandleForReading
            var buffer = Data()
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                buffer.append(data)
                while let end = buffer.firstIndex(of: 10) {
                    Logger.info("Screen OCR: \(String(decoding: buffer[..<end].prefix(2048), as: UTF8.self))")
                    buffer.removeSubrange(...end)
                }
                if buffer.count > 8192 { buffer.removeAll() }
            }
            try? handle.close()
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            try Task.checkCancellation()
            guard child.isRunning else { throw NarrationText.Invalid("Screen recognition could not start. See the PA3 log.") }
            var request = URLRequest(url: endpoint.appendingPathComponent("health"))
            request.timeoutInterval = 1
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            if let (_, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 {
                Logger.info("PaddleOCR-VL ready pid=\(child.processIdentifier)")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NarrationText.Invalid("Screen recognition took too long to start. Try again.")
    }

    func stop() {
        generation = UUID()
        idle?.cancel(); idle = nil
        session?.invalidateAndCancel(); session = nil
        endpoint = nil
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        process = nil
    }

    private static func availablePort() throws -> UInt16 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError(.EADDRNOTAVAIL) }
        defer { Darwin.close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return try withUnsafeMutablePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                guard Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 else { throw POSIXError(.EADDRINUSE) }
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                guard getsockname(socket, $0, &length) == 0 else { throw POSIXError(.EADDRNOTAVAIL) }
                return UInt16(bigEndian: pointer.pointee.sin_port)
            }
        }
    }
}
