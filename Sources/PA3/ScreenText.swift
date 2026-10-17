import AppKit
import Vision
import ImageIO

struct ScreenTextSpan: Sendable {
    var range: NSRange
    let box: CGRect // Vision coordinates, normalized within the captured rectangle.
}

struct ScreenTextDocument: Sendable {
    let text: String
    let spans: [ScreenTextSpan]
    var frame: CGRect? // Global AppKit points, independent of screenshot pixel density.
    var sourceWindow: ScreenTextWindow?

    func rectangles(for range: NSRange) -> [CGRect] {
        guard let frame else { return [] }
        return spans.filter { NSIntersectionRange($0.range, range).length > 0 }.map {
            CGRect(x: frame.minX + $0.box.minX * frame.width,
                   y: frame.minY + $0.box.minY * frame.height,
                   width: $0.box.width * frame.width, height: $0.box.height * frame.height)
        }
    }
}

struct ScreenTextLine: Sendable {
    let text: String
    let box: CGRect
    var spans: [ScreenTextSpan] = []
}

enum ScreenText {
    /// Capture pixels never leave the OCR task. Only text and normalized positions survive.
    @MainActor
    static func recognize(_ url: URL) async -> SelectedTextResult {
        let lines: [ScreenTextLine]?
        do {
            lines = try await Task.detached(priority: .userInitiated) { () -> [ScreenTextLine]? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
                return try observations(in: image)
            }.value
        } catch {
            Logger.warn("Screen OCR failed: \(error.localizedDescription)")
            return SelectedTextResult(message: "Could not recognize the screen text. Try capturing it again.")
        }
        guard let lines else { return SelectedTextResult(message: "Could not read the screenshot. Try capturing the text again.") }
        guard !lines.isEmpty else { return SelectedTextResult(message: "No text found in that area. Try a tighter rectangle or larger text.") }
        guard lines.reduce(0, { $0 + $1.text.count + 2 }) <= 100_000 else {
            return SelectedTextResult(message: "Select a smaller area (less than 100,000 characters).")
        }
        let checker = NSSpellChecker.shared
        let document = layout(lines) { word in
            checker.checkSpelling(of: word, startingAt: 0, language: "en_US", wrap: false,
                                  inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
        return SelectedTextResult(text: document.text, message: "Reading screen text", screenDocument: document)
    }

    private static func observations(in image: CGImage) throws -> [ScreenTextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        let token = try NSRegularExpression(pattern: #"\S+"#)
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string
            let spans = token.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)).compactMap { match -> ScreenTextSpan? in
                guard let range = Range(match.range, in: text) else { return nil }
                let box = (try? candidate.boundingBox(for: range))?.boundingBox ?? observation.boundingBox
                return ScreenTextSpan(range: match.range, box: box)
            }
            return ScreenTextLine(text: text, box: observation.boundingBox, spans: spans)
        }
    }

    @MainActor
    static func recognizeImage(_ image: CGImage) async throws -> ScreenTextDocument {
        let lines = try await Task.detached(priority: .utility) { try observations(in: image) }.value
        let checker = NSSpellChecker.shared
        return layout(lines) { word in
            checker.checkSpelling(of: word, startingAt: 0, language: "en_US", wrap: false,
                                  inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
    }

    /// Preserve line geometry while repairing print-only word breaks. Paragraph boundaries
    /// stay explicit so NarrationText supplies its normal paragraph pause after headings.
    static func layout(_ lines: [ScreenTextLine], knownWord: (String) -> Bool) -> ScreenTextDocument {
        var text = "", spans: [ScreenTextSpan] = []
        let heights = lines.map(\.box.height).sorted()
        let bodyHeight = heights.isEmpty ? 0 : heights[heights.count / 2]
        for (index, line) in lines.enumerated() {
            if index > 0 {
                let previous = lines[index - 1]
                let gap = previous.box.minY - line.box.maxY
                let short = previous.text.count < 100 && previous.box.width < line.box.width * 0.75
                let heading = short && (previous.box.height > line.box.height * 1.18 || gap > bodyHeight * 0.55)
                let paragraph = gap > bodyHeight * 0.85 || line.box.minX - previous.box.minX > bodyHeight * 0.8
                if !heading && !paragraph, let join = wrappedJoin(previous.text, line.text, knownWord: knownWord) {
                    if join { // Remove the typographic hyphen, retaining boxes for both word fragments.
                        text.removeLast()
                        let end = text.utf16.count
                        for i in spans.indices where NSMaxRange(spans[i].range) > end {
                            spans[i].range.length = max(0, end - spans[i].range.location)
                        }
                    }
                } else { text += heading || paragraph ? "\n\n" : "\n" }
            }
            let offset = text.utf16.count
            text += line.text
            spans += line.spans.map { ScreenTextSpan(range: NSRange(location: offset + $0.range.location, length: $0.range.length), box: $0.box) }
        }
        return ScreenTextDocument(text: text, spans: spans)
    }

    private static func wrappedJoin(_ previous: String, _ next: String, knownWord: (String) -> Bool) -> Bool? {
        guard let hyphen = previous.last, "-‐\u{00ad}".contains(hyphen), next.first?.isLowercase == true else { return nil }
        let left = String(previous.dropLast().reversed().prefix(while: { $0.isLetter }).reversed())
        let right = String(next.prefix(while: { $0.isLetter }))
        guard !left.isEmpty, !right.isEmpty else { return nil }
        if hyphen == "\u{00ad}" || knownWord(left + right) { return true }
        // Preserve real compounds; unknown technical words still lose print-only hyphens
        // when at least one fragment is not an ordinary word.
        return !(knownWord(left) && knownWord(right))
    }
}

/// The picker records screen points so OCR boxes can be placed over the source text.
/// Each request owns its temporary directory until capture and OCR both finish.
@MainActor
final class ScreenTextCapture {
    private var process: Process?
    private var requestID: UUID?
    private var captureDirectory: URL?
    private let permission: () -> Bool
    private let makeProcess: (URL, CGRect?) -> Process
    private let requiresRectangle: Bool
    private let chooseRectangle: (@escaping @MainActor (CGRect?) -> Void) -> Void
    private var picker: ScreenRectanglePicker?

    init(permission: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() },
         chooseRectangle: ((@escaping @MainActor (CGRect?) -> Void) -> Void)? = nil,
         makeProcess: ((URL) -> Process)? = nil) {
        self.permission = permission
        self.chooseRectangle = chooseRectangle ?? { $0(nil) }
        self.requiresRectangle = chooseRectangle != nil || makeProcess == nil
        self.makeProcess = { image, frame in
            if let makeProcess { return makeProcess(image) }
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            child.arguments = ["-x", "-t", "png"]
            if let frame {
                let rect = ScreenRectanglePicker.captureRect(frame, desktopTop: NSScreen.screens.first?.frame.maxY ?? 0)
                child.arguments?.append("-R\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))")
            }
            child.arguments?.append(image.path)
            return child
        }
        if chooseRectangle == nil && makeProcess == nil { picker = ScreenRectanglePicker() }
    }

    func cancel() {
        requestID = nil
        picker?.cancel()
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
        let selected: @MainActor (CGRect?) -> Void = { [weak self] frame in
            guard let self, self.requestID == id else { return }
            if self.requiresRectangle && frame == nil {
                self.requestID = nil
                completion(SelectedTextResult(message: "Screen capture cancelled."))
                return
            }
            // Let selection panels disappear before capturing their underlying pixels.
            Task { @MainActor in
                if frame != nil { try? await Task.sleep(for: .milliseconds(100)) }
                guard self.requestID == id else { return }
                self.capture(id: id, frame: frame, recognizing: recognizing, completion: completion)
            }
        }
        if let picker { picker.start(completion: selected) }
        else { chooseRectangle(selected) }
    }

    private func capture(id: UUID, frame: CGRect?, recognizing: @escaping @MainActor () -> Void,
                         completion: @escaping @MainActor (SelectedTextResult) -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pa3-screen-\(id)", isDirectory: true)
        let image = directory.appendingPathComponent("selection.png")
        captureDirectory = directory
        let sourceWindow = frame.flatMap(ScreenTextWindow.containing)
        let child = makeProcess(image, frame)
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
                var result = await ScreenText.recognize(image)
                try? FileManager.default.removeItem(at: directory)
                result.screenDocument?.frame = frame
                result.screenDocument?.sourceWindow = sourceWindow
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
