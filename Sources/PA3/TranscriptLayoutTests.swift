import AppKit
import SwiftUI

@MainActor
func runTranscriptLayoutTests() -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ name: String) {
        if !condition { failures.append("transcript layout: " + name) }
    }
    for selected in [false, true] {
        for words in [["before", "active", "words", ".", "after"], ["לפני", "שלום", "עולם", ".", "אחרי"]] {
            let tokens = words.enumerated().map { index, word in
                TranscriptToken(id: index, text: word, paragraph: 0,
                                selected: selected && (1...3).contains(index),
                                pending: !selected && (1...3).contains(index))
            }
            let content = TranscriptLayout.content(tokens: tokens, language: nil)
            let start = content.ranges[1]!.location
            let end = NSMaxRange(content.ranges[3]!)
            let color = content.text.attribute(.backgroundColor, at: start, effectiveRange: nil) as? NSColor
            check(color != nil, "active text has a background")
            check((start..<end).allSatisfy {
                (content.text.attribute(.backgroundColor, at: $0, effectiveRange: nil) as? NSColor) == color
            }, "highlight includes internal spaces and punctuation for selected=\(selected)")
            check(content.text.attribute(.backgroundColor, at: start - 1, effectiveRange: nil) == nil &&
                  content.text.attribute(.backgroundColor, at: end, effectiveRange: nil) == nil,
                  "highlight does not spill into surrounding spaces")
        }
    }
    check(TranscriptLayout.writingDirection(for: "שלום עולם", language: "hebrew") == .rightToLeft, "Hebrew direction")
    check(TranscriptLayout.writingDirection(for: "English text", language: "hebrew") == .leftToRight, "English paragraph remains LTR")
    check(TranscriptLayout.writingDirection(for: "שלום עולם", language: "english") == .rightToLeft, "earlier Hebrew remains RTL")
    check(TranscriptLayout.writingDirection(for: "123", language: "hebrew") == .rightToLeft, "model language guides neutral text")
    check(TranscriptLayout.writingDirection(for: "123", language: nil) == .leftToRight, "missing language is safe")
    do {
        let response = try JSONDecoder().decode(WhisperTranscription.self,
            from: Data(#"{"language":"hebrew","text":"שלום עולם","segments":[]}"#.utf8))
        check(response.language == "hebrew" && decodedWhisperText(response) == "שלום עולם", "Whisper language metadata decodes alongside Hebrew")
    } catch { failures.append("transcript layout: language response failed to decode") }

    let preferenceSuite = "com.local.pa3.tests.window-level.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: preferenceSuite)!
    defer { preferences.removePersistentDomain(forName: preferenceSuite) }
    let controller = DictationController(transcriber: TranscriberService(), preferences: preferences)
    let levelWindow = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                                styleMask: [.titled], backing: .buffered, defer: false)
    levelWindow.bindAlwaysOnTop(to: controller)
    check(controller.alwaysOnTop && levelWindow.level == .floating, "dictation window stays on top by default")
    controller.alwaysOnTop = false
    check(levelWindow.level == .normal, "turning always on top off restores normal window stacking")
    check(preferences.object(forKey: DictationController.alwaysOnTopKey) as? Bool == false,
          "disabling always on top saves an explicit false preference")
    let restoredController = DictationController(transcriber: TranscriberService(),
                                               preferences: UserDefaults(suiteName: preferenceSuite)!)
    let restoredWindow = KeyWindow(contentRect: levelWindow.frame, styleMask: [.titled], backing: .buffered, defer: false)
    restoredWindow.bindAlwaysOnTop(to: restoredController)
    check(!restoredController.alwaysOnTop && restoredWindow.level == .normal,
          "saved disabled preference restores normal stacking when creating a new controller and window")
    controller.beginNewSession()
    check(!controller.alwaysOnTop && levelWindow.level == .normal, "new dictation sessions preserve the window toggle")
    controller.alwaysOnTop = true
    check(levelWindow.level == .floating, "turning always on top back on restores floating window stacking")
    let restoredEnabledController = DictationController(transcriber: TranscriberService(),
                                                      preferences: UserDefaults(suiteName: preferenceSuite)!)
    check(restoredEnabledController.alwaysOnTop, "saved enabled preference is restored on next launch")
    let source = "שלום עולם.\n\nשלום OpenAI test 123 עולם.\n\nEnglish text stays left to right."
    controller.handleTranscription(TranscriptionUpdate(text: source, language: "hebrew"))
    check(controller.detectedLanguage == "hebrew", "language reaches the controller with the text")
    let content = TranscriptLayout.content(tokens: controller.tokens(), language: controller.detectedLanguage)
    check(content.text.string == source.replacingOccurrences(of: "\n\n", with: "\n"), "logical order and punctuation are preserved")
    for token in controller.tokens() {
        check((content.text.string as NSString).substring(with: content.ranges[token.id]!) == token.text,
              "UTF-16 range maps token \(token.id)")
    }

    let storage = NSTextStorage(attributedString: content.text)
    let manager = NSLayoutManager()
    let container = NSTextContainer(size: NSSize(width: 680, height: 1000))
    storage.addLayoutManager(manager)
    manager.addTextContainer(container)
    manager.ensureLayout(for: container)
    func rect(_ range: NSRange) -> CGRect {
        manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
    }
    check(rect(content.ranges[0]!).minX > rect(content.ranges[1]!).minX, "Hebrew words flow right to left")
    check(rect(content.ranges[2]!).minX < rect(content.ranges[1]!).minX, "sentence punctuation appears at the visual end")
    let latin = (content.text.string as NSString).range(of: "OpenAI test")
    check(rect(NSRange(location: latin.location, length: 1)).minX < rect(NSRange(location: NSMaxRange(latin) - 1, length: 1)).minX,
          "embedded English retains LTR order")
    let digits = (content.text.string as NSString).range(of: "123")
    check(rect(NSRange(location: digits.location, length: 1)).minX < rect(NSRange(location: digits.location + 2, length: 1)).minX,
          "numbers retain LTR order")

    controller.setWordFrames(content.ranges.mapValues { rect($0) })
    controller.selectedWord = 1
    func press(_ code: UInt16, shift: Bool = false) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [],
                                    timestamp: 0, windowNumber: 0, context: nil, characters: "",
                                    charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        controller.handleKey(KeyEvent(nsEvent: event))
    }
    press(124)
    press(123, shift: true)
    check(controller.selectedWord == 1 && controller.selectionStart == 0 && controller.selectionEnd == 1,
          "Shift+Left selects the next visual Hebrew word")
    press(124)
    check(controller.selectedWord == 0, "Right moves back visually in Hebrew")
    controller.selectedWord = 2
    press(123)
    check(controller.selectedWord == 3, "Left at Hebrew line end advances to the right edge of the next line")
    press(124)
    check(controller.selectedWord == 2, "Right at Hebrew line start returns to the previous line's left edge")
    var pasted = ""
    controller.onPasteAndHide = { pasted = $0 }
    controller.pasteAndHide()
    check(pasted == source, "paste retains logical Unicode order and paragraph breaks")

    container.containerSize = NSSize(width: 140, height: 2000)
    manager.ensureLayout(for: container)
    check(manager.usedRect(for: container).height > 100, "mixed text wraps at narrow widths")

    // Measure actual wrapped rows, not just paragraph-style properties.
    for words in [["English", "words", "wrap", "across", "several", "lines"],
                  ["שלום", "עולם", "שלום", "עולם", "שלום", "עולם"],
                  ["مرحبا", "بالعالم", "مرحبا", "بالعالم", "مرحبا", "بالعالم"]] {
        let tokens = words.enumerated().map {
            TranscriptToken(id: $0.offset, text: $0.element, paragraph: 0, selected: false, pending: false)
        }
        let wrapped = TranscriptLayout.content(tokens: tokens, language: nil)
        let storage = NSTextStorage(attributedString: wrapped.text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 125, height: 2000))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        var rows: [CGRect] = []
        layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) {
            rect, _, _, _, _ in rows.append(rect)
        }
        check(rows.count > 1, "spacing fixture wraps: \(words[0])")
        for (previous, next) in zip(rows, rows.dropFirst()) {
            check(next.minY - previous.minY >= 26.9, "wrapped lines retain a visible gap: \(words[0])")
        }
        if words[0] == "English", rows.count > 1 {
            check(abs(rows[1].minY - rows[0].minY - 27) < 0.1, "English uses 27-point row spacing")
        }
    }

    if CommandLine.arguments.contains("--transcript-layout-test") {
        if let active = DictationStatusIcon.image(active: true),
           let starting = DictationStatusIcon.image(active: true, starting: true),
           let paused = DictationStatusIcon.image(active: false),
           let startingData = starting.tiffRepresentation,
           let startingBitmap = NSBitmapImageRep(data: startingData),
           let activeData = active.tiffRepresentation, let pausedData = paused.tiffRepresentation,
           let activeBitmap = NSBitmapImageRep(data: activeData),
           let pausedBitmap = NSBitmapImageRep(data: pausedData) {
            check(active.size == paused.size && active.size == NSSize(width: 128, height: 128),
                  "both dictation icon resources have the same dimensions")
            let x = activeBitmap.pixelsWide / 8, y = activeBitmap.pixelsHigh / 2
            let activeColor = activeBitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
            let startingColor = startingBitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
            let pausedColor = pausedBitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
            check(activeColor != nil && pausedColor != nil && activeColor != pausedColor,
                  "active and paused icons have distinct background colors")
            check((activeColor?.redComponent ?? 0) > (activeColor?.greenComponent ?? 1) * 1.5,
                  "active icon background is red")
            check((activeColor?.redComponent ?? 0) > 0.95 && (activeColor?.greenComponent ?? 1) < 0.4,
                  "active icon uses bright recording red")
            let corner = activeBitmap.pixelsWide / 8
            check((startingColor?.redComponent ?? 0) > 0.95 &&
                  (startingColor?.greenComponent ?? 0) > 0.7 &&
                  (startingColor?.blueComponent ?? 1) < 0.1,
                  "starting icon background is yellow")
            check((startingBitmap.colorAt(x: corner, y: corner)?.alphaComponent ?? 1) < 0.05,
                  "starting icon is circular")
            check(startingBitmap.colorAt(x: startingBitmap.pixelsWide / 2, y: y) ==
                  activeBitmap.colorAt(x: activeBitmap.pixelsWide / 2, y: y),
                  "startup preserves the dictation portrait")
            check((activeBitmap.colorAt(x: corner, y: corner)?.alphaComponent ?? 1) < 0.05 &&
                  (pausedBitmap.colorAt(x: corner, y: corner)?.alphaComponent ?? 0) > 0.95,
                  "active icon is circular while the paused icon retains its square background")
            check(activeBitmap.colorAt(x: activeBitmap.pixelsWide / 2, y: y) ==
                  pausedBitmap.colorAt(x: pausedBitmap.pixelsWide / 2, y: y),
                  "changing dictation state preserves the portrait")
        } else {
            check(false, "both dictation icon resources load successfully")
        }
        let previewWords = (Array(repeating: "The active transcript should have a clear gap between wrapped lines.", count: 3).joined(separator: " ")
            + "\n" + Array(repeating: "שלום עולם זה טקסט בעברית עם מילים רבות", count: 3).joined(separator: " ")).components(separatedBy: "\n")
        var previewTokens: [TranscriptToken] = []
        for (paragraph, text) in previewWords.enumerated() {
            for word in text.split(separator: " ") {
                previewTokens.append(TranscriptToken(id: previewTokens.count, text: String(word), paragraph: paragraph, selected: false, pending: true))
            }
        }
        let wrappedPreview = TranscriptTextView.TextView(frame: NSRect(x: 0, y: 0, width: 560, height: 360))
        wrappedPreview.textContainerInset = NSSize(width: 18, height: 18)
        wrappedPreview.backgroundColor = .white
        wrappedPreview.textStorage?.setAttributedString(TranscriptLayout.content(tokens: previewTokens, language: nil).text)
        wrappedPreview.layoutManager?.ensureLayout(for: wrappedPreview.textContainer!)
        check(wrappedPreview.textStorage?.length == TranscriptLayout.content(tokens: previewTokens, language: nil).text.length,
              "native view retains text storage when installing highlight renderer")
        check((wrappedPreview.layoutManager?.numberOfGlyphs ?? 0) > 0, "native view lays out visible glyphs")
        if let bitmap = wrappedPreview.bitmapImageRepForCachingDisplay(in: wrappedPreview.bounds) {
            wrappedPreview.cacheDisplay(in: wrappedPreview.bounds, to: bitmap)
            let scaleX = CGFloat(bitmap.pixelsWide) / wrappedPreview.bounds.width
            let scaleY = CGFloat(bitmap.pixelsHigh) / wrappedPreview.bounds.height
            let layout = wrappedPreview.layoutManager!
            var checkedGaps = 0
            layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) {
                row, _, _, _, _ in
                guard row.height >= 27 else { return }
                let y = Int((wrappedPreview.textContainerOrigin.y + row.maxY - 3) * scaleY)
                guard y < bitmap.pixelsHigh else { return }
                let clear = (Int(24 * scaleX)..<Int(530 * scaleX)).allSatisfy { x in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                    return color.redComponent > 0.98 && color.greenComponent > 0.98 && color.blueComponent > 0.98
                }
                check(clear, "rendered highlight leaves the interline gap unpainted")
                checkedGaps += 1
            }
            check(checkedGaps >= 4, "rendered spacing checked across English and Hebrew rows")
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/pa3-line-spacing.png"))
        }
        let highlighted = TranscriptLayout.content(tokens: controller.tokens().map {
            TranscriptToken(id: $0.id, text: $0.text, paragraph: $0.paragraph, selected: false, pending: true)
        }, language: controller.detectedLanguage)
        let view = TranscriptTextView.TextView(frame: NSRect(x: 0, y: 0, width: 720, height: 240))
        view.textContainerInset = NSSize(width: 18, height: 18)
        view.backgroundColor = .white
        view.textStorage?.setAttributedString(highlighted.text)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/pa3-rtl-preview.png"))
        }
        let host = NSHostingView(rootView: DictationView(controller: controller))
        host.frame = NSRect(x: 0, y: 0, width: 1240, height: 620)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/pa3-rtl-window.png"))
        }
        controller.dictating = true // Preview without opening a microphone.
        RunLoop.current.run(until: Date().addingTimeInterval(0.14))
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/pa3-dictation-transition-preview.png"))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/pa3-dictation-active-preview.png"))
        }
        controller.dictating = false
        controller.toggleShortcuts()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/pa3-shortcuts-preview.png"))
        }
    }
    controller.beginNewSession()
    check(controller.detectedLanguage == nil, "new session clears the model hint")
    return failures
}
