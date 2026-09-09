@preconcurrency import AVFoundation
import Foundation

/// Offline replay: pushes a recording through the live transcription worker and checks the result.
///
///   pa3 --replay file.wav [--reference file.txt] [--speed 4] [--max-wer 0.1] [--context-seconds 28]
///   pa3 --replay-test [dir]        replays every dir/*.wav that has a matching .txt reference
enum Replay {
    struct Outcome {
        var name: String
        var text: String
        var cuts: [(time: Double, cut: SegmentCut)]
        var cutProblems: [String]
        var referenceWER: Double?
        var oneShotWER: Double?
        var referenceDiff: String
        var oneShotDiff: String
        var seconds: Double
    }

    /// Audio duration limit during replay. Set with `--context-seconds N`.
    nonisolated(unsafe) static var contextSeconds = Int(SegmentationConfig.default.maxBuffer)

    static func main(arguments: [String]) -> Int32 {
        Logger.setup()
        defer { Logger.close() }
        let speed = value(after: "--speed", in: arguments).flatMap(Double.init) ?? 4
        let maxWER = value(after: "--max-wer", in: arguments).flatMap(Double.init) ?? 0.1
        if arguments.contains("--keep") {
            print("--keep was replaced by --context-seconds (5...28 seconds)")
            return 2
        }
        if arguments.contains("--context-seconds") {
            guard let raw = value(after: "--context-seconds", in: arguments),
                  let seconds = Int(raw), SegmentationConfig.contextSecondsRange.contains(seconds) else {
                print("--context-seconds must be an integer from 5 to 28")
                return 2
            }
            contextSeconds = seconds
        }

        if arguments.contains("--replay-test") {
            let dir = value(after: "--replay-test", in: arguments).map { URL(fileURLWithPath: $0) }
                ?? URL(fileURLWithPath: "Tests/fixtures")
            return runDirectory(dir, speed: speed, maxWER: maxWER)
        }
        guard let path = value(after: "--replay", in: arguments) else {
            print("usage: pa3 --replay file.wav [--reference file.txt] [--speed 4] [--max-wer 0.1] [--context-seconds 28]")
            return 2
        }
        let wav = URL(fileURLWithPath: path)
        var reference: String? = nil
        if let referencePath = value(after: "--reference", in: arguments) {
            reference = try? String(contentsOfFile: referencePath, encoding: .utf8)
        } else {
            let sibling = wav.deletingPathExtension().appendingPathExtension("txt")
            reference = try? String(contentsOf: sibling, encoding: .utf8)
        }
        let transcriber = TranscriberService()
        defer { transcriber.close() }
        guard let outcome = run(wav: wav, reference: reference, speed: speed, transcriber: transcriber) else {
            return 2
        }
        report(outcome, verbose: true)
        return passes(outcome, maxWER: maxWER) ? 0 : 1
    }

    private static func runDirectory(_ dir: URL, speed: Double, maxWER: Double) -> Int32 {
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if files.isEmpty {
            print("no fixtures in \(dir.path); run `make fixtures` first")
            return 2
        }
        let transcriber = TranscriberService()
        defer { transcriber.close() }
        var failed = 0
        for wav in files {
            let referenceURL = wav.deletingPathExtension().appendingPathExtension("txt")
            let reference = try? String(contentsOf: referenceURL, encoding: .utf8)
            guard let outcome = run(wav: wav, reference: reference, speed: speed, transcriber: transcriber) else {
                print("FAIL \(wav.lastPathComponent): could not replay")
                failed += 1
                continue
            }
            let ok = passes(outcome, maxWER: maxWER)
            if !ok {
                failed += 1
            }
            report(outcome, verbose: !ok)
        }
        print(failed == 0 ? "replay-test ok (\(files.count) files)" : "replay-test FAILED \(failed) of \(files.count)")
        return failed == 0 ? 0 : 1
    }

    static func run(wav: URL, reference: String?, speed: Double, transcriber: TranscriberService) -> Outcome? {
        guard let audio = loadAudio(wav) else {
            print("could not read \(wav.path)")
            return nil
        }
        let config = SegmentationConfig.default
        final class Collector: @unchecked Sendable {
            let lock = NSLock()
            var cuts: [(time: Double, cut: SegmentCut)] = []
            var latest = ""
        }
        let collector = Collector()
        transcriber.setContextSeconds(contextSeconds)
        transcriber.cutHandler = { time, cut in
            collector.lock.lock()
            collector.cuts.append((time, cut))
            collector.lock.unlock()
        }
        let started = Date()
        transcriber.replay(samples: audio.samples, sampleRate: audio.sampleRate, speed: speed) { text in
            collector.lock.lock()
            collector.latest = text
            collector.lock.unlock()
        }
        transcriber.cutHandler = nil
        let elapsed = Date().timeIntervalSince(started)
        let final = transcriber.currentText()
        let text = joinText(final.stable, final.pending).text

        // Every cut must sit in audio that is quiet by the standard of the whole file.
        let energies = frameEnergies(samples: audio.samples, sampleRate: audio.sampleRate, frameSeconds: config.frameSeconds)
        let threshold = speechThreshold(energies: energies, config: config)
        var cutProblems: [String] = []
        for (time, cut) in collector.cuts {
            let center = Int(time / config.frameSeconds)
            let span = Int(0.05 / config.frameSeconds)
            let window = energies[max(0, center - span)..<min(energies.count, center + span + 1)]
            if let peak = window.max(), peak >= threshold {
                cutProblems.append(String(format: "cut at %.2fs (%@) is not quiet: rms %.4f >= %.4f", time, cut.reason, peak, threshold))
            }
        }

        var outcome = Outcome(name: wav.lastPathComponent, text: text, cuts: collector.cuts, cutProblems: cutProblems,
                              referenceWER: nil, oneShotWER: nil, referenceDiff: "", oneShotDiff: "", seconds: elapsed)
        let hypothesis = normalizedWords(text)
        if let reference {
            let diff = wordDiff(reference: normalizedWords(reference), hypothesis: hypothesis)
            outcome.referenceWER = diff.rate
            outcome.referenceDiff = diff.summary
        }
        let duration = Double(audio.samples.count) / Double(audio.sampleRate)
        if duration <= 30 {
            let oneShot = transcriber.debugTranscribeWAV(WAVEncoder.encode(samples: audio.samples, sampleRate: audio.sampleRate))
            let diff = wordDiff(reference: normalizedWords(oneShot), hypothesis: hypothesis)
            outcome.oneShotWER = diff.rate
            outcome.oneShotDiff = diff.summary
        }
        return outcome
    }

    static func passes(_ outcome: Outcome, maxWER: Double) -> Bool {
        if !outcome.cutProblems.isEmpty { return false }
        if let wer = outcome.referenceWER, wer > maxWER { return false }
        if let wer = outcome.oneShotWER, wer > maxWER { return false }
        return true
    }

    static func report(_ outcome: Outcome, verbose: Bool) {
        var line = "\(outcome.name): cuts=\(outcome.cuts.count)"
        if let wer = outcome.referenceWER { line += String(format: " wer(ref)=%.3f", wer) }
        if let wer = outcome.oneShotWER { line += String(format: " wer(one-shot)=%.3f", wer) }
        line += String(format: " time=%.1fs", outcome.seconds)
        line += outcome.cutProblems.isEmpty ? "" : " cut-problems=\(outcome.cutProblems.count)"
        print(line)
        guard verbose else { return }
        for (time, cut) in outcome.cuts {
            print(String(format: "  cut %6.2fs %-20@ %@", time, cut.reason, buildText(cut.committed)))
        }
        for problem in outcome.cutProblems {
            print("  PROBLEM \(problem)")
        }
        if !outcome.referenceDiff.isEmpty { print("  vs reference: \(outcome.referenceDiff)") }
        if !outcome.oneShotDiff.isEmpty { print("  vs one-shot: \(outcome.oneShotDiff)") }
        print("  text: \(outcome.text)")
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        let next = arguments[index + 1]
        return next.hasPrefix("--") ? nil : next
    }

    /// Reads any audio file into 16 kHz mono float samples.
    static func loadAudio(_ url: URL) -> (samples: [Float], sampleRate: Int)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = Double(TranscriberService.defaultSampleRate)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else { return nil }
        let frames = AVAudioFrameCount(file.length)
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              (try? file.read(into: input)) != nil else { return nil }
        let outCapacity = AVAudioFrameCount(Double(frames) * rate / file.processingFormat.sampleRate + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else { return nil }
        var error: NSError?
        let provider = ConverterInputProvider(buffer: input)
        converter.convert(to: output, error: &error) { _, status in
            provider.next(status: status)
        }
        if error != nil { return nil }
        guard let data = output.floatChannelData else { return nil }
        return (Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength))), Int(rate))
    }
}

/// Lowercase words with punctuation removed, so comparisons look at what was said rather than how it was punctuated.
func normalizedWords(_ text: String) -> [String] {
    text.lowercased()
        .split(whereSeparator: { $0.isWhitespace })
        .map { token in String(token.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "'" }) }
        .filter { !$0.isEmpty }
}

/// Word-level edit distance with a readable list of what was added, dropped, or changed.
func wordDiff(reference: [String], hypothesis: [String]) -> (distance: Int, rate: Double, summary: String) {
    let n = reference.count, m = hypothesis.count
    var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
    for i in 0...n { table[i][0] = i }
    for j in 0...m { table[0][j] = j }
    if n > 0 && m > 0 {
        for i in 1...n {
            for j in 1...m {
                let cost = reference[i - 1] == hypothesis[j - 1] ? 0 : 1
                table[i][j] = min(table[i - 1][j] + 1, table[i][j - 1] + 1, table[i - 1][j - 1] + cost)
            }
        }
    }
    var ops: [String] = []
    var i = n, j = m
    while i > 0 || j > 0 {
        if i > 0, j > 0, table[i][j] == table[i - 1][j - 1], reference[i - 1] == hypothesis[j - 1] {
            i -= 1; j -= 1
        } else if i > 0, j > 0, table[i][j] == table[i - 1][j - 1] + 1 {
            ops.append("\(reference[i - 1])->\(hypothesis[j - 1])")
            i -= 1; j -= 1
        } else if j > 0, table[i][j] == table[i][j - 1] + 1 {
            ops.append("+\(hypothesis[j - 1])")
            j -= 1
        } else {
            ops.append("-\(reference[i - 1])")
            i -= 1
        }
    }
    let distance = table[n][m]
    let rate = n == 0 ? (m == 0 ? 0 : 1) : Double(distance) / Double(n)
    let summary = ops.isEmpty ? "exact" : ops.reversed().joined(separator: " ")
    return (distance, rate, summary)
}
