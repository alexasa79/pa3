import AppKit
import ImageIO

func runScreenMathTests() -> [String] {
    var failures: [String] = []
    func check(_ value: Bool, _ message: String) { if !value { failures.append(message) } }
    func speech(_ text: String) -> String { (try? ScreenMath.segments(text).map(\.text).joined()) ?? "ERROR" }
    check(speech("1/ε. Changing ε = 1/2.") == "1 over epsilon. Changing epsilon equals 1 over 2.", "Read Greek letters, reciprocal, equality, and inline fractions")
    check(speech(#"\(B^{\varepsilon}\)-tree"#) == "bee to the power epsilon-tree", "Read a recognized exponent without leaking LaTeX")
    check(speech(#"B\(^{\varepsilon}\)-tree"#) == "B to the power epsilon-tree", "Keep a base outside the model's math delimiters attached to its exponent")
    check(speech(#"\(O(\frac{\log_{B}N}{\varepsilon})\)"#) == "big O of fraction log base bee of en over epsilon end fraction", "Preserve fraction nesting and logarithm base in speech")
    check(speech(#"\(\frac{1}{\frac{x}{y}}\)"#) == "fraction 1 over fraction ex over why end fraction end fraction", "Nested fractions must retain both denominators")
    check(speech(#"\(\sqrt{x^2}\)"#) == "square root of ex to the power 2 end root", "Read square roots and powers")
    check(speech(#"\(\frac12\)"#) == "fraction 1 over 2 end fraction", "Unbraced fraction arguments must remain separate TeX tokens")
    check(speech(#"\(\sqrt[3]{x}\)"#) == "cube root of ex end root", "An indexed root must not be narrated as a square root")
    check(speech(#"\(\log 10\)"#) == "log of 10", "Keep a function's multi-digit argument intact")
    check(speech(#"\(\sin^2 x\)"#) == "sin to the power 2 of ex", "Preserve powers on recognized functions")
    check(speech("The variable e and ordinary prose.") == "The variable e and ordinary prose.", "Never reinterpret an ordinary Latin e as epsilon")
    check(speech("Prices range from $5 to $10.") == "Prices range from $5 to $10.", "Do not confuse currency amounts with model math delimiters")
    check(speech(#"An incomplete \(x"#) == "ERROR", "Unclosed math delimiters must not reach the voice model")
    check(speech(#"\(\unsupported{x}\)"#) == "ERROR", "Unknown formula commands must fail explicitly instead of silently changing the formula")
    check(speech(#"\(\frac{x}\)"#) == "ERROR", "Incomplete fractions must not reach narration")
    let fractionBox = CGRect(x: 100, y: 100, width: 70, height: 50)
    let mathLayout = ScreenHighlightGeometry.layout(sentence: [CGRect(x: 20, y: 110, width: 200, height: 25), fractionBox], focus: [fractionBox], formulas: [fractionBox])
    check(mathLayout.focus.contains(ScreenHighlightGeometry.paintRect(fractionBox)), "Formula highlighting must include the observed numerator and denominator height")

    func visual(_ text: String, frame: CGRect) -> ScreenTextDocument {
        let spans = ScreenTextRelocation.words(text).enumerated().map { index, word in
            ScreenTextSpan(range: word.range, box: CGRect(x: Double(index) * 0.045, y: 0.5, width: 0.04, height: 0.1))
        }
        return ScreenTextDocument(text: text, spans: spans, frame: frame)
    }
    do {
        let source = visual("The search cost is O logB N e. Another sentence follows in this paragraph.", frame: CGRect(x: 0, y: 0, width: 900, height: 100))
        let doc = try ScreenOCRMapping.document(recognized: #"The search cost is \(O(\frac{\log_{B}N}{\varepsilon})\). Another sentence follows in this paragraph."#, visual: source)
        let epsilon = (doc.text as NSString).range(of: "epsilon")
        let formula = (doc.text as NSString).range(of: "fraction log base bee of en over epsilon end fraction")
        check(!doc.rectangles(for: epsilon).isEmpty && doc.rectangles(for: epsilon) == doc.rectangles(for: formula), "Expanded formula words must share real visual formula boxes")
        let moved = visual(source.text, frame: CGRect(x: 200, y: 500, width: 900, height: 100))
        let match = ScreenTextRelocation(source: doc, current: moved)
        check(match.contains(epsilon), "A spoken formula must remain relocatable through its visual source")
        check(match.document.rectangles(for: epsilon).first?.minY == doc.rectangles(for: epsilon).first!.minY + 500,
              "Formula relocation must use updated positions after scrolling")
        let offscreen = visual("Another sentence follows in this paragraph.", frame: moved.frame!)
        check(!ScreenTextRelocation(source: doc, current: offscreen).contains(epsilon), "Remaining prose must not justify an offscreen formula highlight")
        let heading = try ScreenOCRMapping.document(recognized: "Abstract\nA careful reader follows this paragraph.",
            visual: visual("Abstract\n\nA careful reader follows this paragraph.", frame: moved.frame!))
        check(heading.text.hasPrefix("Abstract\n\n"), "Model recognition must retain geometric heading pauses")
    } catch { failures.append("Formula geometry mapping: \(error)") }
    return failures
}

@MainActor
func runScreenOCRLiveTests(_ urls: [URL]) async -> Int32 {
    defer { PaddleOCR.shared.stop() }
    var failures = runScreenMathTests()
    for (index, url) in urls.enumerated() {
        let started = Date()
        let result = await ScreenText.recognizeForNarration(url)
        guard var doc = result.screenDocument else { failures.append(result.message); continue }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            failures.append("Unreadable screenshot"); continue
        }
        doc.frame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let vision = await ScreenText.recognize(url)
        guard var visual = vision.screenDocument else { failures.append("No geometry"); continue }
        visual.frame = doc.frame
        let match = ScreenTextRelocation(source: doc, current: visual)
        let missing = match.sourceWords.indices.filter { !match.matchedWords.contains($0) }.map { match.sourceWords[$0].text }
        print("OCR \(url.lastPathComponent) in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        print(doc.text)
        print("Unmapped highlight words: \(missing)")
        do {
            let pieces = try NarrationText.plan(NarrationInput(text: doc.text))
            if pieces.map(\.text).joined().contains("\\") { failures.append("LaTeX reached the voice model") }
            try doc.text.write(toFile: "/tmp/pa3-screen-ocr-\(index).txt", atomically: true, encoding: .utf8)
        } catch { failures.append("Narration planning: \(error)") }
        let epsilon = (doc.text as NSString).range(of: "epsilon")
        if epsilon.location != NSNotFound, !match.contains(epsilon) { failures.append("Epsilon has no highlight position") }
        if let scenePath = ProcessInfo.processInfo.environment["PA3_SCREEN_OCR_SCENE"],
           let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: scenePath) as CFURL, nil),
           let scene = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let frame = CGRect(x: 0, y: 0, width: scene.width, height: scene.height)
            let tracker = ScreenHighlightTracker(source: doc, onUpdate: { _, _ in })
            tracker.invalidate()
            do {
                let relocated = try await tracker.locate(in: ScreenHighlightSnapshot(image: scene, frame: frame, visibleRegions: [frame]))
                let absent = relocated.sourceWords.indices.filter { !relocated.matchedWords.contains($0) }
                if !absent.isEmpty { failures.append("Spoken words lost after full-page relocation: \(absent.map { relocated.sourceWords[$0].text })") }
                else { print("PASS formula and prose positions after full-page relocation") }
            } catch { failures.append("Full-page OCR relocation: \(error)") }
            tracker.stop()
        }
        let focus = (doc.text as NSString).range(of: "fraction")
        if focus.location != NSNotFound {
            let bounds = doc.frame!
            let snapshot = ScreenHighlightSnapshot(image: image, frame: bounds, visibleRegions: [bounds])
            if let art = ScreenHighlightArtwork(snapshot: snapshot, sampleRects: match.document.rectangles(for: focus)) {
                let view = NarrationHighlightView(frame: bounds)
                view.artwork = art
                view.imageFrame = bounds
                let sentence = ScreenHighlightGeometry.sentenceRange(in: doc.text, containing: focus)
                let formulaRects = doc.formulas.filter { NSIntersectionRange($0, sentence).length > 0 }.flatMap { match.document.rectangles(for: $0) }
                let layout = ScreenHighlightGeometry.layout(sentence: match.document.rectangles(for: sentence), focus: match.document.rectangles(for: focus), formulas: formulaRects)
                view.sentence = layout.sentence
                view.focus = layout.focus
                let overlay = view.bitmapImageRepForCachingDisplay(in: bounds)!
                view.cacheDisplay(in: bounds, to: overlay)
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: image.width, pixelsHigh: image.height,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                NSImage(cgImage: image, size: bounds.size).draw(in: bounds)
                let layer = NSImage(size: bounds.size); layer.addRepresentation(overlay)
                layer.draw(in: bounds)
                NSGraphicsContext.restoreGraphicsState()
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/pa3-screen-formula-\(index).png"))
            }
        }
    }
    if let url = urls.first {
        let cancelled = Task { try await PaddleOCR.shared.recognize(url) }
        try? await Task.sleep(for: .milliseconds(40))
        cancelled.cancel()
        do { _ = try await cancelled.value; failures.append("Cancelled model recognition returned usable text") }
        catch { if !cancelled.isCancelled { failures.append("Unexpected recognition failure: \(error)") } }
        let retry = await ScreenText.recognizeForNarration(url)
        if retry.text == nil { failures.append("Recognition did not recover after cancellation: \(retry.message)") }
        else { print("PASS local OCR cancellation and fresh-worker recovery") }
    }
    failures.forEach { print("FAIL: " + $0) }
    print(failures.isEmpty ? "screen-ocr-test: ok" : "screen-ocr-test: failed")
    return failures.isEmpty ? 0 : 1
}
