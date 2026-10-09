import AppKit
import Vision
import ImageIO

/// Vision runs off the main thread and returns only text, never the captured image.
enum ScreenText {
    static func recognize(_ url: URL) -> SelectedTextResult {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return SelectedTextResult(message: "Could not read the screenshot. Try capturing the text again.")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
            // Vision returns observations in reading order. Keep line boundaries;
            // narration normalizes whitespace without losing sentence punctuation.
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return SelectedTextResult(message: "No text found in that area. Try a tighter rectangle or larger text.")
            }
            guard text.count <= 100_000 else {
                return SelectedTextResult(message: "Select a smaller area (less than 100,000 characters).")
            }
            return SelectedTextResult(text: text, message: "Reading screen text")
        } catch {
            Logger.warn("Screen OCR failed: \(error.localizedDescription)")
            return SelectedTextResult(message: "Could not recognize the screen text. Try capturing it again.")
        }
    }
}

/// The system picker handles Retina displays, multiple monitors, dragging, and Escape.
/// Each request owns its temporary directory until capture and OCR both finish.
@MainActor
final class ScreenTextCapture {
    private var process: Process?
    private var requestID: UUID?
    private var captureDirectory: URL?
    private let permission: () -> Bool
    private let makeProcess: (URL) -> Process

    init(permission: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() },
         makeProcess: @escaping (URL) -> Process = { image in
             let child = Process()
             child.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
             child.arguments = ["-i", "-s", "-x", "-t", "png", image.path]
             return child
         }) {
        self.permission = permission
        self.makeProcess = makeProcess
    }

    func cancel() {
        requestID = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        if let captureDirectory { try? FileManager.default.removeItem(at: captureDirectory) }
        captureDirectory = nil
    }

    func start(recognizing: @escaping @MainActor () -> Void,
               completion: @escaping @MainActor (SelectedTextResult) -> Void) {
        cancel()
        guard permission() else {
            completion(SelectedTextResult(message: "Allow PA3 in System Settings → Privacy & Security → Screen Recording, then try again. You may need to reopen PA3."))
            return
        }
        let id = UUID()
        requestID = id
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pa3-screen-\(id)", isDirectory: true)
        let image = directory.appendingPathComponent("selection.png")
        captureDirectory = directory
        let child = makeProcess(image)
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                guard let self, self.requestID == id else {
                    try? FileManager.default.removeItem(at: directory)
                    return
                }
                self.process = nil
                guard finished.terminationStatus == 0, FileManager.default.fileExists(atPath: image.path) else {
                    try? FileManager.default.removeItem(at: directory)
                    self.captureDirectory = nil
                    self.requestID = nil
                    Logger.info("Screen capture ended status=\(finished.terminationStatus)")
                    completion(SelectedTextResult(message: "Screen capture cancelled or unavailable. Try again and release the shortcut keys before dragging."))
                    return
                }
                recognizing()
                let result = await Task.detached(priority: .userInitiated) {
                    defer { try? FileManager.default.removeItem(at: directory) }
                    return ScreenText.recognize(image)
                }.value
                guard self.requestID == id else { return }
                self.captureDirectory = nil
                self.requestID = nil
                completion(result)
            }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            process = child
            try child.run()
        } catch {
            process = nil
            requestID = nil
            captureDirectory = nil
            try? FileManager.default.removeItem(at: directory)
            Logger.warn("Screen capture could not start: \(error.localizedDescription)")
            completion(SelectedTextResult(message: "Could not start screen capture. Try again."))
        }
    }
}
