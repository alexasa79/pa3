import AppKit

@MainActor
func runScreenTextTests() async -> [String] {
    var failures: [String] = []
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
                (line as NSString).draw(at: NSPoint(x: 40, y: 220 - index * 70), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 36), .foregroundColor: dark ? NSColor.white : NSColor.black])
            }
            NSGraphicsContext.restoreGraphicsState()
            let url = directory.appendingPathComponent(name + ".png")
            try bitmap.representation(using: .png, properties: [:])!.write(to: url)
            return url
        }
        let lines = ["The quiet garden waits for spring.", "A small bird sings beside the window."]
        for dark in [false, true] {
            let result = ScreenText.recognize(try fixture(dark ? "dark" : "light", lines: lines, dark: dark))
            if result.text != lines.joined(separator: "\n") {
                failures.append("OCR recognizes both lines in reading order (dark=\(dark)): \(result.text ?? result.message)")
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

        let blank = ScreenText.recognize(try fixture("blank", lines: []))
        if blank.text != nil || !blank.message.contains("No text found") {
            failures.append("Blank screenshot must not produce narration")
        }
        let invalid = directory.appendingPathComponent("invalid.png")
        try Data("not an image".utf8).write(to: invalid)
        if ScreenText.recognize(invalid).text != nil {
            failures.append("Invalid screenshot must not produce narration")
        }
        if ScreenText.recognize(directory.appendingPathComponent("missing.png")).text != nil {
            failures.append("Cancelled/missing screenshot must not produce narration")
        }
    } catch { failures.append("OCR fixture failure: \(error)") }
    return failures
}
