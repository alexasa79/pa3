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
