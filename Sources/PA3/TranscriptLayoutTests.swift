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

    let controller = DictationController(transcriber: TranscriberService())
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

    if CommandLine.arguments.contains("--transcript-layout-test") {
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
