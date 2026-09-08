@preconcurrency import AVFoundation
import Darwin
import Foundation

struct WhisperWord: Decodable {
    let word: String
    let start: Float
    let end: Float
    let probability: Float?
}

struct WhisperSegment: Decodable {
    let id: Int?
    let text: String
    let start: Float
    let end: Float
    let words: [WhisperWord]?
}

struct WhisperTranscription: Decodable {
    let task: String?
    let language: String?
    var duration: Float?
    let text: String
    var segments: [WhisperSegment]
}

func decodedWhisperText(_ transcription: WhisperTranscription) -> String {
    let pieces = transcription.segments.flatMap { segment in
        segment.words?.map(\.word) ?? []
    }
    if pieces.isEmpty {
        return transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return pieces.joined().trimmingCharacters(in: .whitespacesAndNewlines)
}

final class SampleQueue {
    private let condition = NSCondition()
    private let capacity: Int
    private var chunks: [[Float]] = []
    private var closed = false

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func send(_ chunk: [Float], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while chunks.count >= capacity && !closed {
            if !condition.wait(until: deadline) {
                return false
            }
        }
        if closed {
            return false
        }
        chunks.append(chunk)
        condition.signal()
        return true
    }

    func receive() -> [Float]? {
        condition.lock()
        defer { condition.unlock() }
        while chunks.isEmpty && !closed {
            condition.wait()
        }
        if chunks.isEmpty && closed {
            return nil
        }
        let chunk = chunks.removeFirst()
        condition.signal()
        return chunk
    }

    func drain() -> [[Float]] {
        condition.lock()
        defer { condition.unlock() }
        let drained = chunks
        chunks.removeAll(keepingCapacity: true)
        condition.broadcast()
        return drained
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }
}

extension SampleQueue: @unchecked Sendable {}

final class TranscriberService {
    static let defaultSampleRate = 16_000
    private let chunkDurationMs = 10
    private let audioBufferSeconds = 10
    private let silencePadding: TimeInterval = 0.1
    private var segmentationConfig = SegmentationConfig.default
    private var segmentation: SegmentationConfig {
        stateLock.lock()
        defer { stateLock.unlock() }
        return segmentationConfig
    }
    private let whisperPort = 65_461
    private let whisperStartupTimeout: TimeInterval = 180

    private let stateLock = NSLock()
    private let taskLock = NSLock()
    private let statusLock = NSLock()
    private var stableText = ""
    private var stableRunes = 0
    private var pendingText = ""
    private var systemPrompt = ""
    /// Called with the absolute time of every cut. Used by the replay tool.
    var cutHandler: (@Sendable (Double, SegmentCut) -> Void)?
    private var language = "en"
    private var isStopping = false
    private var generation = 0
    private var statusHandler: (@Sendable (String) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var captureSession: AVCaptureSession?
    private var captureDelegate: AudioCaptureDelegate?
    private var sampleQueue: SampleQueue?
    private var captureQueue = DispatchQueue(label: "pa3.audio.capture")
    private var workerThread: Thread?
    private var currentTask: URLSessionDataTask?
    private var ownedWhisperProcess: Process?
    private var ownedWhisperOutputPipes: [Pipe] = []
    private var timestamp = ""
    private var sampleRate = defaultSampleRate
    private let startupLock = NSLock()
    private var startupStarted = false
    private let debugLock = NSLock()
    private var tapCallbacks = 0
    private var queuedChunks = 0
    private var workerChunks = 0
    private var skipWhisper = false

    init() {
    }

    func warmUp() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = self?.ensureWhisperServerStarted()
        }
    }

    /// How many complete sentences stay in the audio buffer as context for Whisper. Applies from the next round.
    func setKeepSentences(_ count: Int) {
        stateLock.lock()
        segmentationConfig.keepSentences = max(0, count)
        stateLock.unlock()
    }

    func setSystemPrompt(_ prompt: String) {
        stateLock.lock()
        systemPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        stateLock.unlock()
    }

    func setLanguage(_ value: String) {
        stateLock.lock()
        language = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        stateLock.unlock()
    }

    func setStatusHandler(_ handler: (@Sendable (String) -> Void)?) {
        statusLock.lock()
        statusHandler = handler
        statusLock.unlock()
    }

    func stablePrefixRunes() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stableRunes
    }

    func startTranscribe(sendTo receiver: @escaping @Sendable (String) -> Void, skipWhisper: Bool = false) {
        Logger.info("TranscriberService.startTranscribe")
        stopTranscribe()

        stateLock.lock()
        generation += 1
        let startGeneration = generation
        stableText = ""
        stableRunes = 0
        pendingText = ""
        isStopping = false
        self.skipWhisper = skipWhisper
        stateLock.unlock()
        debugLock.lock()
        tapCallbacks = 0
        queuedChunks = 0
        workerChunks = 0
        debugLock.unlock()

        timestamp = Self.recordingTimestamp()
        if skipWhisper {
            startCaptureAndWorker(receiver: receiver)
            return
        }
        reportStatus("Starting Whisper...")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            guard self.ensureWhisperServerStarted(generation: startGeneration) else {
                Logger.warn("Whisper startup did not complete for generation \(startGeneration)")
                return
            }
            guard self.shouldContinue(generation: startGeneration) else {
                Logger.info("Skipping capture start for stale generation \(startGeneration)")
                return
            }
            self.startCaptureAndWorker(receiver: receiver)
        }
    }

    func stopTranscribe() {
        Logger.info("TranscriberService.stopTranscribe")
        stateLock.lock()
        isStopping = true
        generation += 1
        stateLock.unlock()

        taskLock.lock()
        currentTask?.cancel()
        currentTask = nil
        taskLock.unlock()

        sampleQueue?.close()
        workerThread?.cancel()
        let deadline = Date().addingTimeInterval(0.5)
        while workerThread?.isExecuting == true && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if workerThread?.isExecuting == true {
            Logger.warn("transcription worker still exiting; stopTranscribe continuing")
        }
        workerThread = nil
        sampleQueue = nil

        if let session = captureSession {
            DispatchQueue.global(qos: .utility).async {
                session.stopRunning()
            }
            captureSession = nil
            captureDelegate = nil
        }

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }
    }

    func close() {
        stopTranscribe()
        stopOwnedWhisperServer()
    }

    private func startCaptureAndWorker(receiver: @escaping @Sendable (String) -> Void) {
        Logger.info("startCaptureAndWorker")
        let permission = AVCaptureDevice.authorizationStatus(for: .audio)
        if permission == .denied || permission == .restricted {
            Logger.error("Microphone permission denied or restricted")
            return
        }
        if permission == .notDetermined {
            Logger.info("Requesting microphone permission")
            let semaphore = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Logger.info("Microphone permission granted=\(granted)")
                semaphore.signal()
            }
            semaphore.wait()
            if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                Logger.error("Microphone permission not authorized after request")
                return
            }
        }

        // The microphone may deliver any rate, and it can change mid-session. Everything past this point runs at 16 kHz.
        sampleRate = Self.defaultSampleRate
        let resampler = Resampler(outputRate: Double(sampleRate))
        let framesPerBuffer = max(1, Int(round(Double(sampleRate * chunkDurationMs) / 1000.0)))
        let chunksPerSecond = max(1, Int(ceil(Double(sampleRate) / Double(framesPerBuffer))))
        let queue = SampleQueue(capacity: max(32, chunksPerSecond * audioBufferSeconds))
        sampleQueue = queue

        guard let device = AVCaptureDevice.default(for: .audio) else {
            Logger.error("No default audio capture device")
            return
        }
        let session = AVCaptureSession()
        session.beginConfiguration()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            } else {
                Logger.error("Cannot add audio capture input")
                session.commitConfiguration()
                return
            }
        } catch {
            Logger.error("Failed to create audio capture input: \(error)")
            session.commitConfiguration()
            return
        }

        let output = AVCaptureAudioDataOutput()
        let delegate = AudioCaptureDelegate { [weak self, weak queue] samples, rate in
            guard let self, let queue else { return }
            self.noteTapCallback(frames: samples.count)
            self.captureQueue.async {
                let samples = resampler.process(samples, inputRate: rate)
                if samples.isEmpty {
                    return
                }
                if !queue.send(samples, timeout: 0.25) {
                    Logger.warn("Dropping audio frame; consumer behind")
                } else {
                    self.noteQueuedChunk(samples: samples.count)
                }
            }
        }
        output.setSampleBufferDelegate(delegate, queue: DispatchQueue(label: "pa3.avcapture.audio"))
        if session.canAddOutput(output) {
            session.addOutput(output)
        } else {
            Logger.error("Cannot add audio capture output")
            session.commitConfiguration()
            return
        }
        session.commitConfiguration()
        captureSession = session
        captureDelegate = delegate
        Logger.info("AVCaptureSession configured")

        let thread = Thread { [weak self, weak queue] in
            guard let self, let queue else { return }
            Logger.info("transcription worker started")
            self.transcribeLoop(queue: queue, timestamp: self.timestamp, sampleRate: self.sampleRate, receiver: receiver)
        }
        thread.name = "pa3.transcription.worker"
        workerThread = thread
        thread.start()

        session.startRunning()
        Logger.info("AVCaptureSession started")
    }

    private func monoSamples(from buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat?) -> [Float] {
        var source = buffer
        if let targetFormat, buffer.format.channelCount != 1 || abs(buffer.format.sampleRate - targetFormat.sampleRate) > 0.5 {
            guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat),
                  let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate + 16)) else {
                return []
            }
            var error: NSError?
            let provider = ConverterInputProvider(buffer: buffer)
            converter.convert(to: converted, error: &error) { _, status in
                provider.next(status: status)
            }
            if let error {
                Logger.warn("Audio conversion failed: \(error)")
                return []
            }
            source = converted
        }

        guard let channelData = source.floatChannelData else {
            return []
        }
        let frames = Int(source.frameLength)
        let channels = Int(source.format.channelCount)
        if channels <= 1 {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frames))
        }
        var result = [Float](repeating: 0, count: frames)
        for channel in 0..<channels {
            let pointer = channelData[channel]
            for i in 0..<frames {
                result[i] += pointer[i] / Float(channels)
            }
        }
        return result
    }

    private func transcribeLoop(queue: SampleQueue, timestamp: String, sampleRate: Int, record: Bool = true, receiver: @escaping @Sendable (String) -> Void) {
        var audio: [Float] = []
        audio.reserveCapacity(sampleRate * 300)
        var consumedSamples = 0
        let recorder = (skipWhisper || !record) ? nil : SessionRecorder(directory: recordingDirectory(), timestamp: timestamp, sampleRate: sampleRate)
        defer { recorder?.close() }

        var newAudio = false
        var lastRequestStart = Date.distantPast
        var threshold = segmentation.minThreshold
        let maxTrailingSilence = Int(segmentation.maxTrailingSilence * Double(sampleRate))

        while !Thread.current.isCancelled {
            guard let chunk = queue.receive() else {
                Logger.info("transcription worker queue closed")
                if newAudio, !skipWhisper, audio.count > sampleRate / 2 {
                    // Replay ends here. A live session is already stopping, so this request is refused and costs nothing.
                    _ = transcribeSlice(samples: audio, offsetSamples: consumedSamples, sampleRate: sampleRate, receiver: receiver)
                }
                break
            }
            noteWorkerChunk(samples: chunk.count)
            for piece in [chunk] + queue.drain() {
                recorder?.append(piece)
                if skipWhisper {
                    continue
                }
                // Once the buffer already ends in a second of silence, more silence adds nothing. Drop it so a pause
                // cannot grow the buffer, and so the tail of the last sentence stays close to the end of the audio.
                if audio.count >= maxTrailingSilence,
                   isQuiet(audio[(audio.count - maxTrailingSilence)...], threshold: threshold),
                   isQuiet(piece[...], threshold: threshold) {
                    consumedSamples += piece.count
                    continue
                }
                audio.append(contentsOf: piece)
                newAudio = true
            }

            if skipWhisper {
                if audio.count > sampleRate {
                    audio.removeAll(keepingCapacity: true)
                }
                continue
            }
            // One round per interval, counted from the start of the previous round. The loop is sequential, so a round
            // that runs longer than the interval simply delays the next one until it is done.
            guard audio.count > sampleRate, newAudio,
                  Date().timeIntervalSince(lastRequestStart) >= segmentation.minRequestInterval else {
                continue
            }
            newAudio = false
            lastRequestStart = Date()
            let result = transcribeSlice(samples: audio, offsetSamples: consumedSamples, sampleRate: sampleRate, receiver: receiver)
            threshold = result.threshold
            if result.trim > 0 {
                let count = min(result.trim, audio.count)
                audio.removeFirst(count)
                consumedSamples += count
            }
        }
        Logger.info("transcription worker exiting")
    }

    private func noteTapCallback(frames: Int) {
        debugLock.lock()
        tapCallbacks += 1
        let count = tapCallbacks
        debugLock.unlock()
        if count == 1 || count % 100 == 0 {
            Logger.info("audio tap callback count=\(count) frames=\(frames)")
        }
    }

    private func noteQueuedChunk(samples: Int) {
        debugLock.lock()
        queuedChunks += 1
        let count = queuedChunks
        debugLock.unlock()
        if count == 1 || count % 100 == 0 {
            Logger.info("queued audio chunk count=\(count) samples=\(samples)")
        }
    }

    private func noteWorkerChunk(samples: Int) {
        debugLock.lock()
        workerChunks += 1
        let count = workerChunks
        debugLock.unlock()
        if count == 1 || count % 100 == 0 {
            Logger.info("worker chunk count=\(count) samples=\(samples)")
        }
    }

    func debugSnapshot() -> (tapCallbacks: Int, queuedChunks: Int, workerChunks: Int) {
        debugLock.lock()
        defer { debugLock.unlock() }
        return (tapCallbacks, queuedChunks, workerChunks)
    }

    /// Sends the buffer to Whisper and commits whatever can be cut.
    /// Returns how many samples to drop from the front and the speech threshold measured on this buffer.
    private func transcribeSlice(samples: [Float], offsetSamples: Int, sampleRate: Int, receiver: @escaping @Sendable (String) -> Void) -> (trim: Int, threshold: Float) {
        let segmentation = self.segmentation
        let energies = frameEnergies(samples: samples, sampleRate: sampleRate, frameSeconds: segmentation.frameSeconds)
        let threshold = speechThreshold(energies: energies, config: segmentation)
        guard ensureWhisperServerStarted() else {
            return (0, threshold)
        }
        if !energies.contains(where: { $0 >= threshold }) {
            // Nothing to hear. Keep a little context and skip the request so Whisper cannot invent words from silence.
            let keep = Int(segmentation.searchWindow * Double(sampleRate))
            return (max(0, samples.count - keep), threshold)
        }
        let paddingSamples = max(0, Int(round(Double(sampleRate) * silencePadding)))
        let padded = [Float](repeating: 0, count: paddingSamples) + samples
        let wav = WAVEncoder.encode(samples: padded, sampleRate: sampleRate)

        guard let transcription = requestTranscription(wav: wav) else {
            return (0, threshold)
        }
        let tokens = timedTokens(transcription, offset: silencePadding)
        let quiet = quietRuns(energies: energies, threshold: threshold, config: segmentation)
        let duration = Double(samples.count) / Double(sampleRate)
        var cut = chooseCut(tokens: tokens, quiet: quiet, duration: duration, config: segmentation)
        if let candidate = cut {
            // Whisper's word times are too rough to trust a cut on their own. Transcribe the audio before the cut by itself:
            // that text is what really lies before the cut, whatever the timestamps said.
            let cutSamples = Int(round(candidate.time * Double(sampleRate)))
            let head = [Float](repeating: 0, count: paddingSamples) + samples[..<cutSamples]
            if let headTranscription = requestTranscription(wav: WAVEncoder.encode(samples: head, sampleRate: sampleRate)) {
                let headTokens = timedTokens(headTranscription, offset: silencePadding).map(\.text)
                cut = confirmCut(candidate, headTokens: headTokens, allTokens: tokens.map(\.text))
                if cut == nil {
                    Logger.info("cut at \(String(format: "%.2f", candidate.time))s rejected: head says \(String(reflecting: buildText(headTokens))) expected \(String(reflecting: buildText(candidate.committed)))")
                }
            } else {
                cut = nil
            }
        }

        stateLock.lock()
        if let cut {
            stableText = appendText(stableText, buildText(cut.committed))
            pendingText = buildText(cut.pending)
        } else {
            pendingText = buildText(tokens.map(\.text))
        }
        let joined = joinText(stableText, pendingText)
        stableRunes = joined.stableRunes
        stateLock.unlock()

        if let cut {
            let absolute = Double(offsetSamples) / Double(sampleRate) + cut.time
            Logger.info("cut at \(String(format: "%.2f", absolute))s reason=\(cut.reason) committed=\(String(reflecting: buildText(cut.committed))) pending=\(String(reflecting: buildText(cut.pending)))")
            cutHandler?(absolute, cut)
        }
        let text = joined.text
        Logger.info("Received Whisper transcription duration=\(String(format: "%.2f", duration)) text=\(String(reflecting: buildText(tokens.map(\.text))))")
        reportStatus("Dictation active")
        DispatchQueue.main.async {
            receiver(text)
        }
        guard let cut else {
            return (0, threshold)
        }
        return (Int(round(cut.time * Double(sampleRate))), threshold)
    }

    private func requestTranscription(wav: Data) -> WhisperTranscription? {
        guard let url = URL(string: "http://127.0.0.1:\(whisperPort)/inference") else {
            return nil
        }

        let boundary = "pa3-\(UUID().uuidString)"
        var body = Data()
        func addField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"file.wav\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        body.append("\r\n")
        addField("response_format", "verbose_json")
        addField("temperature", "0.0")
        addField("temperature_inc", "0.2")

        stateLock.lock()
        let prompt = systemPrompt
        let currentLanguage = language
        let stopping = isStopping
        stateLock.unlock()
        if stopping {
            return nil
        }
        if !prompt.isEmpty {
            addField("prompt", prompt)
        }
        if !currentLanguage.isEmpty {
            addField("language", currentLanguage)
        }
        addField("translate", "false")
        body.append("--\(boundary)--\r\n")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        Logger.info("Sending Whisper request bytes=\(body.count)")
        reportStatus("Transcribing...")

        let syncTask = SyncHTTP.dataTask(for: request)
        let task = syncTask.task
        taskLock.lock()
        currentTask = task
        taskLock.unlock()
        task.resume()
        let result = syncTask.wait()
        taskLock.lock()
        if currentTask === task {
            currentTask = nil
        }
        taskLock.unlock()

        if let error = result.error {
            Logger.warn("HTTP request failed: \(error)")
            return nil
        }
        guard result.statusCode == 200, let responseData = result.data else {
            Logger.warn("Whisper server responded with status \(result.statusCode)")
            return nil
        }
        do {
            return try JSONDecoder().decode(WhisperTranscription.self, from: responseData)
        } catch {
            Logger.warn("Failed to decode whisper response: \(error)")
            return nil
        }
    }

    func debugTranscribeWAV(_ wav: Data) -> String {
        guard ensureWhisperServerStarted(), let transcription = requestTranscription(wav: wav) else {
            return ""
        }
        return decodedWhisperText(transcription)
    }

    /// Feeds prerecorded audio through the same worker the microphone uses, paced at `speed` times real time.
    /// Returns once the worker has processed everything.
    func replay(samples: [Float], sampleRate: Int, speed: Double, receiver: @escaping @Sendable (String) -> Void) {
        stopTranscribe()
        stateLock.lock()
        generation += 1
        stableText = ""
        stableRunes = 0
        pendingText = ""
        isStopping = false
        skipWhisper = false
        stateLock.unlock()
        self.sampleRate = sampleRate

        let framesPerChunk = max(1, Int(round(Double(sampleRate * chunkDurationMs) / 1000.0)))
        let queue = SampleQueue(capacity: max(32, (sampleRate / framesPerChunk) * audioBufferSeconds))
        sampleQueue = queue
        let thread = Thread { [weak self, weak queue] in
            guard let self, let queue else { return }
            self.transcribeLoop(queue: queue, timestamp: "replay", sampleRate: sampleRate, record: false, receiver: receiver)
        }
        thread.name = "pa3.transcription.replay"
        workerThread = thread
        thread.start()

        let chunkInterval = Double(chunkDurationMs) / 1000.0 / max(0.01, speed)
        let started = Date()
        var index = 0
        var sent = 0
        while index < samples.count {
            let end = min(samples.count, index + framesPerChunk)
            _ = queue.send(Array(samples[index..<end]), timeout: 60)
            index = end
            sent += 1
            let due = started.addingTimeInterval(Double(sent) * chunkInterval)
            let wait = due.timeIntervalSinceNow
            if wait > 0 {
                Thread.sleep(forTimeInterval: wait)
            }
        }
        queue.close()
        while thread.isExecuting {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        workerThread = nil
        sampleQueue = nil
    }

    func currentText() -> (stable: String, pending: String) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (stableText, pendingText)
    }


    private func startWhisperServer(generation: Int? = nil) -> Bool {
        if isWhisperPortOpen() {
            Logger.info("Whisper server is already reachable on port \(whisperPort)")
            reportStatus("Whisper ready")
            return true
        }
        reportStatus("Starting Whisper...")
        if let generation, !shouldContinue(generation: generation) {
            return false
        }

        let installDir = appResourceDirectory()
        let buildDir = installDir.appendingPathComponent("whisper.cpp/build")
        let server = buildDir.appendingPathComponent("bin/whisper-server")
        let model = installDir.appendingPathComponent("models/whisper.ggml")
        let args = ["-m", model.path, "--port", "\(whisperPort)"]

        let process = Process()
        process.executableURL = server
        process.currentDirectoryURL = installDir.appendingPathComponent("whisper.cpp")
        process.arguments = args
        let libraryPaths = [
            buildDir.appendingPathComponent("src").path,
            buildDir.appendingPathComponent("ggml/src").path,
            buildDir.appendingPathComponent("ggml/src/ggml-blas").path,
            buildDir.appendingPathComponent("ggml/src/ggml-metal").path
        ]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "DYLD_LIBRARY_PATH": libraryPaths.joined(separator: ":")
        ]) { _, new in new }
        let outputPipes = attachWhisperLogging(to: process)
        process.terminationHandler = { process in
            Logger.warn("whisper-server pid \(process.processIdentifier) exited status \(process.terminationStatus)")
        }
        do {
            try process.run()
            taskLock.lock()
            ownedWhisperProcess = process
            ownedWhisperOutputPipes = outputPipes
            taskLock.unlock()
            Logger.info("Started whisper-server pid \(process.processIdentifier)")
        } catch {
            Logger.error("Failed to start whisper-server: \(error)")
            reportStatus("Whisper failed to start")
            return false
        }
        return waitForWhisperServer(timeout: whisperStartupTimeout, generation: generation)
    }

    private func ensureWhisperServerStarted(generation: Int? = nil) -> Bool {
        startupLock.lock()
        if startupStarted {
            startupLock.unlock()
            if !isWhisperPortOpen() {
                reportStatus("Waiting for Whisper...")
                return waitForWhisperServer(timeout: whisperStartupTimeout, generation: generation)
            }
            reportStatus("Whisper ready")
            return true
        }
        startupStarted = true
        startupLock.unlock()
        return startWhisperServer(generation: generation)
    }

    private func waitForWhisperServer(timeout: TimeInterval, generation: Int? = nil) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var lastReport = Date.distantPast
        while Date() < deadline {
            if let generation, !shouldContinue(generation: generation) {
                Logger.info("Whisper startup cancelled for generation \(generation)")
                reportStatus("Dictation stopped")
                return false
            }
            if isWhisperPortOpen() {
                reportStatus("Whisper ready")
                return true
            }
            if Date().timeIntervalSince(lastReport) >= 1 {
                let remaining = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
                reportStatus("Starting Whisper... \(remaining)s")
                lastReport = Date()
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        Logger.warn("Whisper server did not become ready")
        reportStatus("Whisper not ready")
        return false
    }

    private func reportStatus(_ message: String) {
        Logger.info("transcriber status=\(message)")
        statusLock.lock()
        let handler = statusHandler
        statusLock.unlock()
        handler?(message)
    }

    private func shouldContinue(generation expectedGeneration: Int) -> Bool {
        stateLock.lock()
        let active = !isStopping && generation == expectedGeneration
        stateLock.unlock()
        return active
    }

    private func stopOwnedWhisperServer() {
        taskLock.lock()
        let process = ownedWhisperProcess
        ownedWhisperProcess = nil
        taskLock.unlock()
        guard let process, process.isRunning else {
            return
        }
        Logger.info("Terminating owned whisper-server pid \(process.processIdentifier)")
        process.terminate()
        let deadline = Date().addingTimeInterval(2.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            Logger.warn("owned whisper-server did not terminate promptly; interrupting")
            process.interrupt()
        }
        taskLock.lock()
        for pipe in ownedWhisperOutputPipes {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        ownedWhisperOutputPipes.removeAll()
        taskLock.unlock()
    }

    private func attachWhisperLogging(to process: Process) -> [Pipe] {
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        logWhisperOutput(stdout, prefix: "whisper-server stdout")
        logWhisperOutput(stderr, prefix: "whisper-server stderr")
        return [stdout, stderr]
    }

    private func logWhisperOutput(_ pipe: Pipe, prefix: String) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(whereSeparator: \.isNewline) {
                Logger.info("\(prefix): \(line)")
            }
        }
    }

    private func isWhisperPortOpen() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 {
            return false
        }
        defer { Darwin.close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(whisperPort).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        return withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private static func recordingTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter.string(from: Date())
    }
}

extension TranscriberService: @unchecked Sendable {}

final class ConverterInputProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var didProvide = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        if didProvide {
            status.pointee = .noDataNow
            return nil
        }
        didProvide = true
        status.pointee = .haveData
        return buffer
    }
}

private final class AudioCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let onSamples: @Sendable ([Float], Double) -> Void

    init(onSamples: @escaping @Sendable ([Float], Double) -> Void) {
        self.onSamples = onSamples
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return
        }
        let asbd = asbdPointer.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else {
            Logger.warn("Unsupported audio format id=\(asbd.mFormatID)")
            return
        }

        var bufferListSize = 0
        var blockBuffer: CMBlockBuffer?
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, bufferListSize > 0 else {
            Logger.warn("Failed to size audio buffer list status=\(status)")
            return
        }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: bufferListSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let audioBufferList = raw.assumingMemoryBound(to: AudioBufferList.self)
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: bufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            Logger.warn("Failed to read audio buffer list status=\(status)")
            return
        }

        let samples = Self.floatSamples(from: audioBufferList, asbd: asbd, sampleCount: CMSampleBufferGetNumSamples(sampleBuffer))
        if !samples.isEmpty {
            onSamples(samples, asbd.mSampleRate)
        }
    }

    private static func floatSamples(from audioBufferList: UnsafeMutablePointer<AudioBufferList>, asbd: AudioStreamBasicDescription, sampleCount: Int) -> [Float] {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let bits = Int(asbd.mBitsPerChannel)
        let flags = asbd.mFormatFlags
        let isFloat = (flags & kAudioFormatFlagIsFloat) != 0
        let isSignedInteger = (flags & kAudioFormatFlagIsSignedInteger) != 0
        let isNonInterleaved = (flags & kAudioFormatFlagIsNonInterleaved) != 0

        guard sampleCount > 0 else {
            return []
        }

        var result = [Float](repeating: 0, count: sampleCount)
        if isNonInterleaved {
            let channelCount = min(channels, buffers.count)
            guard channelCount > 0 else { return [] }
            for channel in 0..<channelCount {
                addChannel(buffer: buffers[channel], to: &result, sampleCount: sampleCount, bits: bits, isFloat: isFloat, isSignedInteger: isSignedInteger, stride: 1, channelOffset: 0, divisor: Float(channelCount))
            }
            return result
        }

        guard let first = buffers.first else {
            return []
        }
        for channel in 0..<channels {
            addChannel(buffer: first, to: &result, sampleCount: sampleCount, bits: bits, isFloat: isFloat, isSignedInteger: isSignedInteger, stride: channels, channelOffset: channel, divisor: Float(channels))
        }
        return result
    }

    private static func addChannel(buffer: AudioBuffer, to result: inout [Float], sampleCount: Int, bits: Int, isFloat: Bool, isSignedInteger: Bool, stride: Int, channelOffset: Int, divisor: Float) {
        guard let data = buffer.mData else {
            return
        }
        if isFloat, bits == 32 {
            let pointer = data.assumingMemoryBound(to: Float.self)
            for i in 0..<sampleCount {
                result[i] += pointer[i * stride + channelOffset] / divisor
            }
            return
        }
        if isSignedInteger, bits == 16 {
            let pointer = data.assumingMemoryBound(to: Int16.self)
            for i in 0..<sampleCount {
                result[i] += Float(pointer[i * stride + channelOffset]) / 32768.0 / divisor
            }
            return
        }
        if isSignedInteger, bits == 32 {
            let pointer = data.assumingMemoryBound(to: Int32.self)
            for i in 0..<sampleCount {
                result[i] += Float(pointer[i * stride + channelOffset]) / 2_147_483_648.0 / divisor
            }
            return
        }
        Logger.warn("Unsupported PCM format bits=\(bits) isFloat=\(isFloat) isSignedInteger=\(isSignedInteger)")
    }
}

/// Appends every captured sample of one capture run to `rec/<timestamp>.wav`.
/// The header sizes are patched after each write so the file stays playable if the app dies.
final class SessionRecorder {
    private var handle: FileHandle?
    private var sampleCount = 0
    private let sampleRate: Int

    init?(directory: URL, timestamp: String, sampleRate: Int) {
        self.sampleRate = sampleRate
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(timestamp).wav")
        guard FileManager.default.createFile(atPath: file.path, contents: WAVEncoder.header(sampleCount: 0, sampleRate: sampleRate)),
              let handle = try? FileHandle(forWritingTo: file) else {
            Logger.warn("Failed to open session recording \(file.path)")
            return nil
        }
        self.handle = handle
        _ = try? handle.seekToEnd()
    }

    func append(_ samples: [Float]) {
        guard let handle, !samples.isEmpty else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: WAVEncoder.pcm(samples: samples))
            sampleCount += samples.count
            let header = WAVEncoder.header(sampleCount: sampleCount, sampleRate: sampleRate)
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: header[4..<8])
            try handle.seek(toOffset: 40)
            try handle.write(contentsOf: header[40..<44])
        } catch {
            Logger.warn("Session recording write failed: \(error)")
            close()
        }
    }

    func close() {
        guard let handle else { return }
        try? handle.close()
        self.handle = nil
        Logger.info("session recording closed samples=\(sampleCount)")
    }
}

enum WAVEncoder {
    static func encode(samples: [Float], sampleRate: Int) -> Data {
        var data = header(sampleCount: samples.count, sampleRate: sampleRate)
        data.append(pcm(samples: samples))
        return data
    }

    static func pcm(samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let value = Int16(clamped * 32767)
            data.append(value.littleEndianData)
        }
        return data
    }

    static func header(sampleCount: Int, sampleRate: Int) -> Data {
        var data = Data()
        let bytesPerSample = 2
        let subchunk2Size = sampleCount * bytesPerSample
        let chunkSize = 36 + subchunk2Size

        data.append("RIFF".data(using: .ascii)!)
        data.append(UInt32(chunkSize).littleEndianData)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(UInt32(16).littleEndianData)
        data.append(UInt16(1).littleEndianData)
        data.append(UInt16(1).littleEndianData)
        data.append(UInt32(sampleRate).littleEndianData)
        data.append(UInt32(sampleRate * bytesPerSample).littleEndianData)
        data.append(UInt16(bytesPerSample).littleEndianData)
        data.append(UInt16(16).littleEndianData)
        data.append("data".data(using: .ascii)!)
        data.append(UInt32(subchunk2Size).littleEndianData)
        return data
    }
}

private extension FixedWidthInteger {
    var littleEndianData: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: MemoryLayout<Self>.size)
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(string.data(using: .utf8)!)
    }
}
