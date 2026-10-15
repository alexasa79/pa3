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

struct TranscriptionUpdate: Sendable {
    let text: String
    let language: String?
    let isRecognition: Bool

    init(text: String, language: String?, isRecognition: Bool = true) {
        self.text = text
        self.language = language
        self.isRecognition = isRecognition
    }
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
    private var continuationAnchor: (offset: Int, word: String)?
    private var rejectedBoundaryOffset = -1
    private var rejectedBoundaryHeads: Set<String> = []
    private var whisperPrompt = ""
    /// Called with the absolute time of every cut. Used by the replay tool.
    var cutHandler: (@Sendable (Double, SegmentCut) -> Void)?
    private var isStopping = false
    private var captureRequested = false
    private var recordingActive = false
    private var recordingActivityHandler: (@Sendable () -> Void)?

    var isRecording: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return recordingActive
    }

    func setRecordingActivityHandler(_ handler: @escaping @Sendable () -> Void) {
        stateLock.lock()
        recordingActivityHandler = handler
        stateLock.unlock()
    }

    private func markRecordingActive(generation expected: Int) {
        stateLock.lock()
        guard generation == expected, captureRequested, !isStopping, !recordingActive else {
            stateLock.unlock()
            return
        }
        recordingActive = true
        let handler = recordingActivityHandler
        stateLock.unlock()
        Logger.info("Microphone recording active; first audio queued")
        handler?()
    }
    private var captureStopsInFlight = 0
    var captureIsBusy: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return captureRequested || captureStopsInFlight > 0
    }
    private var generation = 0
    private var statusHandler: (@Sendable (String) -> Void)?
    private var recordingDurationHandler: (@Sendable (Double) -> Void)?

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

    /// Audio duration limit in seconds. Applies from the next transcription round.
    func setContextSeconds(_ seconds: Int) {
        stateLock.lock()
        segmentationConfig.trimAfterSeconds = Double(SegmentationConfig.contextSecondsRange.clamped(seconds))
        stateLock.unlock()
    }

    func setVocabulary(_ words: [String]) {
        stateLock.lock()
        whisperPrompt = Vocabulary.whisperPrompt(for: words)
        stateLock.unlock()
    }

    func setStatusHandler(_ handler: (@Sendable (String) -> Void)?) {
        statusLock.lock()
        statusHandler = handler
        statusLock.unlock()
    }

    func setRecordingDurationHandler(_ handler: (@Sendable (Double) -> Void)?) {
        statusLock.lock()
        recordingDurationHandler = handler
        statusLock.unlock()
    }

    func stablePrefixRunes() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stableRunes
    }

    func startTranscribe(sendTo receiver: @escaping @Sendable (String) -> Void, skipWhisper: Bool = false) {
        startTranscribeUpdates(sendTo: { receiver($0.text) }, skipWhisper: skipWhisper)
    }

    func startTranscribeUpdates(sendTo receiver: @escaping @Sendable (TranscriptionUpdate) -> Void, skipWhisper: Bool = false) {
        Logger.info("TranscriberService.startTranscribe")
        stopTranscribe()

        stateLock.lock()
        generation += 1
        let startGeneration = generation
        stableText = ""
        stableRunes = 0
        pendingText = ""
        continuationAnchor = nil
        rejectedBoundaryOffset = -1
        rejectedBoundaryHeads.removeAll()
        isStopping = false
        captureRequested = true
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
        captureRequested = false
        recordingActive = false
        let activityHandler = recordingActivityHandler
        captureStopsInFlight += 1
        generation += 1
        stateLock.unlock()
        activityHandler?()

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

        let stoppingSession = captureSession
        if stoppingSession != nil {
            captureSession = nil
            captureDelegate = nil
        }

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }
        if let stoppingSession {
            DispatchQueue.global(qos: .utility).async { [self] in
                stoppingSession.stopRunning()
                finishCaptureStop()
            }
        } else {
            finishCaptureStop()
        }
    }

    private func finishCaptureStop() {
        stateLock.lock()
        captureStopsInFlight -= 1
        stateLock.unlock()
    }

    func close() {
        stopTranscribe()
        stopOwnedWhisperServer()
    }

    private func startCaptureAndWorker(receiver: @escaping @Sendable (TranscriptionUpdate) -> Void) {
        Logger.info("startCaptureAndWorker")
        stateLock.lock()
        let captureGeneration = generation
        stateLock.unlock()
        reportStatus("Starting microphone...")
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
                    self.markRecordingActive(generation: captureGeneration)
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

    private func transcribeLoop(queue: SampleQueue, timestamp: String, sampleRate: Int, record: Bool = true, receiver: @escaping @Sendable (TranscriptionUpdate) -> Void) {
        var audio: [Float] = []
        audio.reserveCapacity(sampleRate * 40)
        var consumedSamples = 0
        let recorder = (skipWhisper || !record) ? nil : SessionRecorder(directory: recordingDirectory(), timestamp: timestamp, sampleRate: sampleRate)
        defer { recorder?.close() }
        var lastRequestStart = Date.distantPast
        var activity = SpeechActivityGate()
        var lastSpeechEnd = 0
        var recognizedThrough = -1
        var attemptedOffset = -1
        var attemptedSpeechEnd = -1
        var attemptedNeedsCut = false

        while !Thread.current.isCancelled {
            let chunk = queue.receive()
            let ended = chunk == nil
            if let chunk {
                noteWorkerChunk(samples: chunk.count)
                for piece in [chunk] + queue.drain() {
                    recorder?.append(piece)
                    if skipWhisper { continue }
                    activity.append(piece, sampleRate: sampleRate, threshold: segmentation.minThreshold)
                    lastSpeechEnd = activity.speechEnd ?? 0
                    audio.append(contentsOf: piece)
                }
            }
            if skipWhisper {
                if ended { break }
                continue
            }
            // Before any credible speech, retain enough pre-roll for the complete
            // onset and discard old ambient audio. The full recording stays intact.
            if activity.speechEnd == nil {
                let count = max(0, audio.count - sampleRate)
                audio.removeFirst(count)
                consumedSamples += count
                if ended { break }
                continue
            }
            // Quiet freezes pending text and its audio; it never makes text permanent.
            // Only a verified cut or the user's stop can finalize an utterance.
            let minimumSamples = ended ? 0 : sampleRate
            if audio.count <= minimumSamples || lastSpeechEnd <= recognizedThrough
                || (!ended && !activity.readyForRecognition(sampleRate: sampleRate)) {
                if ended { break }
                continue
            }
            if !ended, Date().timeIntervalSince(lastRequestStart) < segmentation.minRequestInterval { continue }
            let window = recognitionWindow(samples: audio, sampleRate: sampleRate, config: segmentation)
            if window.samples.isEmpty {
                let count = max(0, window.inspectedSamples - sampleRate / 5)
                if count == 0 { if ended { break }; continue }
                audio.removeFirst(count)
                consumedSamples += count
                continue
            }
            // Remove only confirmed leading quiet, retaining pre-roll for the onset.
            // This also avoids decoding a long frozen pause when speech resumes.
            let leadingQuiet = max(0, window.speechStart - sampleRate)
            if leadingQuiet > 0 {
                audio.removeFirst(leadingQuiet)
                consumedSamples += leadingQuiet
                continue
            }
            // Do not spin on the same recognized audio when no new speech arrives.
            // Further audio remains recorded; no unverified text or samples are discarded.
            let needsCut = audio.count >= Int(segmentation.trimAfterSeconds * Double(sampleRate))
            if attemptedOffset == consumedSamples, attemptedSpeechEnd == window.speechEnd,
               !needsCut || attemptedNeedsCut {
                if ended { break }
                continue
            }
            attemptedOffset = consumedSamples
            attemptedSpeechEnd = window.speechEnd
            attemptedNeedsCut = needsCut
            lastRequestStart = Date()
            Logger.info("recognition sourceStart=\(Double(consumedSamples) / Double(sampleRate)) speechEnd=\(Double(consumedSamples + window.speechEnd) / Double(sampleRate)) capturedEnd=\(Double(consumedSamples + audio.count) / Double(sampleRate))")
            let result = transcribeSlice(samples: window.samples, offsetSamples: consumedSamples, sampleRate: sampleRate,
                                         needsCut: needsCut, receiver: receiver)
            if result.recognized {
                recognizedThrough = result.trim > 0 ? consumedSamples + result.trim : max(recognizedThrough, consumedSamples + window.samples.count)
            } else {
                attemptedOffset = -1
            }
            if result.trim > 0 {
                let count = min(result.trim, audio.count)
                audio.removeFirst(count)
                consumedSamples += count
            }
            if ended, result.trim == 0 { break }
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
    private func transcribeSlice(samples: [Float], offsetSamples: Int, sampleRate: Int, needsCut: Bool, receiver: @escaping @Sendable (TranscriptionUpdate) -> Void) -> (trim: Int, threshold: Float, recognized: Bool) {
        let segmentation = self.segmentation
        let energies = frameEnergies(samples: samples, sampleRate: sampleRate, frameSeconds: segmentation.frameSeconds)
        let threshold = speechThreshold(energies: energies, config: segmentation)
        guard transcriptionRequestForTesting != nil || ensureWhisperServerStarted() else {
            return (0, threshold, false)
        }
        if !energies.contains(where: { $0 >= threshold }) {
            // Nothing to hear. Keep a little context and skip the request so Whisper cannot invent words from silence.
            let keep = Int(segmentation.searchWindow * Double(sampleRate))
            return (max(0, samples.count - keep), threshold, false)
        }
        let paddingSamples = max(0, Int(round(Double(sampleRate) * silencePadding)))
        let padded = [Float](repeating: 0, count: paddingSamples) + samples

        guard let transcription = recognize(samples: padded, sampleRate: sampleRate, reportDuration: true) else {
            return (0, threshold, false)
        }
        var tokens = timedTokens(transcription, offset: silencePadding)
        stateLock.lock()
        let opening = continuationAnchor.flatMap { $0.offset == offsetSamples ? $0.word : nil }
        stateLock.unlock()
        if !tokens.isEmpty {
            let first = tokens[0]
            tokens[0] = TimedToken(text: continuationOpening(first.text, contextual: opening), start: first.start, end: first.end)
        }
        let quiet = quietRuns(energies: energies, threshold: threshold, config: segmentation)
        let duration = Double(samples.count) / Double(sampleRate)
        // Publish the validated full-window result before doing any trimming work.
        // Finalizing a boundary is a separate update, not another recognition.
        stateLock.lock()
        pendingText = buildText(tokens.map(\.text))
        let preview = joinText(stableText, pendingText)
        stableRunes = preview.stableRunes
        if rejectedBoundaryOffset != offsetSamples {
            rejectedBoundaryOffset = offsetSamples
            rejectedBoundaryHeads.removeAll()
        }
        let rejected = rejectedBoundaryHeads
        stateLock.unlock()
        Logger.info("Received Whisper transcription duration=\(String(format: "%.2f", duration)) text=\(String(reflecting: buildText(tokens.map(\.text))))")
        reportStatus("Dictation active")
        DispatchQueue.main.async {
            receiver(TranscriptionUpdate(text: preview.text, language: transcription.language))
        }

        var cut: SegmentCut?
        if needsCut, duration >= segmentation.trimAfterSeconds {
            let proposals = sentenceCuts(tokens: tokens, quiet: quiet, minimumCut: 0.5, duration: duration - 1, config: segmentation)
            func key(_ candidate: SegmentCut) -> String {
                normalizedWords(candidate.committed.joined(separator: " ")).joined(separator: " ")
            }
            // At most one candidate and two verification requests per round.
            // A rejected, unchanged head waits for new wording or a later sentence.
            if let candidate = proposals.first(where: { !rejected.contains(key($0)) }) {
                let cutSamples = Int(round(candidate.time * Double(sampleRate)))
                let margin = sampleRate / 20
                if cutSamples >= margin, cutSamples + margin < samples.count,
                   isQuiet(samples[(cutSamples - margin)..<(cutSamples + margin)], threshold: threshold) {
                    let retainedEnd = min(samples.count, cutSamples + 6 * sampleRate)
                    let retainedSamples = Array(samples[cutSamples..<retainedEnd])
                    if containsSpeech(samples: retainedSamples, sampleRate: sampleRate, config: segmentation) {
                        let retained = [Float](repeating: 0, count: paddingSamples) + retainedSamples
                        var headDisagreed = false
                        if let checked = recognize(samples: retained, sampleRate: sampleRate),
                           let confirmed = confirmRetainedCut(candidate, tokens: tokens,
                               retainedWords: timedTokens(checked, offset: silencePadding).map(\.text), headIsQuiet: false) {
                            let head = [Float](repeating: 0, count: paddingSamples) + samples.prefix(cutSamples)
                            if let checkedHead = recognize(samples: head, sampleRate: sampleRate) {
                                cut = confirmCommittedCut(confirmed, headWords: timedTokens(checkedHead, offset: silencePadding).map(\.text))
                                headDisagreed = cut == nil
                            }
                        }
                        if headDisagreed {
                            stateLock.lock()
                            rejectedBoundaryHeads.insert(key(candidate))
                            stateLock.unlock()
                            Logger.info("Deferring disputed sentence boundary; preserving provisional text and audio")
                        }
                    }
                }
            }
        }
        guard let cut else { return (0, threshold, true) }

        stateLock.lock()
        stableText = appendText(stableText, buildText(cut.committed))
        pendingText = buildText(cut.pending)
        let nextOffset = offsetSamples + Int(round(cut.time * Double(sampleRate)))
        continuationAnchor = cut.committed.last.map { endsSentence($0) } == false
            ? cut.pending.first.map { (offset: nextOffset, word: $0) } : nil
        let joined = joinText(stableText, pendingText)
        stableRunes = joined.stableRunes
        stateLock.unlock()

        let absolute = Double(offsetSamples) / Double(sampleRate) + cut.time
        Logger.info("cut at \(String(format: "%.2f", absolute))s reason=\(cut.reason) committed=\(String(reflecting: buildText(cut.committed))) pending=\(String(reflecting: buildText(cut.pending)))")
        cutHandler?(absolute, cut)
        let text = joined.text
        DispatchQueue.main.async {
            receiver(TranscriptionUpdate(text: text, language: transcription.language, isRecognition: false))
        }
        return (Int(round(cut.time * Double(sampleRate))), threshold, true)
    }

    var recognitionHandler: (@Sendable (Double) -> Void)?

    // Test transport: exercises the real recognition and segmentation path without
    // microphone access, a model server, or variable model output.
    var transcriptionRequestForTesting: (@Sendable (Data, String) -> WhisperTranscription?)?

    func debugTranscribeSlice(samples: [Float], needsCut: Bool,
                              receiver: @escaping @Sendable (TranscriptionUpdate) -> Void) -> (trim: Int, recognized: Bool) {
        precondition(transcriptionRequestForTesting != nil)
        let result = transcribeSlice(samples: samples, offsetSamples: 0,
                                     sampleRate: Self.defaultSampleRate, needsCut: needsCut, receiver: receiver)
        return (result.trim, result.recognized)
    }

    private func recognize(samples: [Float], sampleRate: Int, reportDuration: Bool = false) -> WhisperTranscription? {
        // Even a complete short word gets at least one second of acoustic context.
        let padded = samples + [Float](repeating: 0, count: max(0, sampleRate - samples.count))
        let duration = Double(padded.count) / Double(sampleRate)
        recognitionHandler?(duration)
        // Boundary verification decodes short excerpts of the same audio. Those
        // requests must not replace the duration of the main transcription window.
        if reportDuration {
            statusLock.lock()
            let durationHandler = recordingDurationHandler
            statusLock.unlock()
            durationHandler?(duration)
        }
        Logger.info("recognition duration=\(String(format: "%.3f", duration))")
        return requestTranscription(wav: WAVEncoder.encode(samples: padded, sampleRate: sampleRate))
    }

    private func requestTranscription(wav: Data) -> WhisperTranscription? {
        if let transport = transcriptionRequestForTesting {
            stateLock.lock()
            let prompt = whisperPrompt
            stateLock.unlock()
            return transport(wav, prompt)
        }
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
        let prompt = whisperPrompt
        let stopping = isStopping
        stateLock.unlock()
        if stopping {
            return nil
        }
        addField("prompt", prompt)
        // Explicitly override the server's English default for every audio clip.
        addField("language", "auto")
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
        continuationAnchor = nil
        rejectedBoundaryOffset = -1
        rejectedBoundaryHeads.removeAll()
        isStopping = false
        skipWhisper = false
        stateLock.unlock()
        self.sampleRate = sampleRate

        let framesPerChunk = max(1, Int(round(Double(sampleRate * chunkDurationMs) / 1000.0)))
        let queue = SampleQueue(capacity: max(32, (sampleRate / framesPerChunk) * audioBufferSeconds))
        sampleQueue = queue
        let thread = Thread { [weak self, weak queue] in
            guard let self, let queue else { return }
            self.transcribeLoop(queue: queue, timestamp: "replay", sampleRate: sampleRate, record: false, receiver: { receiver($0.text) })
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

        guard let server = SpeechRuntime.executable("whisper-server") else {
            reportStatus("Install speech tools: brew install whisper.cpp")
            return false
        }
        let model = SpeechRuntime.whisperModel
        guard FileManager.default.fileExists(atPath: model.path) else {
            reportStatus("Whisper model missing; run make speech-setup")
            return false
        }
        let args = ["-m", model.path, "--host", "127.0.0.1", "--port", "\(whisperPort)"]

        let process = Process()
        process.executableURL = server
        process.arguments = args
        Logger.info("Whisper executable=\(server.path) model=\(model.path)")
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
