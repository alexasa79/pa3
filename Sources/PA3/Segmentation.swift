import Foundation

/// One whitespace-separated token of a transcription with its audio span, in seconds from the start of the buffer.
/// Whisper tends to stretch the end of a word into a following pause, so `start` is the more reliable of the two.
struct TimedToken: Equatable {
    let text: String
    let start: Double
    let end: Double
}

/// A stretch of audio below the speech threshold, in seconds from the start of the buffer.
struct QuietRun: Equatable {
    let start: Double
    let end: Double

    var length: Double { end - start }
    var middle: Double { (start + end) / 2 }
}

struct SegmentationConfig {
    /// How far from a sentence-final word's timestamp to look for a pause.
    var searchWindow = 0.5
    /// Shortest pause that counts as a gap between sentences.
    var minQuiet = 0.15
    /// Silence kept at the end of the buffer. Anything beyond it is dropped as it arrives.
    var maxTrailingSilence = 1.0
    /// Time between the starts of two rounds. A round that runs longer than this delays the next one.
    var minRequestInterval = 1.0
    /// Duration limit, with headroom below Whisper's 30-second window.
    static let contextSecondsRange = 5...28
    var maxBuffer = Double(SegmentationConfig.contextSecondsRange.upperBound)
    /// Frame size for energy measurement.
    var frameSeconds = 0.01
    /// Speech threshold is the noise floor times this factor, clamped to the range below.
    var noiseFactor: Float = 3
    var minThreshold: Float = 0.003
    var maxThreshold: Float = 0.02

    static let `default` = SegmentationConfig()
}

struct SegmentCut: Equatable {
    /// Where to trim the buffer, in seconds from its start. Always inside a pause.
    let time: Double
    let committed: [String]
    let pending: [String]
    let reason: String
    /// True when the words were assigned by timestamp. Those are unreliable near pauses, so the caller
    /// should transcribe the audio before the cut on its own and use that text instead of `committed`.
    var timeBased = false
}

/// Rebuilds the whitespace-separated tokens of `decodedWhisperText` while keeping the end time of each token.
/// `offset` is subtracted from every timestamp, which removes the silence padding added before the request.
func timedTokens(_ transcription: WhisperTranscription, offset: Double) -> [TimedToken] {
    var result: [TimedToken] = []
    var current = ""
    var currentStart = 0.0
    var currentEnd = 0.0
    func flush() {
        if !current.isEmpty {
            result.append(TimedToken(text: current, start: currentStart, end: currentEnd))
            current = ""
        }
    }
    for segment in transcription.segments {
        for word in segment.words ?? [] {
            let start = max(0, Double(word.start) - offset)
            let end = max(0, Double(word.end) - offset)
            for character in word.word {
                if character.isWhitespace {
                    flush()
                } else {
                    if current.isEmpty {
                        currentStart = start
                    }
                    current.append(character)
                    currentEnd = end
                }
            }
        }
    }
    flush()
    return result
}

/// Root mean square energy per frame.
func frameEnergies(samples: [Float], sampleRate: Int, frameSeconds: Double) -> [Float] {
    let frameSize = max(1, Int(Double(sampleRate) * frameSeconds))
    var result: [Float] = []
    result.reserveCapacity(samples.count / frameSize + 1)
    var index = 0
    while index < samples.count {
        let end = min(samples.count, index + frameSize)
        var sum: Float = 0
        for i in index..<end {
            sum += samples[i] * samples[i]
        }
        result.append((sum / Float(end - index)).squareRoot())
        index = end
    }
    return result
}

/// Picks the level that separates speech from background noise for this buffer.
func speechThreshold(energies: [Float], config: SegmentationConfig) -> Float {
    if energies.isEmpty {
        return config.minThreshold
    }
    let sorted = energies.sorted()
    let floor = sorted[min(sorted.count - 1, sorted.count / 5)]
    return min(config.maxThreshold, max(config.minThreshold, floor * config.noiseFactor))
}

func quietRuns(samples: [Float], sampleRate: Int, config: SegmentationConfig) -> [QuietRun] {
    let energies = frameEnergies(samples: samples, sampleRate: sampleRate, frameSeconds: config.frameSeconds)
    let threshold = speechThreshold(energies: energies, config: config)
    return quietRuns(energies: energies, threshold: threshold, config: config)
}

func quietRuns(energies: [Float], threshold: Float, config: SegmentationConfig) -> [QuietRun] {
    var result: [QuietRun] = []
    var runStart: Int? = nil
    func close(at frame: Int) {
        if let start = runStart {
            let run = QuietRun(start: Double(start) * config.frameSeconds, end: Double(frame) * config.frameSeconds)
            if run.length >= config.minQuiet {
                result.append(run)
            }
            runStart = nil
        }
    }
    for (frame, energy) in energies.enumerated() {
        if energy < threshold {
            if runStart == nil {
                runStart = frame
            }
        } else {
            close(at: frame)
        }
    }
    close(at: energies.count)
    return result
}

func containsSpeech(samples: [Float], sampleRate: Int, config: SegmentationConfig) -> Bool {
    let energies = frameEnergies(samples: samples, sampleRate: sampleRate, frameSeconds: config.frameSeconds)
    let threshold = speechThreshold(energies: energies, config: config)
    return energies.contains { $0 >= threshold }
}

/// True when no 10 ms stretch of `samples` reaches the speech threshold.
func isQuiet(_ samples: ArraySlice<Float>, threshold: Float, frameSize: Int = 160) -> Bool {
    var index = samples.startIndex
    while index < samples.endIndex {
        let end = min(samples.endIndex, index + frameSize)
        var sum: Float = 0
        for i in index..<end {
            sum += samples[i] * samples[i]
        }
        if (sum / Float(end - index)).squareRoot() >= threshold {
            return false
        }
        index = end
    }
    return true
}

/// Sentence-final tokens that have real speech after them. A period on the last token is where the audio ended, not a sentence.
func trustedSentenceEnds(_ tokens: [TimedToken]) -> [Int] {
    var result: [Int] = []
    var lastSpeech = -1
    for (index, token) in tokens.enumerated() where hasAlphanumeric(token.text) {
        lastSpeech = index
    }
    for (index, token) in tokens.enumerated() where index < lastSpeech && endsSentence(token.text) {
        result.append(index)
    }
    return result
}

/// Cut only after exceeding the duration limit. Prefer the earliest sentence boundary
/// that removes enough audio, preserving all later sentences as context.
func chooseCut(tokens: [TimedToken], quiet: [QuietRun], duration: Double, config: SegmentationConfig = .default) -> SegmentCut? {
    guard duration > config.maxBuffer else { return nil }
    // One frame of headroom puts the retained clip strictly below the limit.
    let minimumCut = duration - config.maxBuffer + config.frameSeconds
    guard minimumCut > 0, minimumCut < duration else { return nil }
    if let cut = sentenceCut(tokens: tokens, quiet: quiet, minimumCut: minimumCut, duration: duration, config: config) {
        return cut
    }

    // Without a usable sentence boundary, preserve as much audio as possible by
    // using the earliest sufficient pause. A time cut is the last resort.
    let pauseTimes = quiet.compactMap { run -> Double? in
        let time = max(minimumCut, run.middle)
        return time < run.end && time < duration ? time : nil
    }
    if let time = pauseTimes.min() {
        return cutAtTime(time, tokens: tokens, reason: "window cap")
    }
    return cutAtTime(minimumCut, tokens: tokens, reason: "window cap, no pause")
}

private func sentenceCut(tokens: [TimedToken], quiet: [QuietRun], minimumCut: Double, duration: Double, config: SegmentationConfig) -> SegmentCut? {
    var best: SegmentCut?
    for index in trustedSentenceEnds(tokens) {
        // Associate each sentence with the pause nearest the next word's start.
        // Do not select a different, later pause merely to meet the duration limit.
        let end = tokens[index].end
        let nextStart = tokens[index + 1].start
        let low = min(end, nextStart) - config.searchWindow
        let high = max(end, nextStart) + config.searchWindow
        let candidates = quiet.filter { $0.end > low && $0.start < high }
        guard let run = candidates.min(by: { abs($0.end - nextStart) < abs($1.end - nextStart) }) else { continue }
        let start = max(low, run.start)
        let finish = min(high, run.end)
        let time = max(minimumCut, (start + finish) / 2)
        guard time >= start, time < finish, time < duration else { continue }
        if let best, best.time <= time { continue }
        best = SegmentCut(
            time: time,
            committed: tokens[...index].map(\.text),
            pending: tokens[(index + 1)...].map(\.text),
            reason: "sentence"
        )
    }
    return best
}

/// Splits by word start: a word that began before the cut was spoken before it, however far Whisper stretched its end.
private func cutAtTime(_ time: Double, tokens: [TimedToken], reason: String) -> SegmentCut {
    let committed = tokens.filter { $0.start < time }.map(\.text)
    let pending = tokens.filter { $0.start >= time }.map(\.text)
    return SegmentCut(time: time, committed: committed, pending: pending, reason: reason, timeBased: true)
}

/// Checks a proposed cut against a transcription of the audio before it.
/// Time based cuts accept whatever lies before the pause. Sentence cuts must find the expected sentence there,
/// possibly followed by more complete sentences when the pause chosen was a later one.
/// Returns nil when the audio before the cut does not hold the expected words.
func confirmCut(_ cut: SegmentCut, headTokens: [String], allTokens: [String]) -> SegmentCut? {
    if cut.timeBased {
        return SegmentCut(time: cut.time, committed: headTokens, pending: cut.pending, reason: cut.reason, timeBased: true)
    }
    let expected = normalizedWords(cut.committed.joined(separator: " "))
    let head = normalizedWords(headTokens.joined(separator: " "))
    guard head.count >= expected.count, !expected.isEmpty else { return nil }
    var mismatches = 0
    for (a, b) in zip(head, expected) where a != b {
        mismatches += 1
    }
    guard mismatches <= max(1, expected.count / 10) else { return nil }
    if head.count == expected.count {
        return cut
    }
    // The pause was after more sentences than expected. Everything before it is spoken and complete, so commit it all.
    let pending = Array(allTokens.dropFirst(min(allTokens.count, headTokens.count)))
    return SegmentCut(time: cut.time, committed: headTokens, pending: pending, reason: cut.reason + " (extended)")
}

/// Converts a stream of mono samples at whatever rate the microphone delivers to a fixed output rate.
/// Linear interpolation, which is plenty for speech going down to 16 kHz. Keeps its place between chunks,
/// and starts over if the input rate changes, as it does when AirPods switch to headset mode.
/// Only ever touched from the serial capture queue.
final class Resampler: @unchecked Sendable {
    let outputRate: Double
    private(set) var inputRate = 0.0
    private var pending: [Float] = []
    private var position = 0.0

    init(outputRate: Double) {
        self.outputRate = outputRate
    }

    func process(_ input: [Float], inputRate: Double) -> [Float] {
        guard inputRate > 0, !input.isEmpty else { return [] }
        if inputRate != self.inputRate {
            if self.inputRate > 0 {
                Logger.info("input sample rate changed \(self.inputRate) -> \(inputRate)")
            }
            self.inputRate = inputRate
            pending.removeAll(keepingCapacity: true)
            position = 0
        }
        if inputRate == outputRate, pending.isEmpty {
            return input
        }
        pending.append(contentsOf: input)
        let step = inputRate / outputRate
        var output: [Float] = []
        output.reserveCapacity(Int(Double(input.count) / step) + 2)
        while position + 1 < Double(pending.count) {
            let index = Int(position)
            let fraction = Float(position - Double(index))
            output.append(pending[index] + (pending[index + 1] - pending[index]) * fraction)
            position += step
        }
        let consumed = Int(position)
        if consumed > 0 {
            pending.removeFirst(min(consumed, pending.count))
            position -= Double(consumed)
        }
        return output
    }
}
