import AppKit

@MainActor
func runScreenTextTests() async -> [String] {
    var failures = runScreenTextLayoutTests()
    failures += await runScreenHighlightTests()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pa3-ocr-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func fixture(_ name: String, lines: [String], dark: Bool = false) throws -> URL {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 300,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            (dark ? NSColor.black : NSColor.white).setFill()
            NSRect(x: 0, y: 0, width: 1200, height: 300).fill()
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: NSPoint(x: 40, y: 220 - index * 50), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 36), .foregroundColor: dark ? NSColor.white : NSColor.black])
            }
            NSGraphicsContext.restoreGraphicsState()
            let url = directory.appendingPathComponent(name + ".png")
            try bitmap.representation(using: .png, properties: [:])!.write(to: url)
            return url
        }
        let lines = ["The quiet garden waits for spring.", "A small bird sings beside the window."]
        for dark in [false, true] {
            let result = await ScreenText.recognize(try fixture(dark ? "dark" : "light", lines: lines, dark: dark))
            if result.text != lines.joined(separator: "\n") {
                failures.append("OCR recognizes both lines in reading order (dark=\(dark)): \(result.text ?? result.message)")
            }
        }
        // The user's two screenshots can also be checked without storing their documents in the repository.
        if let flag = CommandLine.arguments.firstIndex(of: "--screen-text-fixtures"), CommandLine.arguments.count > flag + 2 {
            let first = await ScreenText.recognize(URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
            if first.text?.contains("optimize") != true || first.text?.contains("immediately") != true {
                failures.append("Supplied print excerpt must join optimize and immediately: \(first.text ?? first.message)")
            }
            let second = await ScreenText.recognize(URL(fileURLWithPath: CommandLine.arguments[flag + 2]))
            if second.text?.hasPrefix("Abstract\n\n") != true {
                failures.append("Supplied abstract must separate its heading: \(second.text ?? second.message)")
            }
            if first.screenDocument?.spans.isEmpty != false || second.screenDocument?.spans.isEmpty != false {
                failures.append("Supplied screenshots must retain OCR boxes for highlighting")
            }
        }
        var permissionResult: SelectedTextResult?
        let denied = ScreenTextCapture(permission: { false }, makeProcess: { _ in
            failures.append("Denied permission must not launch capture")
            return Process()
        })
        denied.start(recognizing: { failures.append("Denied permission must not start OCR") },
                     completion: { permissionResult = $0 })
        if permissionResult?.text != nil || permissionResult?.message.contains("Screen Recording") != true {
            failures.append("Permission denial must explain how to enable capture")
        }

        let captureFixture = try fixture("capture", lines: lines)
        var captureURL: URL?
        let capture = ScreenTextCapture(permission: { true }, makeProcess: { image in
            captureURL = image
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/cp")
            process.arguments = [captureFixture.path, image.path]
            return process
        })
        var captured: SelectedTextResult?
        capture.start(recognizing: {}, completion: { captured = $0 })
        let deadline = Date().addingTimeInterval(5)
        while captured == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if captured?.text != lines.joined(separator: "\n") { failures.append("Capture output reaches OCR completion") }
        if let captureURL, FileManager.default.fileExists(atPath: captureURL.deletingLastPathComponent().path) {
            failures.append("Successful capture must delete its temporary directory")
        }

        // Cancel after capture but before OCR returns: a late result must not narrate.
        var enteredRecognition = false
        var staleCompletion = false
        capture.start(recognizing: { enteredRecognition = true; capture.cancel() },
                      completion: { _ in staleCompletion = true })
        let cancelDeadline = Date().addingTimeInterval(5)
        while !enteredRecognition && Date() < cancelDeadline { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(200))
        if !enteredRecognition || staleCompletion { failures.append("Cancelled OCR must suppress completion") }
        if let captureURL, FileManager.default.fileExists(atPath: captureURL.deletingLastPathComponent().path) {
            failures.append("Cancelled capture must delete its temporary directory")
        }
        // A subsequent request remains usable after cancellation.
        captured = nil
        capture.start(recognizing: {}, completion: { captured = $0 })
        let retryDeadline = Date().addingTimeInterval(5)
        while captured == nil && Date() < retryDeadline { try await Task.sleep(for: .milliseconds(10)) }
        if captured?.text == nil { failures.append("New capture must work after cancellation") }

        let selectedFrame = CGRect(x: -900, y: 180, width: 600, height: 150)
        let positionedCapture = ScreenTextCapture(permission: { true }, chooseRectangle: { $0(selectedFrame) }, makeProcess: { image in
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/cp")
            child.arguments = [captureFixture.path, image.path]
            return child
        })
        captured = nil
        positionedCapture.start(recognizing: {}, completion: { captured = $0 })
        let positionedDeadline = Date().addingTimeInterval(5)
        while captured == nil && Date() < positionedDeadline { try await Task.sleep(for: .milliseconds(10)) }
        if captured?.screenDocument?.frame != selectedFrame { failures.append("Capture must retain the picked screen rectangle for highlighting") }
        let cancelledPicker = ScreenTextCapture(permission: { true }, chooseRectangle: { $0(nil) }, makeProcess: { _ in
            failures.append("Cancelled rectangle picker must not start capture"); return Process()
        })
        captured = nil
        cancelledPicker.start(recognizing: {}, completion: { captured = $0 })
        if captured?.text != nil || captured?.message.contains("cancelled") != true { failures.append("Escape must cancel rectangle selection") }

        let blank = await ScreenText.recognize(try fixture("blank", lines: []))
        if blank.text != nil || !blank.message.contains("No text found") {
            failures.append("Blank screenshot must not produce narration")
        }
        let invalid = directory.appendingPathComponent("invalid.png")
        try Data("not an image".utf8).write(to: invalid)
        if await ScreenText.recognize(invalid).text != nil {
            failures.append("Invalid screenshot must not produce narration")
        }
        if await ScreenText.recognize(directory.appendingPathComponent("missing.png")).text != nil {
            failures.append("Cancelled/missing screenshot must not produce narration")
        }
    } catch { failures.append("OCR fixture failure: \(error)") }
    return failures
}

private func runScreenTextLayoutTests() -> [String] {
    var failures: [String] = []
    func line(_ text: String, _ y: Double, width: Double = 0.9, height: Double = 0.04, x: Double = 0.04) -> ScreenTextLine {
        let box = CGRect(x: x, y: y, width: width, height: height)
        return ScreenTextLine(text: text, box: box,
            spans: [ScreenTextSpan(range: NSRange(location: 0, length: text.utf16.count), box: box)])
    }
    let known: Set<String> = ["optimize", "immediately", "high", "performance", "the", "state", "of"]
    let document = ScreenText.layout([
        line("A high-performance tree should op-", 0.9),
        line("timize the case and imme-", 0.85),
        line("diately rewrite messages.", 0.8)
    ], knownWord: { known.contains($0) })
    if document.text != "A high-performance tree should optimize the case and immediately rewrite messages." {
        failures.append("Wrapped words must join without altering in-line compounds: \(document.text)")
    }
    let compound = ScreenText.layout([line("A high-", 0.9), line("performance tree.", 0.85)], knownWord: { known.contains($0) })
    if compound.text != "A high-performance tree." { failures.append("Keep a real compound across a line break") }
    let heading = ScreenText.layout([
        line("Abstract", 0.92, width: 0.15, height: 0.05),
        line("With multicores being ubiquitous,", 0.82), line("concurrent structures matter.", 0.77)
    ], knownWord: { _ in false })
    if heading.text != "Abstract\n\nWith multicores being ubiquitous,\nconcurrent structures matter." {
        failures.append("Geometry must separate a heading from wrapped body text")
    }
    if let pieces = try? NarrationText.plan(NarrationInput(text: heading.text)),
       pieces.first?.text != "Abstract" || (pieces.first?.pauseAfter ?? 0) < 0.6 {
        failures.append("Heading must be narrated separately with a paragraph pause")
    }
    let indented = ScreenText.layout([line("A paragraph ends here.", 0.9), line("Another paragraph begins.", 0.85, x: 0.09)], knownWord: { _ in false })
    if !indented.text.contains("\n\n") { failures.append("Indented paragraph must keep its pause") }
    let soft = ScreenText.layout([line("A technical\u{00ad}", 0.9), line("word continues.", 0.85)], knownWord: { _ in true })
    if soft.text != "A technicalword continues." { failures.append("Soft hyphens always join") }
    var positioned = document
    positioned.frame = CGRect(x: -1200, y: 200, width: 1000, height: 800)
    let word = (document.text as NSString).range(of: "optimize")
    let rects = positioned.rectangles(for: word)
    if rects.count != 2 || rects[0] != CGRect(x: -1160, y: 920, width: 900, height: 32) {
        failures.append("A joined word must highlight both fragments in global points, including a secondary display")
    }
    let capture = ScreenRectanglePicker.captureRect(CGRect(x: -100, y: 200, width: 50, height: 40), desktopTop: 900)
    if capture != CGRect(x: -100, y: 660, width: 50, height: 40) { failures.append("Screen capture coordinates must flip against the main display, retaining negative origins") }
    return failures
}
