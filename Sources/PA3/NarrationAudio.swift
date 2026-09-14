@preconcurrency import AVFoundation
import Foundation

enum NarrationAudio {
    enum Invalid: LocalizedError {
        case silence
        var errorDescription: String? { "The speech model returned silence." }
    }
    // Detect speech in 10 ms windows, retaining 40 ms before and 80 ms after it.
    // Never remove interior pauses or breaths. Keep quiet consonants with the padding.
    static func speechRange(_ samples: [Float], rate: Double) -> Range<Int>? {
        let window = max(1, Int(rate * 0.01))
        var first: Int?, last = 0
        for offset in stride(from: 0, to: samples.count, by: window) {
            let end = min(samples.count, offset + window)
            let energy = samples[offset..<end].reduce(Float(0)) { $0 + $1 * $1 } / Float(end - offset)
            if energy > 0.0000032 { // approximately -55 dBFS RMS
                if first == nil { first = offset }
                last = end
            }
        }
        guard let first else { return nil }
        return max(0, first - Int(rate * 0.04))..<min(samples.count, last + Int(rate * 0.08))
    }

    static func trim(_ path: URL, pause: Double) throws {
        let file = try AVAudioFile(forReading: path)
        guard file.length > 0, file.length < AVAudioFramePosition(file.processingFormat.sampleRate * 81.92),
              file.processingFormat.channelCount == 1,
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NarrationText.Invalid("Invalid narration audio")
        }
        try file.read(into: source)
        guard let data = source.floatChannelData?[0] else { throw NarrationText.Invalid("Missing narration samples") }
        let samples = Array(UnsafeBufferPointer(start: data, count: Int(source.frameLength)))
        let rate = file.processingFormat.sampleRate
        guard let range = speechRange(samples, rate: rate) else { throw Invalid.silence }
        // Edge padding supplies about 120 ms across adjacent pieces. Top up to the desired gap.
        let silence = Int(max(0, pause - 0.12) * rate)
        let count = range.count + silence
        guard let output = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)),
              let target = output.floatChannelData?[0] else { throw NarrationText.Invalid("Could not prepare audio") }
        output.frameLength = AVAudioFrameCount(count)
        for (index, sample) in samples[range].enumerated() { target[index] = sample }
        if silence > 0 { target.advanced(by: range.count).initialize(repeating: 0, count: silence) }
        let temporary = path.deletingPathExtension().appendingPathExtension("trim.wav")
        do {
            let destination = try AVAudioFile(forWriting: temporary, settings: file.fileFormat.settings)
            try destination.write(from: output)
        }
        _ = try FileManager.default.replaceItemAt(path, withItemAt: temporary)
        Logger.info("Narration audio trimmed \(String(format: "%.2f", Double(samples.count - range.count) / rate))s of edge silence; pause \(pause)s")
    }
}
