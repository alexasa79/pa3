import AppKit
import SwiftUI

if CommandLine.arguments.contains("--audio-smoke-test") {
    Logger.setup()
    let seconds = smokeTestDuration()
    Logger.info("audio smoke test starting seconds=\(seconds)")
    let transcriber = TranscriberService()
    transcriber.startTranscribe(sendTo: { text in
        Logger.info("audio smoke transcription update chars=\(text.count)")
        print("TRANSCRIPTION:", text)
    }, skipWhisper: true)
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    transcriber.stopTranscribe()
    let snapshot = transcriber.debugSnapshot()
    let recDir = installationDirectory().appendingPathComponent("rec")
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

if CommandLine.arguments.contains("--whisper-text-test") {
    let failures = runWhisperTextTests()
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

private func smokeTestDuration() -> TimeInterval {
    guard let index = CommandLine.arguments.firstIndex(of: "--audio-smoke-test"),
          CommandLine.arguments.indices.contains(index + 1),
          let value = Double(CommandLine.arguments[index + 1]) else {
        return 3
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

    return failures
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
