import AppKit
import ImageIO

@MainActor
private final class HighlightSnapshotCell {
    var value: ScreenHighlightSnapshot
    var document: ScreenTextDocument?
    var delayVerification = false
    var failVerification = false
    var verification: CheckedContinuation<ScreenTextDocument, Never>?
    init(_ value: ScreenHighlightSnapshot) { self.value = value }
}

@MainActor
func runScreenHighlightTests() async -> [String] {
    var failures: [String] = []
    func expect(_ condition: Bool, _ name: String) { if !condition { failures.append(name) } }
    // Check the real picker and Escape handler without waiting for user input.
    let previousCursor = NSCursor.current
    let picker = ScreenRectanglePicker()
    var pickerCancelled = false
    picker.start { pickerCancelled = $0 == nil }
    let activationDeadline = Date().addingTimeInterval(2)
    while (NSApp.keyWindow == nil || !NSApp.isActive) && Date() < activationDeadline { try? await Task.sleep(for: .milliseconds(10)) }
    expect(NSApp.isActive && NSApp.keyWindow?.title == "Select text to narrate", "Picker must own keyboard focus and the visible cursor")
    expect(NSCursor.current == NSCursor.crosshair, "Opening rectangle selection must immediately set the crosshair")
    if let window = NSApp.keyWindow,
       let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53) {
        window.firstResponder?.keyDown(with: escape)
        expect(pickerCancelled && NSCursor.current == previousCursor, "Escape must cancel selection and restore the previous cursor")
    } else { failures.append("Rectangle picker must accept Escape") }
    picker.cancel()
    picker.start { _ in failures.append("Programmatic cancellation must not complete a selection") }
    picker.cancel()
    expect(NSCursor.current == previousCursor, "Cancelling a pending capture must restore the previous cursor")
    func document(_ text: String, frame: CGRect = CGRect(x: -600, y: 100, width: 500, height: 300), y: Double = 0.5) -> ScreenTextDocument {
        let tokens = ScreenTextRelocation.words(text)
        let spans = tokens.enumerated().map { i, word in
            ScreenTextSpan(range: word.range, box: CGRect(x: 0.02 + Double(i % 8) * 0.1, y: y - Double(i / 8) * 0.08, width: 0.08, height: 0.05))
        }
        return ScreenTextDocument(text: text, spans: spans, frame: frame, sourceWindow: ScreenTextWindow(id: 1, pid: 2))
    }
    let text = "A quiet garden waits for spring. Another small bird sings beside the window."
    let original = document(text)
    let moved = document(text, frame: CGRect(x: 200, y: 150, width: 800, height: 500), y: 0.8)
    let focus = (text as NSString).range(of: "garden")
    let match = ScreenTextRelocation(source: original, current: moved)
    expect(match.contains(focus), "Unique surrounding words must relocate the source word after scrolling and resizing")
    expect(match.document.rectangles(for: focus) == moved.rectangles(for: focus), "Relocation must use fresh screen geometry, never a wheel delta")
    let offscreen = document("Another small bird sings beside the window.")
    expect(!ScreenTextRelocation(source: original, current: offscreen).contains(focus), "An offscreen passage must have no highlight")
    let repeated = document(text + " " + text)
    expect(!ScreenTextRelocation(source: original, current: repeated).contains(focus), "Repeated visible passages must remain ambiguous")
    let unrelated = document("A different garden has unrelated surrounding words and controls.")
    expect(!ScreenTextRelocation(source: original, current: unrelated).contains(focus), "A repeated isolated word is not evidence of source position")
    let short = document("garden waits")
    expect(!ScreenTextRelocation(source: short, current: short).contains(NSRange(location: 0, length: 6)), "Fewer than three words cannot establish a new position")
    let symbols = document("The parameter ε ranges between 0 and 1. A careful reader follows the complete sentence.")
    let confused = document("The parameter e ranges between 0 and 1. A careful reader follows the complete sentence.")
    let symbolMatch = ScreenTextRelocation(source: symbols, current: confused)
    expect(symbolMatch.matchedWords.count == symbolMatch.sourceWords.count, "Anchored math-glyph OCR differences must not drop sentence beginnings or neighboring words")
    let split = ScreenTextRelocation(source: document("Parameter epsilon ranges between zero and one in this paragraph."),
        current: document("Param eter epsilon ranges between zero and one in this paragraph."))
    expect(split.matchedWords.count == split.sourceWords.count && split.document.rectangles(for: NSRange(location: 0, length: 9)).count == 2,
           "An anchored word split across OCR tokens must retain both rectangles")
    let changedLabels = ScreenTextRelocation(source: document("a b c d e. A careful reader follows the complete sentence."),
        current: document("v w x y z. A careful reader follows the complete sentence."))
    expect(!changedLabels.contains(NSRange(location: 0, length: 9)), "A matching suffix must not validate a different sequence of short labels")
    let wrapped = "A sentence wraps across\nseveral visual lines before ending. Next sentence."
    let wrappedFocus = (wrapped as NSString).range(of: "wraps")
    let wrappedRange = ScreenHighlightGeometry.sentenceRange(in: wrapped, containing: wrappedFocus)
    expect((wrapped as NSString).substring(with: wrappedRange).contains("before ending."), "Sentence background must span visual wraps")
    let s1 = "An alpha sentence starts here today. A beta sentence finishes over there tomorrow."
    let s2 = "A beta sentence finishes over there tomorrow. An alpha sentence starts here today."
    expect(ScreenTextRelocation(source: document(s1), current: document(s2)).matchedWords.isEmpty, "Conflicting reading order must reject relocation")

    let rect = CGRect(x: 10, y: 20, width: 40, height: 15)
    expect(ScreenHighlightGeometry.paintRect(rect).midY == rect.midY + 2, "Raise highlight geometry two screen points without moving text")
    // Equal-font rows with different ink bounds and small OCR margin errors.
    let rowBoxes = [CGRect(x: 210, y: 190, width: 140, height: 18),
                    CGRect(x: 50.8, y: 162, width: 300, height: 16),
                    CGRect(x: 49.4, y: 132, width: 302, height: 21),
                    CGRect(x: 50.2, y: 104, width: 180, height: 18)]
    let rowFocus = CGRect(x: 70, y: 163, width: 40, height: 14)
    let normalized = ScreenHighlightGeometry.layout(sentence: rowBoxes, focus: [rowFocus])
    expect(Set(normalized.sentence.map(\.height)).count == 1, "Uniform-size text must have equal highlight heights despite OCR ink variation")
    expect(Set(normalized.sentence.dropFirst().map(\.minX)).count == 1, "Continuation rows must share a stable left margin despite small OCR errors")
    expect(normalized.sentence[0].minX == 209, "A sentence starting mid-line must keep its actual start")
    expect(normalized.sentence[3].maxX == rowBoxes[3].maxX + 1, "The final row must end at the sentence's final word")
    expect(normalized.focus[0].minY == normalized.sentence[1].minY && normalized.focus[0].height == normalized.sentence[1].height,
           "Word focus must use its row's height and vertical position")
    for pair in zip(normalized.sentence, normalized.sentence.dropFirst()) {
        expect(pair.0.minY > pair.1.maxY, "Neighboring highlight rows must not overlap")
    }
    let shortWrap = ScreenHighlightGeometry.layout(sentence: [CGRect(x: 340, y: 200, width: 60, height: 16),
        CGRect(x: 50, y: 170, width: 200, height: 20)], focus: [])
    expect(shortWrap.sentence.count == 2 && shortWrap.sentence[0].height == shortWrap.sentence[1].height,
           "A short sentence wrapping from the far right to the far left must share row height")
    let indents = ScreenHighlightGeometry.layout(sentence: [rowBoxes[0], rowBoxes[1], CGRect(x: 80, y: 132, width: 270, height: 18)], focus: [])
    expect(indents.sentence[1].minX != indents.sentence[2].minX, "Real indentation must not be snapped to another margin")
    let mixed = ScreenHighlightGeometry.layout(sentence: [CGRect(x: 50, y: 230, width: 200, height: 38)] + rowBoxes, focus: [])
    expect(mixed.sentence.first!.height > mixed.sentence.last!.height, "Larger heading text must keep its own highlight height")
    let columns = ScreenHighlightGeometry.layout(sentence: [CGRect(x: 10, y: 60, width: 100, height: 16), CGRect(x: 300, y: 60, width: 100, height: 24)],
        focus: [CGRect(x: 320, y: 60, width: 20, height: 24)])
    expect(columns.sentence.count == 2 && columns.focus[0].height == 28, "Separate columns must keep their geometry and word focus")
    let paragraph = "Abstract\n\nThe first sentence. The next sentence."
    let second = (paragraph as NSString).range(of: "next")
    let sentence = ScreenHighlightGeometry.sentenceRange(in: paragraph, containing: second)
    expect((paragraph as NSString).substring(with: sentence).trimmingCharacters(in: .whitespacesAndNewlines) == "The next sentence.", "Sentence background must stay within the current sentence")
    expect(ScreenHighlightGeometry.sentenceRange(in: paragraph, containing: NSRange(location: 0, length: 8)) == NSRange(location: 0, length: 8), "Heading highlight must remain separate from body text")

    func image(_ dark: Bool, corner: Bool = false) -> CGImage {
        let context = CGContext(data: nil, width: 500, height: 300, bitsPerComponent: 8, bytesPerRow: 2000,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor((dark ? NSColor.black : NSColor.white).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 500, height: 300))
        context.setFillColor((dark ? NSColor.white : NSColor.black).cgColor)
        context.fill(CGRect(x: 100, y: 140, width: 40, height: 10))
        context.setFillColor(NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1).cgColor)
        context.fill(CGRect(x: 200, y: 140, width: 40, height: 10))
        if corner {
            context.setFillColor(NSColor.red.cgColor)
            context.fill(CGRect(x: 480, y: 280, width: 10, height: 10))
        }
        return context.makeImage()!
    }
    for dark in [false, true] {
        let snapshot = ScreenHighlightSnapshot(image: image(dark), frame: original.frame!, visibleRegions: [original.frame!])
        guard let art = ScreenHighlightArtwork(snapshot: snapshot, sampleRects: [CGRect(x: -500, y: 240, width: 40, height: 10)]) else {
            failures.append("Could not render highlight artwork"); continue
        }
        expect(art.palette.dark == dark, "Highlight theme must follow the captured page background")
        let bitmap = NSBitmapImageRep(cgImage: art.sentence.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        let originalBitmap = NSBitmapImageRep(cgImage: snapshot.image)
        let inkY = (0..<300).first { y in
            let red = originalBitmap.colorAt(x: 115, y: y)!.usingColorSpace(.sRGB)!.redComponent
            return dark ? red > 0.98 : red < 0.02
        }!
        let ink = bitmap.colorAt(x: 115, y: inkY)!.usingColorSpace(.sRGB)!
        expect(dark ? ink.redComponent > 0.98 : ink.redComponent < 0.02, "Gray highlight must preserve source glyphs instead of covering them")
        let blue = bitmap.colorAt(x: 215, y: inkY)!.usingColorSpace(.sRGB)!
        expect(blue.blueComponent > 0.98 && blue.redComponent < 0.02, "Highlight shading must preserve colored source text")
        let background = bitmap.colorAt(x: 10, y: 10)!.usingColorSpace(.sRGB)!
        let expected = dark ? 55 / 255.0 * 0.91 : (221 / 255.0 * 0.93 + 0.07)
        expect(abs(background.redComponent - expected) < 0.015, "Sentence background must match Chrome's sRGB composite")
    }
    if let css = try? String(contentsOfFile: "chrome-extension/content.css", encoding: .utf8) {
        expect(css.contains("rgba(221, 215, 202, 0.93)") && css.contains("rgba(55, 57, 52, 0.91)") && css.contains("--reedah-word-focus-opacity: 0.26") && css.contains("--reedah-word-focus-opacity: 0.3"), "Native palette contract must match the extension stylesheet")
    }

    let snapshot = ScreenHighlightSnapshot(image: image(false), frame: original.frame!, visibleRegions: [original.frame!])
    var updates: [Bool] = [], calls = 0
    let latestSnapshot = HighlightSnapshotCell(snapshot)
    let tracker = ScreenHighlightTracker(source: original, capture: { _ in latestSnapshot.value }, recognize: { _ in calls += 1; return moved }, onUpdate: { match, _ in updates.append(match != nil) })
    await tracker.refresh()
    expect(updates.last == true && calls == 1, "A verified snapshot must publish fresh positions")
    await tracker.refresh()
    expect(calls == 1, "Unchanged pixels must reuse verified OCR geometry")
    latestSnapshot.value = ScreenHighlightSnapshot(image: image(false, corner: true), frame: original.frame!, visibleRegions: [original.frame!])
    await tracker.refresh()
    expect(calls == 1, "Animation outside the selected passage must not trigger OCR or hide its highlight")
    tracker.invalidate()
    expect(updates.last == true, "Input must retain the verified highlight while a replacement is located")
    try? await Task.sleep(for: .milliseconds(200))
    await tracker.refresh()
    expect(updates.last == true, "An unchanged verified surface can recover after interaction")
    tracker.stop()
    expect(updates.last == false, "Stopping must remove the overlay")

    // A changed passage must remain highlighted throughout slow verification.
    let verificationScene = HighlightSnapshotCell(snapshot)
    var verificationCalls = 0, verificationUpdates: [Bool] = []
    let continuous = ScreenHighlightTracker(source: original, capture: { _ in verificationScene.value }, recognize: { _ in
        verificationCalls += 1
        if verificationScene.failVerification { throw NarrationText.Invalid("temporary OCR failure") }
        if verificationScene.delayVerification {
            return await withCheckedContinuation { verificationScene.verification = $0 }
        }
        return original
    }, onUpdate: { match, _ in verificationUpdates.append(match != nil) })
    continuous.focusRange = focus
    await continuous.refresh()
    verificationScene.value = ScreenHighlightSnapshot(image: image(true), frame: original.frame!, visibleRegions: [original.frame!])
    verificationScene.delayVerification = true
    let verifying = Task { await continuous.refresh() }
    while verificationScene.verification == nil { await Task.yield() }
    expect(verificationCalls == 2 && verificationUpdates == [true], "Changed pixels must trigger OCR without hiding the verified highlight while it waits")
    verificationScene.verification?.resume(returning: original)
    await verifying.value
    expect(verificationUpdates == [true, true], "Fresh geometry must replace the old highlight without an intervening blank")
    verificationScene.delayVerification = false
    verificationScene.failVerification = true
    verificationScene.value = snapshot
    await continuous.refresh()
    expect(verificationCalls == 3 && verificationUpdates == [true, true], "Transient OCR errors must retain the last verified highlight")
    verificationScene.failVerification = false
    await continuous.refresh()
    expect(verificationCalls == 4 && verificationUpdates == [true, true, true], "Verification must recover after a transient error without blinking")
    continuous.stop()

    // Some source words can remain visible while the focused passage is offscreen.
    // Their stable pixels must never prevent a full search when the passage returns.
    let scene = HighlightSnapshotCell(snapshot)
    scene.document = moved
    var recovered = false
    let recovery = ScreenHighlightTracker(source: original, capture: { _ in scene.value }, recognize: { _ in scene.document! },
        onUpdate: { match, _ in recovered = match?.contains(focus) == true })
    recovery.focusRange = focus
    await recovery.refresh()
    expect(recovered, "Recovery fixture must initially locate the current word")
    scene.value = ScreenHighlightSnapshot(image: image(true), frame: original.frame!, visibleRegions: [original.frame!])
    scene.document = offscreen
    await recovery.refresh()
    expect(!recovered, "Remaining source words cannot justify highlighting a missing current word")
    scene.value = snapshot
    scene.document = moved
    await recovery.refresh()
    expect(recovered, "A missing current word must trigger a full search when content changes elsewhere")
    recovery.stop()

    var continuation: CheckedContinuation<ScreenTextDocument, Never>?
    var lateUpdates: [Bool] = []
    let delayed = ScreenHighlightTracker(source: original, capture: { _ in snapshot }, recognize: { _ in
        await withCheckedContinuation { continuation = $0 }
    }, onUpdate: { match, _ in lateUpdates.append(match != nil) })
    let pending = Task { await delayed.refresh() }
    while continuation == nil { await Task.yield() }
    delayed.invalidate()
    continuation?.resume(returning: moved)
    await pending.value
    expect(!lateUpdates.contains(true), "Late OCR after another scroll must not restore stale positions")
    delayed.stop()
    if let flag = CommandLine.arguments.firstIndex(of: "--screen-text-fixtures"), CommandLine.arguments.count > flag + 1 {
        do { try await renderScreenHighlightPreview(URL(fileURLWithPath: CommandLine.arguments[flag + 1])) }
        catch { failures.append("Highlight preview could not render: \(error)") }
    }
    if let flag = CommandLine.arguments.firstIndex(of: "--screen-highlight-fixture"), CommandLine.arguments.count > flag + 2 {
        let url = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
        let expected = CommandLine.arguments[flag + 2]
        let result = await ScreenText.recognize(url)
        if var doc = result.screenDocument {
            doc.frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
            let last = ScreenTextRelocation.words(doc.text).last
            expect(last?.text == expected, "Screenshot OCR must retain its final word")
            if let last {
                let relocated = ScreenTextRelocation(source: doc, current: doc)
                expect(relocated.contains(last.range) && !relocated.document.rectangles(for: last.range).isEmpty,
                       "The final screenshot word must retain a relocatable highlight rectangle")
            }
        } else { failures.append("Could not recognize supplied highlight fixture") }
    }
    if let flag = CommandLine.arguments.firstIndex(of: "--screen-highlight-rows-fixture"), CommandLine.arguments.count > flag + 6 {
        do {
            let args = CommandLine.arguments
            let url = URL(fileURLWithPath: args[flag + 1])
            let values = (2...5).compactMap { Double(args[flag + $0]) }
            guard values.count == 4, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let crop = image.cropping(to: CGRect(x: values[0], y: values[1], width: values[2], height: values[3])) else {
                throw NarrationText.Invalid("Invalid row fixture region")
            }
            var doc = try await ScreenText.recognizeImage(crop)
            doc.frame = CGRect(x: 0, y: 0, width: crop.width, height: crop.height)
            let focus = (doc.text as NSString).range(of: args[flag + 6])
            guard focus.location != NSNotFound else { throw NarrationText.Invalid("Row fixture phrase missing: \(doc.text)") }
            let range = ScreenHighlightGeometry.sentenceRange(in: doc.text, containing: focus)
            let layout = ScreenHighlightGeometry.layout(sentence: doc.rectangles(for: range), focus: doc.rectangles(for: focus))
            expect(layout.sentence.count >= 3, "Supplied sentence must span at least three physical rows")
            expect(Set(layout.sentence.map(\.height)).count == 1, "Supplied screenshot rows must have equal highlight heights")
            expect(Set(layout.sentence.dropFirst().map(\.minX)).count == 1, "Supplied screenshot continuation rows must align")
            print("Row fixture: \(layout.sentence)")
        } catch { failures.append("Screenshot row fixture: \(error)") }
    }
    if let flag = CommandLine.arguments.firstIndex(of: "--screen-highlight-matching-fixture"), CommandLine.arguments.count > flag + 2 {
        do {
            let sourceURL = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
            let sceneURL = URL(fileURLWithPath: CommandLine.arguments[flag + 2])
            let source = await ScreenText.recognize(sourceURL)
            guard var sourceDoc = source.screenDocument,
                  let src = CGImageSourceCreateWithURL(sourceURL as CFURL, nil), let srcImage = CGImageSourceCreateImageAtIndex(src, 0, nil),
                  let scene = CGImageSourceCreateWithURL(sceneURL as CFURL, nil), let sceneImage = CGImageSourceCreateImageAtIndex(scene, 0, nil) else {
                throw NarrationText.Invalid("Matching fixture OCR failed")
            }
            sourceDoc.frame = CGRect(x: 0, y: 0, width: srcImage.width, height: srcImage.height)
            let frame = CGRect(x: 0, y: 0, width: sceneImage.width, height: sceneImage.height)
            var recognizedSizes: [CGSize] = []
            let tracker = ScreenHighlightTracker(source: sourceDoc, recognize: { image in
                recognizedSizes.append(CGSize(width: image.width, height: image.height))
                return try await ScreenText.recognizeImage(image)
            }, onUpdate: { _, _ in })
            defer { tracker.stop() }
            tracker.invalidate() // Exercise relocation into the full two-column page.
            let match = try await tracker.locate(in: ScreenHighlightSnapshot(image: sceneImage, frame: frame, visibleRegions: [frame]))
            let missing = match.sourceWords.indices.filter { !match.matchedWords.contains($0) }.map { match.sourceWords[$0].text }
            print("Selection OCR: \(sourceDoc.text)")
            print("Position-search OCR regions: \(recognizedSizes)")
            print("Missing source positions: \(missing)")
            expect(missing.isEmpty, "Every selected word must have highlight geometry in the supplied page")
            for word in match.sourceWords {
                expect(!match.document.rectangles(for: word.range).isEmpty, "Matched source word must have actual OCR geometry: \(word.text)")
            }
            // Render the reported sentence beginnings using the relocated page,
            // not a synthetic paragraph or the source crop's original geometry.
            for phrase in ["The", "Parameter"] {
                let focus = (sourceDoc.text as NSString).range(of: phrase)
                guard focus.location != NSNotFound else { continue }
                let sentence = ScreenHighlightGeometry.sentenceRange(in: sourceDoc.text, containing: focus)
                let boxes = match.document.rectangles(for: sentence)
                let region = boxes.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -12, dy: -12)
                guard let crop = ScreenHighlightSnapshot(image: sceneImage, frame: frame, visibleRegions: [frame]).cropped(to: region),
                      let art = ScreenHighlightArtwork(snapshot: crop, sampleRects: boxes) else {
                    throw NarrationText.Invalid("Could not render relocated sentence")
                }
                let layout = ScreenHighlightGeometry.layout(sentence: boxes, focus: match.document.rectangles(for: focus))
                expect(Set(layout.sentence.map(\.height)).count == 1, "Reported sentence must have equal row heights: \(phrase)")
                let bounds = CGRect(origin: .zero, size: crop.frame.size)
                let view = NarrationHighlightView(frame: bounds)
                view.artwork = art
                view.imageFrame = crop.frame.offsetBy(dx: -crop.frame.minX, dy: -crop.frame.minY)
                view.sentence = layout.sentence.map { $0.offsetBy(dx: -crop.frame.minX, dy: -crop.frame.minY) }
                view.focus = layout.focus.map { $0.offsetBy(dx: -crop.frame.minX, dy: -crop.frame.minY) }
                let overlay = view.bitmapImageRepForCachingDisplay(in: bounds)!
                view.cacheDisplay(in: bounds, to: overlay)
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: crop.image.width, pixelsHigh: crop.image.height,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                NSImage(cgImage: crop.image, size: bounds.size).draw(in: bounds)
                let layer = NSImage(size: bounds.size); layer.addRepresentation(overlay)
                layer.draw(in: bounds)
                NSGraphicsContext.restoreGraphicsState()
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/pa3-relocated-\(phrase).png"))
            }
        } catch { failures.append("Matching fixture: \(error)") }
    }
    do { try await renderRowHighlightPreview() }
    catch { failures.append("Multi-line highlight preview: \(error)") }
    return failures
}

@MainActor
private func renderScreenHighlightPreview(_ url: URL) async throws {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
    var doc = try await ScreenText.recognizeImage(image)
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    doc.frame = bounds
    let focus = (doc.text as NSString).range(of: "optimize")
    guard focus.location != NSNotFound else { throw NarrationText.Invalid("Preview word missing") }
    let snapshot = ScreenHighlightSnapshot(image: image, frame: bounds, visibleRegions: [bounds])
    guard let artwork = ScreenHighlightArtwork(snapshot: snapshot, sampleRects: doc.rectangles(for: NSRange(location: 0, length: doc.text.utf16.count))) else {
        throw NarrationText.Invalid("Preview artwork missing")
    }
    let view = NarrationHighlightView(frame: bounds)
    view.artwork = artwork
    view.imageFrame = bounds
    let layout = ScreenHighlightGeometry.layout(sentence: doc.rectangles(for: ScreenHighlightGeometry.sentenceRange(in: doc.text, containing: focus)), focus: doc.rectangles(for: focus))
    view.sentence = layout.sentence
    view.focus = layout.focus
    let overlay = view.bitmapImageRepForCachingDisplay(in: bounds)!
    view.cacheDisplay(in: bounds, to: overlay)
    let composite = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: image.width, pixelsHigh: image.height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: composite)
    NSImage(cgImage: image, size: bounds.size).draw(in: bounds)
    let overlayImage = NSImage(size: bounds.size)
    overlayImage.addRepresentation(overlay)
    overlayImage.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try composite.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/pa3-highlight-preview.png"))
}


@MainActor
private func renderRowHighlightPreview() async throws {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 250)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1000, pixelsHigh: 250,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.white.setFill(); bounds.fill()
    let lines = ["Earlier sentence. One sentence starts here, and its words",
                 "appear on more than one line to expose the varying",
                 "heights between glyphs and groups of characters,",
                 "then end on this shorter line."]
    for (index, line) in lines.enumerated() {
        (line as NSString).draw(at: CGPoint(x: 40, y: 195 - index * 45), withAttributes: [
            .font: NSFont(name: "Times-Roman", size: 30)!, .foregroundColor: NSColor.black])
    }
    NSGraphicsContext.restoreGraphicsState()
    let image = bitmap.cgImage!
    var doc = try await ScreenText.recognizeImage(image)
    doc.frame = bounds
    let focus = (doc.text as NSString).range(of: "glyphs")
    guard focus.location != NSNotFound else { throw NarrationText.Invalid("Multi-line fixture OCR missing glyphs") }
    let sentence = ScreenHighlightGeometry.sentenceRange(in: doc.text, containing: focus)
    let raw = doc.rectangles(for: sentence)
    let layout = ScreenHighlightGeometry.layout(sentence: raw, focus: doc.rectangles(for: focus))
    guard layout.sentence.count == 4, Set(layout.sentence.map(\.height)).count == 1,
          Set(layout.sentence.dropFirst().map(\.minX)).count == 1 else {
        throw NarrationText.Invalid("Native OCR fixture must render four rows with equal heights and aligned continuation margins")
    }
    let snapshot = ScreenHighlightSnapshot(image: image, frame: bounds, visibleRegions: [bounds])
    guard let art = ScreenHighlightArtwork(snapshot: snapshot, sampleRects: raw) else { throw NarrationText.Invalid("Row artwork missing") }
    for after in [false, true] {
        let view = NarrationHighlightView(frame: bounds)
        view.artwork = art
        view.imageFrame = bounds
        view.sentence = after ? layout.sentence : ScreenHighlightGeometry.lineRects(raw).map(ScreenHighlightGeometry.paintRect)
        view.focus = after ? layout.focus : doc.rectangles(for: focus).map(ScreenHighlightGeometry.paintRect)
        let overlay = view.bitmapImageRepForCachingDisplay(in: bounds)!
        view.cacheDisplay(in: bounds, to: overlay)
        let composite = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1000, pixelsHigh: 250,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: composite)
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds)
        let layer = NSImage(size: bounds.size); layer.addRepresentation(overlay)
        layer.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let name = after ? "after" : "before"
        try composite.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/pa3-highlight-rows-\(name).png"))
    }
}
