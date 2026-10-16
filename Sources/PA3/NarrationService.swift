@preconcurrency import AVFoundation
import Foundation

struct NarrationInput: Decodable {
    let text: String
    var voice: String?
    var language: String?
    var mode: String?
    var instruct: String?
    var pronunciations: [String: String]?
    var output: String?
    var timing: String?
}

enum NarrationVoice {
    static let defaultVoice = "vctk-p311"

    static func resolve(_ value: String?) -> String? {
        guard let value else { return defaultVoice }
        if [defaultVoice, "p311"].contains(value.lowercased()) { return defaultVoice }
        return nil
    }
}

@MainActor
final class NarrationService: NSObject, AVAudioPlayerDelegate {
    private struct StreamChunk {
        let path: URL
        let samples: Int
        let sampleRate: Int
        var words: [NarrationWordTiming]?
        var json: [String: Any] {
            var result: [String: Any] = ["samples": samples, "sample_rate": sampleRate]
            if let words { result["word_timings"] = words.map(\.json) }
            return result
        }
    }
    private struct Job {
        let id: String
        let characters: Int
        let voice: String
        let language: String
        let instruct: String?
        var chunks: [NarrationPiece]
        let isSelection: Bool
        let output: String
        var timed = false
        var published = 0
        var segmentStart = 0
        var sourceLength = 0
        var audioExpires: Date?
        var streamChunks: [StreamChunk] = []
        var nextStreamChunk = 0
        var audioPieces: [[String: Double]] = []
        var state = "queued"
        var generated = 0
        var played = 0
        var silenceRetries = 0
        let total: Int
        var error: String?
        var json: [String: Any] {
            var value: [String: Any] = ["id": id, "state": state, "characters": characters,
                "voice": voice, "language": language, "pieces": total, "pieces_played": played,
                "pieces_generated": generated, "output": output, "audio_available": audioExpires != nil]
            if output == "stream" { value["audio_chunks"] = Array(streamChunks.prefix(published)).map(\.json) }
            if output == "pieces" { value["audio_pieces"] = Array(audioPieces.prefix(generated)) }
            if let error { value["error"] = error }
            return value
        }
    }

    private let server = NarrationHTTPServer()
    private var jobs: [String: Job] = [:]
    private var order: [String] = []
    private var pending: [String] = []
    private var active: String?
    private var worker: (any NarrationWorker)?
    private let makeWorker: (@escaping @Sendable (UUID, TTSWorkerEvent) -> Void) -> any NarrationWorker
    private let isConfigured: () -> Bool
    private var timingWorker: (any NarrationTimingWorker)?
    private var timingDeadline: Date?
    private let makeTimingWorker: (@escaping @Sendable (UUID, NarrationTimingEvent) -> Void) -> any NarrationTimingWorker
    private var workerReady = false
    private var workerDeadline: Date?
    private var generatingPath: URL?
    private var prepared: [URL] = []
    private var playingPath: URL?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var token = ""
    private var shuttingDown = false
    private var warmupAttempted = false
    private let audioDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("pa3-narration-\(UUID().uuidString)")
    var isDictationBusy: () -> Bool = { false }
    var pronunciationDictionary: () throws -> [String: String] = { [:] }
    var prepareModels: () -> Bool = { true }
    var modelDownloadHealth: () -> [String: Any] = { [:] }
    var onSelectionFailure: (String) -> Void = { _ in }
    var hasNarration: Bool { active != nil || !pending.isEmpty }

    init(isConfigured: @escaping () -> Bool = { TTSWorker.configured }, token: String = "",
         makeWorker: @escaping (@escaping @Sendable (UUID, TTSWorkerEvent) -> Void) -> any NarrationWorker = { TTSWorker(onEvent: $0) },
         makeTimingWorker: @escaping (@escaping @Sendable (UUID, NarrationTimingEvent) -> Void) -> any NarrationTimingWorker = { NarrationTiming(onEvent: $0) }) {
        self.token = token
        self.isConfigured = isConfigured
        self.makeWorker = makeWorker
        self.makeTimingWorker = makeTimingWorker
        super.init()
    }

    func narrateSelection(_ selection: SelectedTextResult) -> NarrationHTTPResponse {
        guard let text = selection.text else { return .error(422, "No selected text") }
        let data = (try? JSONSerialization.data(withJSONObject: ["text": text, "mode": "replace"])) ?? Data()
        return submit(data, selection: selection)
    }
    private let languages = Array(TTSWorker.languages.keys)

    func start() {
        do {
            let tokenFile = userDataDirectory().appendingPathComponent("narration-token")
            if let saved = try? String(contentsOf: tokenFile, encoding: .utf8), !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                token = saved.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                token = UUID().uuidString + UUID().uuidString
                try Data((token + "\n").utf8).write(to: tokenFile, options: .atomic)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
            try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let rawPort = ProcessInfo.processInfo.environment["PA3_NARRATION_PORT"] ?? "65462"
            guard let port = UInt16(rawPort), port > 0 else { throw NarrationText.Invalid("Invalid PA3_NARRATION_PORT") }
            try server.start(port: port) { [weak self] request, reply in
                Task { @MainActor in reply(self?.handle(request) ?? .error(503, "PA3 is shutting down")) }
            }
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.expireAudio()
                    if self.active != nil && self.isDictationBusy() { self.stopAll() }
                    if let deadline = self.timingDeadline, Date() > deadline { self.failActive("Narration recognition timed out") }
                    if let deadline = self.workerDeadline, Date() > deadline { self.workerFailed("Qwen worker timed out") }
                    if !self.warmupAttempted, TTSWorker.configured, !self.isDictationBusy() {
                        self.startWorker()
                    }
                }
            }
        } catch {
            Logger.error("Narration startup failed: \(error)")
        }
    }

    func handle(_ request: NarrationHTTPRequest) -> NarrationHTTPResponse {
        guard !shuttingDown else { return .error(503, "PA3 is shutting down") }
        guard request.headers["origin"] == nil else { return .error(403, "Browser origins are not allowed") }
        if request.method == "GET", request.path == "/health" {
            return .json(200, ["service": "pa3-narration", "configured": TTSWorker.configured,
                "model": "Qwen3-TTS-12Hz-1.7B-Base-Q8_0", "model_loaded": workerReady,
                "runtime": "libllama", "runtime_ready": workerReady, "model_residency": "persistent",
                "default_voice": NarrationVoice.defaultVoice,
                "model_download": modelDownloadHealth(),
                "dictation_busy": isDictationBusy(), "queued": pending.count, "active_id": active as Any? ?? NSNull()])
        }
        guard !token.isEmpty, request.headers["authorization"] == "Bearer \(token)" else { return .error(401, "Missing or invalid bearer token") }
        if request.method == "POST" {
            guard request.headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else {
                return .error(415, "Use Content-Type: application/json")
            }
            if request.path == "/v1/narrations/stop" {
                stopAll()
                return .json(200, ["stopped": true])
            }
            if request.path == "/v1/narrations" { return submit(request.body) }
        }
        if request.path.hasPrefix("/v1/narrations/") {
            let suffix = String(request.path.dropFirst("/v1/narrations/".count))
            let components = suffix.split(separator: "/", omittingEmptySubsequences: false)
            let id = String(components[0])
            guard let job = jobs[id] else { return .error(404, "Unknown narration job") }
            if components.count > 1 {
                guard request.method == "GET", ["audio", "chunks"].contains(String(components[1])) else { return .error(404, "Unknown endpoint") }
                if components[1] == "chunks" {
                    if components.count == 3, let index = Int(components[2]) { return streamResponse(id, index: index) }
                    return .error(404, "Unknown endpoint")
                }
                if components.count == 2 { return audioResponse(id) }
                if components.count == 3, let index = Int(components[2]) { return pieceResponse(id, index: index) }
                return .error(404, "Unknown endpoint")
            }
            if request.method == "GET" { return .json(200, job.json) }
            if request.method == "DELETE" {
                cancel(id)
                return .json(200, jobs[id]?.json ?? job.json)
            }
        }
        return .error(404, "Unknown endpoint")
    }

    func submit(_ data: Data, selection: SelectedTextResult? = nil) -> NarrationHTTPResponse {
        guard let input = try? JSONDecoder().decode(NarrationInput.self, from: data) else { return .error(400, "Invalid JSON; text must be a string") }
        guard ["playback", "audio", "pieces", "stream"].contains(input.output ?? "playback") else { return .error(422, "Output must be playback, audio, pieces, or stream") }
        if ["audio", "pieces", "stream"].contains(input.output ?? ""), input.text.count > 4000 { return .error(422, "Audio requests are limited to 4,000 characters") }
        guard input.timing == nil || (input.timing == "words" && input.output == "stream") else {
            return .error(422, "Word timing requires stream output")
        }
        guard ["enqueue", "replace"].contains(input.mode ?? "enqueue") else { return .error(422, "Mode must be enqueue or replace") }
        guard let voice = NarrationVoice.resolve(input.voice),
              let language = languages.first(where: { $0.lowercased() == (input.language ?? "English").lowercased() }) else {
            return .error(422, "Use voice vctk-p311 and an explicit supported language; native narration does not support presets or Auto")
        }
        guard (input.instruct?.count ?? 0) <= 1000 else { return .error(422, "Instructions exceed 1,000 characters") }
        if voice == NarrationVoice.defaultVoice, !(input.instruct ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .error(422, "The voice uses the saved VCTK p311 reference. Native narration does not support delivery instructions.")
        }
        guard prepareModels() else { return .error(503, "Speech models are downloading. See PA3 for progress, then retry this request.") }
        guard isConfigured() else { return .error(503, "Install speech tools with brew install whisper.cpp, then retry.") }
        guard !isDictationBusy() else { return .error(409, "Dictation is active or audio output is still being restored") }
        do {
            let chunks = try NarrationText.plan(input, dictionary: pronunciationDictionary())
            guard input.mode == "replace" || pending.count < 10 else { return .error(429, "Narration queue is full") }
            if input.mode == "replace" { stopAll() }
            let id = UUID().uuidString.lowercased()
            jobs[id] = Job(id: id, characters: input.text.count, voice: voice, language: language,
                           instruct: input.instruct, chunks: chunks, isSelection: selection != nil, output: input.output ?? "playback", total: chunks.count)
            jobs[id]?.timed = input.timing == "words"
            jobs[id]?.sourceLength = input.text.utf16.count
            jobs[id]?.audioPieces = chunks.map {
                ["start": Double($0.sourceRange.location) / Double(input.text.utf16.count),
                 "end": Double(NSMaxRange($0.sourceRange)) / Double(input.text.utf16.count)]
            }
            order.append(id)
            pending.append(id)
            pruneHistory()
            Logger.info("Narration accepted id=\(id) chars=\(input.text.count) pieces=\(chunks.count)")
            pump()
            return .json(202, jobs[id]!.json)
        } catch let error as NarrationText.Invalid { return .error(422, error.message) }
        catch { return .error(422, "Could not prepare narration text") }
    }

    private func startWorker() {
        guard worker == nil else { return }
        warmupAttempted = true
        let worker = makeWorker { [weak self] workerID, event in
            Task { @MainActor in self?.workerEvent(workerID, event) }
        }
        self.worker = worker
        workerReady = false
        workerDeadline = Date().addingTimeInterval(90)
        do { try worker.start() }
        catch { workerFailed("Could not start the Qwen worker: \(error)") }
    }

    private func pump() {
        guard !shuttingDown else { return }
        if isDictationBusy() { stopAll(); return }
        if active == nil, !pending.isEmpty { active = pending.removeFirst() }
        guard let id = active, var job = jobs[id] else { return }
        if worker == nil {
            jobs[id]?.state = "loading"
            startWorker()
            return
        }
        guard workerReady else { jobs[id]?.state = "loading"; return }
        if job.output == "playback", player == nil, !prepared.isEmpty {
            let path = prepared.removeFirst()
            do {
                let player = try AVAudioPlayer(contentsOf: path)
                player.delegate = self
                // AVAudioPlayer rate adjustment preserves pitch; enable before preparing.
                player.enableRate = true
                player.rate = 1.1
                player.prepareToPlay()
                guard player.play() else { throw NarrationText.Invalid("Audio output could not start") }
                self.player = player
                playingPath = path
                jobs[id]?.state = "playing"
                Logger.info("Narration playing id=\(id) piece=\(job.played + 1)")
            } catch { failActive("Could not play generated audio"); return }
        }
        job = jobs[id]!
        if generatingPath == nil, (job.output != "playback" || prepared.count < 3), job.generated < job.total {
            let directory = audioDirectory.appendingPathComponent(id)
            do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            catch { failActive("Could not create temporary audio directory"); return }
            let path = directory.appendingPathComponent("\(job.generated).wav")
            generatingPath = path
            jobs[id]?.nextStreamChunk = 0
            jobs[id]?.segmentStart = job.streamChunks.count
            workerDeadline = Date().addingTimeInterval(120)
            if player == nil { jobs[id]?.state = "generating" }
            worker?.generate(id: id, text: job.chunks[job.generated].text, voice: job.voice,
                             language: job.language, instruct: job.instruct, path: path,
                             pause: job.chunks[job.generated].pauseAfter, seed: 7 + job.silenceRetries, stream: job.output == "stream")
        } else if job.output != "playback", generatingPath == nil, job.generated == job.total {
            guard job.published == job.streamChunks.count else { return }
            let directory = audioDirectory.appendingPathComponent(id)
            do {
                if job.output == "audio" {
                    try NarrationAudio.concatenate(prepared, to: directory.appendingPathComponent("audio.wav"))
                    for path in prepared { try FileManager.default.removeItem(at: path) }
                }
            } catch { failActive("Could not assemble generated audio: \(error)"); return }
            prepared = []
            jobs[id]?.state = "completed"
            jobs[id]?.chunks = []
            jobs[id]?.audioExpires = Date().addingTimeInterval(300)
            active = nil
            pump()
        } else if player == nil, prepared.isEmpty, generatingPath == nil, job.played == job.total {
            jobs[id]?.state = "completed"
            jobs[id]?.chunks = []
            try? FileManager.default.removeItem(at: audioDirectory.appendingPathComponent(id))
            Logger.info("Narration completed id=\(id)")
            active = nil
            pump()
        }
    }

    private func workerEvent(_ id: UUID, _ event: TTSWorkerEvent) {
        guard worker?.id == id else { return }
        switch event.event {
        case "ready":
            workerReady = true
            workerDeadline = nil
            Logger.info("Qwen worker ready")
            pump()
        case "partial":
            guard let active, event.id == active, let path = generatingPath,
                  let job = jobs[active], job.output == "stream", event.chunk == job.nextStreamChunk,
                  let samples = event.samples, samples > 0, samples <= 192000,
                  let rate = event.sampleRate, rate == 24000,
                  event.path == path.path + ".part-\(job.nextStreamChunk).pcm" else {
                workerFailed("Unexpected streaming audio response from Qwen"); return
            }
            let chunkPath = URL(fileURLWithPath: event.path!)
            guard (try? chunkPath.resourceValues(forKeys: [.fileSizeKey]).fileSize) == samples * 4,
                  audioWithinLimit(active) else { failActive("Invalid streaming audio or storage limit exceeded"); return }
            jobs[active]?.streamChunks.append(StreamChunk(path: chunkPath, samples: samples, sampleRate: rate))
            jobs[active]?.nextStreamChunk += 1
            if job.timed {
                if timingWorker == nil {
                    let timing = makeTimingWorker { [weak self] workerID, event in
                        Task { @MainActor in self?.timingEvent(workerID, event) }
                    }
                    timingWorker = timing
                    do { try timing.start() }
                    catch { failActive("Could not start narration recognition: \(error)"); return }
                }
                let chunks = jobs[active]!.streamChunks
                if timingDeadline == nil { timingDeadline = Date().addingTimeInterval(120) }
                timingWorker?.recognize(id: active, chunk: chunks.count - 1, segment: job.generated,
                    paths: chunks[job.segmentStart...].map(\.path), words: job.chunks[job.generated].words,
                    offset: chunks[..<job.segmentStart].reduce(0) { $0 + Double($1.samples) / Double($1.sampleRate) }, language: job.language)
            } else { jobs[active]?.published = job.streamChunks.count + 1 }
            workerDeadline = Date().addingTimeInterval(120)
        case "audio":
            guard let active, event.id == active, let path = generatingPath, event.path == path.path else {
                workerFailed("Unexpected audio response from Qwen"); return
            }
            if jobs[active]?.output != "playback", !audioWithinLimit(active) {
                failActive("Generated audio exceeds storage limit"); return
            }
            jobs[active]?.generated += 1
            if jobs[active]?.output != "stream" { prepared.append(path) }
            generatingPath = nil
            workerDeadline = nil
            pump()
        case "error", "exit":
            if event.retryable == true, let active, jobs[active]?.silenceRetries == 0, let path = generatingPath {
                // Retry the same passage once in a fresh worker, without cutting off valid playback.
                jobs[active]?.silenceRetries += 1
                Logger.warn("Narration retrying silent audio id=\(active)")
                stopWorker()
                try? FileManager.default.removeItem(at: path)
                generatingPath = nil
                startWorker()
            } else {
                workerFailed(event.error ?? "Qwen worker failed")
            }
        default: workerFailed("Unknown response from Qwen worker")
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player, let id = self.active else { return }
            self.player = nil
            if let path = self.playingPath { try? FileManager.default.removeItem(at: path) }
            self.playingPath = nil
            if flag { self.jobs[id]?.played += 1; self.pump() }
            else { self.failActive("Audio playback failed") }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.failActive("Audio decoding failed")
        }
    }

    private func stopWorker() {
        let old = worker
        worker = nil
        workerReady = false
        workerDeadline = nil
        old?.stop()
        warmupAttempted = false
    }

    private func timingEvent(_ workerID: UUID, _ event: NarrationTimingEvent) {
        guard timingWorker?.id == workerID else { return }
        if let error = event.error {
            Logger.error("Narration recognition failure: \(error)")
            timingWorker?.stop()
            timingWorker = nil
            timingDeadline = nil
            if let active, jobs[active]?.timed == true { failActive(error) }
            return
        }
        guard let active, event.id == active, let job = jobs[active],
              let index = event.chunk, index == job.published, index < job.streamChunks.count,
              let words = event.words else { failActive("Unexpected narration timing response"); return }
        let duration = job.streamChunks.prefix(index + 1).reduce(0) { $0 + Double($1.samples) / Double($1.sampleRate) }
        var last = job.streamChunks.prefix(index).compactMap { $0.words?.last?.start }.last ?? 0
        for word in words {
            guard word.location >= 0, word.length > 0, word.location <= job.sourceLength - word.length,
                  word.start.isFinite, word.end.isFinite, word.start >= last,
                  word.end >= word.start, word.end <= duration + 0.001 else {
                failActive("Invalid narration word timing"); return
            }
            last = word.start
        }
        jobs[active]?.streamChunks[index].words = words
        jobs[active]?.published += 1
        timingDeadline = index + 1 < job.streamChunks.count ? Date().addingTimeInterval(120) : nil
        pump()
    }

    private func clearPlayback() {
        timingWorker?.stop()
        timingWorker = nil
        timingDeadline = nil
        player?.stop()
        player = nil
        // Remove the job directory too, so a cancelled worker cannot publish late audio.
        let directories = Set((prepared + [playingPath, generatingPath].compactMap({ $0 })).map { $0.deletingLastPathComponent() })
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
        prepared = []
        playingPath = nil
        generatingPath = nil
    }

    private func workerFailed(_ message: String) {
        Logger.error("Narration worker failure: \(message)")
        stopWorker()
        warmupAttempted = true // Retry on the next request, not every timer tick.
        // Do not repeatedly reload a broken model for every queued request.
        let affected = pending + [active].compactMap { $0 }
        showFailure(message)
        for id in affected { jobs[id]?.state = "failed"; jobs[id]?.error = message; jobs[id]?.chunks = [] }
        pending = []
        active = nil
        clearPlayback()
    }

    private func failActive(_ message: String) {
        guard let id = active else { return }
        Logger.error("Narration failed id=\(id): \(message)")
        if generatingPath != nil { stopWorker() }
        showFailure(message)
        clearPlayback()
        jobs[id]?.state = "failed"
        jobs[id]?.error = message
        jobs[id]?.chunks = []
        active = nil
        pump()
    }

    private func showFailure(_ message: String) {
        guard let active, jobs[active]?.isSelection == true else { return }
        onSelectionFailure(message)
    }

    func audioResponse(_ id: String) -> NarrationHTTPResponse {
        expireAudio()
        guard let job = jobs[id], job.output == "audio", job.state == "completed", job.audioExpires != nil else {
            return .error(404, "Audio is not ready or has expired")
        }
        do {
            return NarrationHTTPResponse(status: 200, body: try Data(contentsOf: audioDirectory.appendingPathComponent(id).appendingPathComponent("audio.wav")), contentType: "audio/wav")
        } catch { return .error(500, "Could not read generated audio") }
    }

    func pieceResponse(_ id: String, index: Int) -> NarrationHTTPResponse {
        expireAudio()
        guard let job = jobs[id], job.output == "pieces", index >= 0, index < job.generated,
              ["generating", "completed"].contains(job.state),
              job.state != "completed" || job.audioExpires != nil else {
            return .error(404, "Audio piece is not ready or has expired")
        }
        do {
            return NarrationHTTPResponse(status: 200, body: try Data(contentsOf: audioDirectory.appendingPathComponent(id).appendingPathComponent("\(index).wav")), contentType: "audio/wav")
        } catch { return .error(500, "Could not read generated audio piece") }
    }

    func streamResponse(_ id: String, index: Int) -> NarrationHTTPResponse {
        expireAudio()
        guard let job = jobs[id], job.output == "stream", index >= 0, index < job.published,
              ["generating", "completed"].contains(job.state),
              job.state != "completed" || job.audioExpires != nil else {
            return .error(404, "Audio chunk is not ready or has expired")
        }
        do {
            return NarrationHTTPResponse(status: 200, body: try Data(contentsOf: job.streamChunks[index].path), contentType: "application/octet-stream")
        } catch { return .error(500, "Could not read streaming audio") }
    }

    private func audioWithinLimit(_ id: String) -> Bool {
        // Bound both a single export and all retained exports, including pending audio.
        var total = 0, jobTotal = 0
        guard let files = FileManager.default.enumerator(at: audioDirectory, includingPropertiesForKeys: [.fileSizeKey]) else { return false }
        for case let file as URL in files where ["wav", "pcm"].contains(file.pathExtension) {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += size
            if file.deletingLastPathComponent().lastPathComponent == id { jobTotal += size }
        }
        return jobTotal <= 32 * 1024 * 1024 && total <= 128 * 1024 * 1024
    }

    private func expireAudio() {
        for (id, job) in jobs where job.audioExpires.map({ $0 <= Date() }) == true {
            removeAudio(id)
        }
    }

    private func removeAudio(_ id: String) {
        try? FileManager.default.removeItem(at: audioDirectory.appendingPathComponent(id))
        jobs[id]?.audioExpires = nil
    }

    private func cancel(_ id: String) {
        if jobs[id]?.audioExpires != nil { removeAudio(id) }

        guard pending.contains(id) || active == id else { return }
        pending.removeAll { $0 == id }
        if active == id {
            if generatingPath != nil || !workerReady { stopWorker() }
            clearPlayback()
            active = nil
        }
        jobs[id]?.state = "cancelled"
        jobs[id]?.chunks = []
        pump()
    }

    func stopAll() {
        let affected = pending + [active].compactMap { $0 }
        pending = []
        for id in affected { jobs[id]?.state = "cancelled"; jobs[id]?.chunks = [] }
        active = nil
        if generatingPath != nil || !workerReady { stopWorker() }
        clearPlayback()
    }

    private func pruneHistory() {
        while order.count > 100 {
            guard let index = order.firstIndex(where: { $0 != active && !pending.contains($0) }) else { break }
            let id = order.remove(at: index)
            removeAudio(id)
            jobs.removeValue(forKey: id)
        }
    }

    func shutdown() {
        shuttingDown = true
        server.stop()
        timer?.invalidate()
        timer = nil
        stopAll()
        stopWorker()
        try? FileManager.default.removeItem(at: audioDirectory)
    }
}
