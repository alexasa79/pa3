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
    private let sentencesToKeep = 2
    private let whisperPort = 65_461

    private let stateLock = NSLock()
    private let taskLock = NSLock()
    private var stableText = ""
    private var stableRunes = 0
    private var previousSentences: [String] = []
    private var systemPrompt = ""
    private var language = "en"
    private var isStopping = false

    private var audioEngine: AVAudioEngine?
    private var captureSession: AVCaptureSession?
    private var captureDelegate: AudioCaptureDelegate?
    private var sampleQueue: SampleQueue?
    private var captureQueue = DispatchQueue(label: "pa3.audio.capture")
    private var workerThread: Thread?
    private var currentTask: URLSessionDataTask?
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
            self?.ensureWhisperServerStarted()
        }
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

    func stablePrefixRunes() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stableRunes
    }

    func startTranscribe(sendTo receiver: @escaping @Sendable (String) -> Void, skipWhisper: Bool = false) {
        Logger.info("TranscriberService.startTranscribe")
        stopTranscribe()

        stateLock.lock()
        stableText = ""
        stableRunes = 0
        previousSentences = []
        isStopping = false
        self.skipWhisper = skipWhisper
        stateLock.unlock()
        debugLock.lock()
        tapCallbacks = 0
        queuedChunks = 0
        workerChunks = 0
        debugLock.unlock()

        timestamp = Self.recordingTimestamp()
        startCaptureAndWorker(receiver: receiver)
    }

    func stopTranscribe() {
        Logger.info("TranscriberService.stopTranscribe")
        stateLock.lock()
        isStopping = true
        stateLock.unlock()

        taskLock.lock()
        currentTask?.cancel()
        currentTask = nil
        taskLock.unlock()

        sampleQueue?.close()
        workerThread?.cancel()
        while workerThread?.isExecuting == true {
            Thread.sleep(forTimeInterval: 0.01)
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

        sampleRate = 48_000
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
            if rate > 0 {
                self.sampleRate = Int(rate.rounded())
            }
            self.noteTapCallback(frames: samples.count)
            self.captureQueue.async {
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

    private func transcribeLoop(queue: SampleQueue, timestamp: String, sampleRate: Int, receiver: @escaping @Sendable (String) -> Void) {
        var audio: [Float] = []
        audio.reserveCapacity(sampleRate * 300)

        while !Thread.current.isCancelled {
            guard let chunk = queue.receive() else {
                Logger.info("transcription worker queue closed")
                break
            }
            noteWorkerChunk(samples: chunk.count)
            audio.append(contentsOf: chunk)
            for drained in queue.drain() {
                audio.append(contentsOf: drained)
            }

            if skipWhisper {
                if audio.count > sampleRate {
                    audio.removeAll(keepingCapacity: true)
                }
                continue
            }
            if audio.count > sampleRate {
                let trimmed = transcribeSlice(samples: audio, timestamp: timestamp, sampleRate: sampleRate, receiver: receiver)
                if trimmed > 0 {
                    if trimmed >= audio.count {
                        audio.removeAll(keepingCapacity: true)
                    } else {
                        audio.removeFirst(trimmed)
                    }
                }
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

    private func transcribeSlice(samples: [Float], timestamp: String, sampleRate: Int, receiver: @escaping @Sendable (String) -> Void) -> Int {
        ensureWhisperServerStarted()
        let paddingSamples = max(0, Int(round(Double(sampleRate) * silencePadding)))
        let padded = [Float](repeating: 0, count: paddingSamples) + samples
        let wav = WAVEncoder.encode(samples: padded, sampleRate: sampleRate)
        saveRecording(wav, timestamp: timestamp)

        let trimSeconds = sendRequest(wav: wav, receiver: receiver)
        if trimSeconds <= 0 {
            return 0
        }
        let trimmedSamples = Int(round(trimSeconds * Double(sampleRate)))
        if trimmedSamples <= 0 || trimmedSamples >= samples.count {
            return 0
        }
        return trimmedSamples
    }

    private func sendRequest(wav: Data, receiver: @escaping @Sendable (String) -> Void) -> Double {
        guard let url = URL(string: "http://127.0.0.1:\(whisperPort)/inference") else {
            return 0
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
        let prev = previousSentences
        let stopping = isStopping
        stateLock.unlock()
        if stopping {
            return 0
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
            return 0
        }
        guard result.statusCode == 200, let responseData = result.data else {
            Logger.warn("Whisper server responded with status \(result.statusCode)")
            return 0
        }

        do {
            var transcription = try JSONDecoder().decode(WhisperTranscription.self, from: responseData)
            transcription = adjustTranscriptionTiming(transcription)
            let split = splitTranscription(transcription, previousSentences: prev, keepSentences: sentencesToKeep)

            stateLock.lock()
            if split.trimSeconds > 0, !split.stableChunk.isEmpty {
                stableText = appendText(stableText, split.stableChunk)
            }
            previousSentences = split.nextSentences
            let joined = joinText(stableText, split.pendingText)
            stableRunes = joined.stableRunes
            stateLock.unlock()

            let text = joined.text
            Logger.info("Received Whisper transcription chars=\(text.count)")
            DispatchQueue.main.async {
                receiver(text)
            }
            return split.trimSeconds
        } catch {
            Logger.warn("Failed to decode whisper response: \(error)")
            return 0
        }
    }

    func debugTranscribeWAV(_ wav: Data) -> String {
        ensureWhisperServerStarted()
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var text = ""
            var done = false
            func set(_ value: String) {
                lock.lock()
                text = value
                done = true
                lock.unlock()
            }
            func snapshot() -> (Bool, String) {
                lock.lock()
                defer { lock.unlock() }
                return (done, text)
            }
        }
        let box = Box()
        _ = sendRequest(wav: wav) { text in
            box.set(text)
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let snapshot = box.snapshot()
            if snapshot.0 {
                return snapshot.1
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return box.snapshot().1
    }

    private func saveRecording(_ wav: Data, timestamp: String) {
        let dir = installationDirectory().appendingPathComponent("rec")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(timestamp).wav")
        try? wav.write(to: file)
    }

    private func startWhisperServer() {
        if isWhisperPortOpen() {
            Logger.info("Whisper server is already reachable on port \(whisperPort)")
            return
        }

        let installDir = installationDirectory()
        let buildDir = installDir.appendingPathComponent("whisper.cpp/build")
        let server = buildDir.appendingPathComponent("bin/whisper-server")
        let model = installDir.appendingPathComponent("models/whisper.ggml")
        let args = ["-m", model.path, "--port", "\(whisperPort)"]

        if isServerRunning(serverPath: server.path, args: args) {
            Logger.info("Whisper server is already running")
            return
        }

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
        do {
            try process.run()
            Logger.info("Started whisper-server pid \(process.processIdentifier)")
        } catch {
            Logger.error("Failed to start whisper-server: \(error)")
        }
        waitForWhisperServer(timeout: 45)
    }

    private func ensureWhisperServerStarted() {
        startupLock.lock()
        if startupStarted {
            startupLock.unlock()
            if !isWhisperPortOpen() {
                waitForWhisperServer(timeout: 45)
            }
            return
        }
        startupStarted = true
        startupLock.unlock()
        startWhisperServer()
    }

    private func isServerRunning(serverPath: String, args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["aux"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return false }
            let expected = ([serverPath] + args).joined(separator: " ")
            return text.contains(expected)
        } catch {
            Logger.warn("Unable to inspect running processes: \(error)")
            return false
        }
    }

    private func waitForWhisperServer(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isWhisperPortOpen() {
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        Logger.warn("Whisper server did not become ready")
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

    private func adjustTranscriptionTiming(_ transcription: WhisperTranscription) -> WhisperTranscription {
        // The current UI only needs text and word end boundaries. Keep response immutable here and account for padding while splitting.
        transcription
    }

    private func splitTranscription(_ transcription: WhisperTranscription, previousSentences: [String], keepSentences: Int) -> (trimSeconds: Double, stableChunk: String, pendingText: String, nextSentences: [String]) {
        let tokens = transcription.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if tokens.isEmpty || keepSentences < 0 {
            return (0, "", "", [])
        }
        let boundaries = sentenceBoundaries(transcription.segments)
        var sentences = completeSentenceTexts(tokens)
        let completeCount = min(boundaries.count, sentences.count)
        sentences = Array(sentences.prefix(completeCount))
        if completeCount == 0 {
            return (0, "", buildText(tokens), sentences)
        }
        let verified = commonSentencePrefix(previousSentences, sentences)
        let maxCommit = max(0, completeCount - keepSentences)
        let commitCount = min(verified, maxCommit)
        if commitCount <= 0 {
            return (0, "", buildText(tokens), sentences)
        }
        let boundaryIndex = commitCount - 1
        let trimSeconds = max(0, boundaries[boundaryIndex] - silencePadding)
        if trimSeconds <= 0 {
            return (0, "", buildText(tokens), sentences)
        }
        let split = splitTokensAtSentence(tokens, boundaryIndex: boundaryIndex)
        return (trimSeconds, buildText(split.stable), buildText(split.pending), Array(sentences.dropFirst(commitCount)))
    }

    private func sentenceBoundaries(_ segments: [WhisperSegment]) -> [Double] {
        var result: [Double] = []
        for segment in segments {
            for word in segment.words ?? [] where endsSentence(word.word) {
                result.append(max(0, Double(word.end) - silencePadding))
            }
        }
        return result
    }

    private static func recordingTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter.string(from: Date())
    }
}

extension TranscriberService: @unchecked Sendable {}

private final class ConverterInputProvider: @unchecked Sendable {
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

enum WAVEncoder {
    static func encode(samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        let bytesPerSample = 2
        let subchunk2Size = samples.count * bytesPerSample
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

        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let value = Int16(clamped * 32767)
            data.append(value.littleEndianData)
        }
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
