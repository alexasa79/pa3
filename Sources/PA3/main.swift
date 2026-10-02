import AppKit
import AVFoundation
import SwiftUI

if CommandLine.arguments.contains("--narration-recovery-test") {
    let testApp = NSApplication.shared
    testApp.setActivationPolicy(.accessory)
    Task { @MainActor in exit(await runNarrationRecoveryTests()) }
    testApp.run()
}

if CommandLine.arguments.contains("--model-download-test") {
    let testApp = NSApplication.shared
    testApp.setActivationPolicy(.accessory)
    Task { @MainActor in exit(await runModelDownloadTests()) }
    testApp.run()
}

if CommandLine.arguments.contains("--audio-smoke-test") {
    Logger.setup()
    let seconds = smokeTestDuration(flag: "--audio-smoke-test")
    Logger.info("audio smoke test starting seconds=\(seconds)")
    let transcriber = TranscriberService()
    transcriber.startTranscribe(sendTo: { text in
        Logger.info("audio smoke transcription update chars=\(text.count)")
        print("TRANSCRIPTION:", text)
    }, skipWhisper: true)
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    transcriber.stopTranscribe()
    let snapshot = transcriber.debugSnapshot()
    let recDir = recordingDirectory()
    let recordings = (try? FileManager.default.contentsOfDirectory(at: recDir, includingPropertiesForKeys: nil)) ?? []
    let wavs = recordings.filter { $0.pathExtension.lowercased() == "wav" }
    Logger.info("audio smoke test result taps=\(snapshot.tapCallbacks) queued=\(snapshot.queuedChunks) worker=\(snapshot.workerChunks) wavs=\(wavs.count)")
    print("audio-smoke-test")
    print("taps=\(snapshot.tapCallbacks)")
    print("queued=\(snapshot.queuedChunks)")
    print("worker=\(snapshot.workerChunks)")
    print("wavs=\(wavs.count)")
    Logger.close()
    exit(snapshot.tapCallbacks > 0 && snapshot.queuedChunks > 0 && snapshot.workerChunks > 0 ? 0 : 2)
}

if CommandLine.arguments.contains("--duck-test") {
    Logger.setup()
    let seconds = smokeTestDuration(flag: "--duck-test", default: 6)

    func describeDefault(_ tag: String) {
        let input = OutputVolume.defaultInputDevice().map { "\($0) (\(OutputVolume.name(of: $0)))" } ?? "none"
        if let device = OutputVolume.defaultOutputDevice() {
            let vol = OutputVolume.current(device: device).map { String(format: "%.3f", $0) } ?? "nil"
            print("[\(tag)] out=\(device) (\(OutputVolume.name(of: device))) vol=\(vol)  in=\(input)")
        } else {
            print("[\(tag)] no default output device  in=\(input)")
        }
    }

    print("duck-test seconds=\(seconds) — duck, open mic (triggers Bluetooth profile switch), then restore")
    describeDefault("before")

    let ducker = OutputDucker(level: 0.15)
    ducker.start()
    describeDefault("after-duck")

    let transcriber = TranscriberService()
    transcriber.startTranscribe(sendTo: { _ in }, skipWhisper: true)

    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        describeDefault("mic-open")
    }

    transcriber.stopTranscribe()
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    describeDefault("after-mic-stop")

    ducker.stop()
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    describeDefault("after-restore")

    // Watch for several seconds: if Bluetooth keeps per-profile volume memory, the switch
    // back to the music profile may restore the (polluted) value AFTER we restore.
    let settleDeadline = Date().addingTimeInterval(5)
    while Date() < settleDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        describeDefault("settle")
    }

    Logger.close()
    exit(0)
}

if CommandLine.arguments.contains("--whisper-fixture-test") {
    Logger.setup()
    let phrase = fixturePhrase()
    Logger.info("whisper fixture test starting phrase=\(phrase)")
    do {
        let wav = try makeSpeechFixture(phrase: phrase)
        let transcriber = TranscriberService()
        let text = transcriber.debugTranscribeWAV(wav)
        Logger.info("whisper fixture test result=\(text)")
        print("whisper-fixture-test")
        print("phrase=\(phrase)")
        print("transcription=\(text)")
        Logger.close()
        exit(text.lowercased().contains("hello") ? 0 : 2)
    } catch {
        Logger.error("whisper fixture test failed: \(error)")
        print("whisper-fixture-test failed: \(error)")
        Logger.close()
        exit(2)
    }
}

if CommandLine.arguments.contains("--replay") || CommandLine.arguments.contains("--replay-test") {
    exit(Replay.main(arguments: CommandLine.arguments))
}

if CommandLine.arguments.contains("--transcript-layout-test") {
    _ = NSApplication.shared
    let failures = runTranscriptLayoutTests()
    for failure in failures { print("FAIL:", failure) }
    print(failures.isEmpty ? "transcript-layout-test: ok" : "transcript-layout-test: failed")
    exit(failures.isEmpty ? 0 : 2)
}

if CommandLine.arguments.contains("--dictionary-test") {
    _ = NSApplication.shared
    let failures = runNarrationDictionaryTests()
    failures.forEach { print("FAIL: " + $0) }
    print(failures.isEmpty ? "dictionary-test: ok" : "dictionary-test: failed")
    exit(failures.isEmpty ? 0 : 2)
}

if CommandLine.arguments.contains("--whisper-text-test") {
    let failures = runWhisperTextTests() + runSegmentationTests() + runNarrationTests() + runNarrationDictionaryTests() + runSelectedTextTests() + runWordCapitalizationTests() + runDeletionCleanupTests() + runUndoTests() + runRepeatReplacementTests() + runShortcutsTests()
    print("whisper-text-test")
    if failures.isEmpty {
        print("ok")
        exit(0)
    }
    for failure in failures {
        print("FAIL:", failure)
    }
    exit(2)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

private func smokeTestDuration(flag: String = "--audio-smoke-test", default fallback: TimeInterval = 3) -> TimeInterval {
    guard let index = CommandLine.arguments.firstIndex(of: flag),
          CommandLine.arguments.indices.contains(index + 1),
          let value = Double(CommandLine.arguments[index + 1]) else {
        return fallback
    }
    return value
}

private func fixturePhrase() -> String {
    guard let index = CommandLine.arguments.firstIndex(of: "--whisper-fixture-test"),
          CommandLine.arguments.indices.contains(index + 1) else {
        return "hello world"
    }
    return CommandLine.arguments[(index + 1)...].joined(separator: " ")
}

private func makeSpeechFixture(phrase: String) throws -> Data {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pa3-fixture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let aiff = dir.appendingPathComponent("speech.aiff")
    let wav = dir.appendingPathComponent("speech.wav")

    try runProcess("/usr/bin/say", ["-o", aiff.path, phrase])
    try runProcess("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", aiff.path, wav.path])
    return try Data(contentsOf: wav)
}

private func runProcess(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        throw NSError(domain: "PA3.Process", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\(executable) failed: \(output)"])
    }
}

private func runWhisperTextTests() -> [String] {
    var failures: [String] = []

    func expect(_ name: String, _ transcription: WhisperTranscription, _ expected: String) {
        let actual = decodedWhisperText(transcription)
        if actual != expected {
            failures.append("\(name): expected \(String(reflecting: expected)), got \(String(reflecting: actual))")
        }
    }

    expect(
        "joins continuation across segment boundary",
        makeTestTranscription(segments: [
            makeTestSegment(text: " Very importantly, I want you to implement a test that ver", words: [
                " Very", " importantly", ",", " I", " want", " you", " to", " implement", " a", " test", " that", " ver"
            ]),
            makeTestSegment(text: "ifies that the behavior is correct.", words: [
                "ifies", " that", " the", " behavior", " is", " correct", "."
            ])
        ]),
        "Very importantly, I want you to implement a test that verifies that the behavior is correct."
    )

    expect(
        "preserves real space across segment boundary",
        makeTestTranscription(segments: [
            makeTestSegment(text: "I also want you to implement a test that verifies that the", words: [
                " I", " also", " want", " you", " to", " implement", " a", " test", " that", " verifies", " that", " the"
            ]),
            makeTestSegment(text: " order cancellation when rejected type of scenario also", words: [
                " order", " cancellation", " when", " rejected", " type", " of", " scenario", " also"
            ]),
            makeTestSegment(text: " works.", words: [
                " works", "."
            ])
        ]),
        "I also want you to implement a test that verifies that the order cancellation when rejected type of scenario also works."
    )

    expect(
        "preserves contraction and trims first word",
        makeTestTranscription(segments: [
            makeTestSegment(text: " I'm checking whether it works.", words: [
                " I", "'m", " checking", " whether", " it", " works", "."
            ])
        ]),
        "I'm checking whether it works."
    )

    expect(
        "falls back to response text without word pieces",
        makeTestTranscription(
            segments: [
                WhisperSegment(id: 0, text: " Plain response text.", start: 0, end: 1, words: nil)
            ],
            text: " Plain response text.\n"
        ),
        "Plain response text."
    )

    failures.append(contentsOf: runSessionRecorderTest())
    return failures
}

private func runSessionRecorderTest() -> [String] {
    let name = "session recorder writes a readable wav"
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pa3-recorder-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let sampleRate = 16_000
    guard let recorder = SessionRecorder(directory: dir, timestamp: "test", sampleRate: sampleRate) else {
        return ["\(name): could not create recorder"]
    }
    let first = (0..<160).map { Float(sin(Double($0) * 0.1)) }
    let second = [Float](repeating: 0.5, count: 320)
    recorder.append(first)
    recorder.append(second)
    recorder.close()

    let file = dir.appendingPathComponent("test.wav")
    guard let audio = try? AVAudioFile(forReading: file) else {
        return ["\(name): wav did not open"]
    }
    let expected = AVAudioFramePosition(first.count + second.count)
    if audio.length != expected || Int(audio.fileFormat.sampleRate) != sampleRate || audio.fileFormat.channelCount != 1 {
        return ["\(name): got frames=\(audio.length) rate=\(audio.fileFormat.sampleRate) channels=\(audio.fileFormat.channelCount), expected frames=\(expected) rate=\(sampleRate) channels=1"]
    }
    return []
}

private func makeTestTranscription(segments: [WhisperSegment], text: String = "") -> WhisperTranscription {
    WhisperTranscription(task: nil, language: nil, duration: nil, text: text, segments: segments)
}

private func makeTestSegment(text: String, words: [String]) -> WhisperSegment {
    WhisperSegment(
        id: nil,
        text: text,
        start: 0,
        end: 0,
        words: words.map { WhisperWord(word: $0, start: 0, end: 0, probability: nil) }
    )
}
