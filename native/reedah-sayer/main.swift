import Foundation

final class NativeMessenger {
  private let stdinHandle = FileHandle.standardInput
  private let stdoutHandle = FileHandle.standardOutput
  private let stderrHandle = FileHandle.standardError
  private let writeQueue = DispatchQueue(label: "reedah.native.write")

  func log(_ message: String) {
    if let data = (message + "\n").data(using: .utf8) {
      stderrHandle.write(data)
    }
  }

  func send(_ payload: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
      log("ReedahNative: Failed to encode payload.")
      return
    }

    var length = UInt32(data.count).littleEndian
    let header = Data(bytes: &length, count: 4)

    writeQueue.async {
      self.stdoutHandle.write(header)
      self.stdoutHandle.write(data)
    }
  }

  func readMessage() -> [String: Any]? {
    guard let lengthData = readExact(byteCount: 4) else { return nil }
    if lengthData.count < 4 { return nil }

    let length = lengthData.withUnsafeBytes { pointer -> UInt32 in
      pointer.load(as: UInt32.self)
    }
    let messageLength = Int(UInt32(littleEndian: length))

    guard messageLength > 0 else { return nil }
    guard let messageData = readExact(byteCount: messageLength) else { return nil }

    do {
      let json = try JSONSerialization.jsonObject(with: messageData, options: [])
      return json as? [String: Any]
    } catch {
      log("ReedahNative: Failed to decode message JSON.")
      return nil
    }
  }

  private func readExact(byteCount: Int) -> Data? {
    var buffer = Data()
    buffer.reserveCapacity(byteCount)

    while buffer.count < byteCount {
      let remaining = byteCount - buffer.count
      let chunk = stdinHandle.readData(ofLength: remaining)
      if chunk.isEmpty { return nil }
      buffer.append(chunk)
    }

    return buffer
  }
}

struct SentenceRange {
  let start: Int
  let end: Int
}

enum SpeechResult {
  case ok
  case cancelled
  case failed
}

final class ReedahSayer {
  private let messenger: NativeMessenger
  private let speechQueue = DispatchQueue(label: "reedah.native.speech")
  private let stateLock = NSLock()
  private var currentProcess: Process?
  private var cancelRequested = false
  private var activeUtteranceId: String?

  init(messenger: NativeMessenger) {
    self.messenger = messenger
  }

  func speak(text: String, utteranceId: String, voiceHint: String?, rate: Double?, sentenceRanges: [SentenceRange]) {
    speechQueue.async { [weak self] in
      self?.runSpeech(text: text, utteranceId: utteranceId, voiceHint: voiceHint, rate: rate, sentenceRanges: sentenceRanges)
    }
  }

  func stop() {
    stateLock.lock()
    cancelRequested = true
    let process = currentProcess
    stateLock.unlock()
    process?.terminate()
  }

  private func runSpeech(text: String, utteranceId: String, voiceHint: String?, rate: Double?, sentenceRanges: [SentenceRange]) {
    stateLock.lock()
    cancelRequested = false
    activeUtteranceId = utteranceId
    stateLock.unlock()

    guard !text.isEmpty else {
      sendError("empty_text", utteranceId: utteranceId)
      return
    }

    guard !sentenceRanges.isEmpty else {
      sendError("missing_sentence_ranges", utteranceId: utteranceId)
      return
    }

    let voiceLabel = (voiceHint?.isEmpty == false) ? voiceHint! : "system-default"
    messenger.send([
      "event": "started",
      "utteranceId": utteranceId,
      "voiceName": voiceLabel,
      "voiceIdentifier": voiceLabel
    ])

    let nsText = text as NSString
    let maxLength = nsText.length
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("reedah-\(utteranceId)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    } catch {
      sendError("tempdir_failed", utteranceId: utteranceId, details: error.localizedDescription)
      return
    }

    defer {
      try? FileManager.default.removeItem(at: tempDir)
    }

    for (index, range) in sentenceRanges.enumerated() {
      if isCancelled() {
        sendCancelled(utteranceId: utteranceId)
        return
      }

      let start = max(0, min(range.start, maxLength))
      let end = max(start, min(range.end, maxLength))
      let length = end - start
      if length == 0 { continue }

      let sentence = nsText.substring(with: NSRange(location: start, length: length))
      if sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }

      let result = runSay(
        sentence: sentence,
        voiceHint: voiceHint,
        rate: rate,
        utteranceId: utteranceId,
        tempDir: tempDir,
        index: index,
        location: start,
        length: length
      )
      switch result {
      case .ok:
        continue
      case .cancelled:
        sendCancelled(utteranceId: utteranceId)
        return
      case .failed:
        return
      }
    }

    if isCancelled() {
      sendCancelled(utteranceId: utteranceId)
      return
    }

    messenger.send([
      "event": "finished",
      "utteranceId": utteranceId
    ])
  }

  private func runSay(
    sentence: String,
    voiceHint: String?,
    rate: Double?,
    utteranceId: String,
    tempDir: URL,
    index: Int,
    location: Int,
    length: Int
  ) -> SpeechResult {
    if isCancelled() { return .cancelled }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    let outputURL = tempDir.appendingPathComponent("sentence-\(index).m4a")
    defer {
      try? FileManager.default.removeItem(at: outputURL)
    }

    var arguments: [String] = []
    arguments.append("--file-format=m4af")
    arguments.append("--data-format=aac")
    arguments.append("-o")
    arguments.append(outputURL.path)
    if let voiceHint = voiceHint, !voiceHint.isEmpty {
      arguments.append("-v")
      arguments.append(voiceHint)
    }
    if let rate = rate {
      let wpm = mapRate(rate)
      arguments.append("-r")
      arguments.append(String(wpm))
    }
    arguments.append(sentence)
    process.arguments = arguments

    let stderrPipe = Pipe()
    process.standardError = stderrPipe

    stateLock.lock()
    currentProcess = process
    stateLock.unlock()

    do {
      try process.run()
    } catch {
      stateLock.lock()
      currentProcess = nil
      stateLock.unlock()
      sendError("say_launch_failed", utteranceId: utteranceId, details: error.localizedDescription)
      return .failed
    }

    process.waitUntilExit()

    stateLock.lock()
    currentProcess = nil
    stateLock.unlock()

    if isCancelled() { return .cancelled }

    if process.terminationStatus != 0 {
      let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
      let errorMessage = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
      if let errorMessage, !errorMessage.isEmpty {
        sendError("say_failed", utteranceId: utteranceId, details: errorMessage)
      } else {
        sendError("say_failed", utteranceId: utteranceId)
      }
      return .failed
    }

    if isCancelled() { return .cancelled }

    do {
      let data = try Data(contentsOf: outputURL)
      let base64 = data.base64EncodedString()
      messenger.send([
        "event": "audio",
        "utteranceId": utteranceId,
        "index": index,
        "location": location,
        "length": length,
        "mimeType": "audio/mp4",
        "audioBase64": base64
      ])
    } catch {
      sendError("audio_read_failed", utteranceId: utteranceId, details: error.localizedDescription)
      return .failed
    }

    try? FileManager.default.removeItem(at: outputURL)

    return .ok
  }

  private func mapRate(_ value: Double) -> Int {
    let clamped = min(max(value, 0), 1)
    let minWpm = 120.0
    let maxWpm = 260.0
    let mapped = minWpm + (maxWpm - minWpm) * clamped
    return Int(mapped.rounded())
  }

  private func isCancelled() -> Bool {
    stateLock.lock()
    let cancelled = cancelRequested
    stateLock.unlock()
    return cancelled
  }

  private func sendCancelled(utteranceId: String) {
    messenger.send([
      "event": "cancelled",
      "utteranceId": utteranceId
    ])
  }

  private func sendError(_ code: String, utteranceId: String, details: String? = nil) {
    var payload: [String: Any] = [
      "event": "error",
      "message": code,
      "utteranceId": utteranceId
    ]
    if let details, !details.isEmpty {
      payload["details"] = details
    }
    messenger.send(payload)
  }

}

let messenger = NativeMessenger()
let sayer = ReedahSayer(messenger: messenger)

DispatchQueue.global(qos: .userInitiated).async {
  while let message = messenger.readMessage() {
    guard let action = message["action"] as? String else {
      messenger.send([
        "event": "error",
        "message": "missing_action",
        "utteranceId": ""
      ])
      continue
    }

    if action == "speak" {
      let text = (message["text"] as? String) ?? ""
      let utteranceId = (message["utteranceId"] as? String) ?? UUID().uuidString
      let voiceHint = (message["voice"] as? String) ?? ""
      let rateValue = message["rate"]
      let rate: Double?
      if let rateValue = rateValue as? Double {
        rate = rateValue
      } else if let rateValue = rateValue as? String, let parsed = Double(rateValue) {
        rate = parsed
      } else {
        rate = nil
      }

      let rangesRaw = message["sentenceRanges"] as? [[String: Any]] ?? []
      let ranges = rangesRaw.compactMap { entry -> SentenceRange? in
        guard let start = entry["start"] as? Int else { return nil }
        guard let end = entry["end"] as? Int else { return nil }
        return SentenceRange(start: start, end: end)
      }

      sayer.speak(text: text, utteranceId: utteranceId, voiceHint: voiceHint, rate: rate, sentenceRanges: ranges)
      continue
    }

    if action == "stop" {
      sayer.stop()
      continue
    }

    messenger.send([
      "event": "error",
      "message": "unknown_action",
      "utteranceId": ""
    ])
  }

  DispatchQueue.main.async {
    exit(0)
  }
}

RunLoop.main.run()
