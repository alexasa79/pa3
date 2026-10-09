import AppKit
import SwiftUI

enum TranscriptLayout {
    static func writingDirection(for text: String, language: String?) -> NSWritingDirection {
        // First strong letter determines each paragraph independently. This also
        // handles pasted/edited text and keeps earlier paragraphs stable as the
        // model detects a different language in a later audio clip.
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF:
                return .rightToLeft
            default:
                return .leftToRight
            }
        }
        let language = language?.lowercased() ?? ""
        return ["he", "hebrew", "iw", "ar", "arabic", "fa", "persian", "ur", "urdu"].contains(language)
            ? .rightToLeft : .leftToRight
    }

    @MainActor
    static func content(tokens: [TranscriptToken], language: String?) -> (text: NSAttributedString, ranges: [Int: NSRange]) {
        let result = NSMutableAttributedString(string: "")
        var ranges: [Int: NSRange] = [:]
        var previous: TranscriptToken?
        var paragraphStart = 0
        func background(for token: TranscriptToken) -> NSColor? {
            if token.selected { return PaperTheme.selection }
            if token.pending { return PaperTheme.muted.withAlphaComponent(0.20) }
            return nil
        }
        func finishParagraph() {
            let range = NSRange(location: paragraphStart, length: result.length - paragraphStart)
            guard range.length > 0 else { return }
            let style = NSMutableParagraphStyle()
            style.baseWritingDirection = writingDirection(for: (result.string as NSString).substring(with: range), language: language)
            style.alignment = style.baseWritingDirection == .rightToLeft ? .right : .left
            // Keep an explicit gap between wrapped lines. Let taller glyphs expand
            // the line so RTL scripts and combining marks are not clipped.
            style.minimumLineHeight = 21
            style.lineSpacing = 6
            style.paragraphSpacing = 10
            result.addAttribute(.paragraphStyle, value: style, range: range)
        }
        for token in tokens {
            if let previous {
                if previous.paragraph != token.paragraph {
                    result.append(NSAttributedString(string: "\n"))
                    finishParagraph()
                    paragraphStart = result.length
                } else if shouldInsertSpace(before: token.text, after: previous.text) {
                    var attributes: [NSAttributedString.Key: Any] = [:]
                    if let color = background(for: token), color == background(for: previous) {
                        attributes[.backgroundColor] = color
                    }
                    result.append(NSAttributedString(string: " ", attributes: attributes))
                }
            }
            let range = NSRange(location: result.length, length: token.text.utf16.count)
            result.append(NSAttributedString(string: token.text))
            ranges[token.id] = range
            result.addAttribute(.foregroundColor, value: PaperTheme.ink, range: range)
            if let color = background(for: token) {
                result.addAttribute(.backgroundColor, value: color, range: range)
            }
            previous = token
        }
        finishParagraph()
        result.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular),
                            range: NSRange(location: 0, length: result.length))
        return (result, ranges)
    }
}

struct TranscriptTextView: NSViewRepresentable {
    let tokens: [TranscriptToken]
    let language: String?
    let dictating: Bool
    let selectedWord: Int
    let onKey: (KeyEvent) -> Void
    let onFrames: ([Int: CGRect]) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let view = TextView(frame: scroll.contentView.bounds)
        view.isEditable = false
        view.isSelectable = false
        view.isRichText = true
        view.backgroundColor = PaperTheme.canvas
        view.textContainerInset = NSSize(width: 18, height: 18)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? TextView else { return }
        let content = TranscriptLayout.content(tokens: tokens, language: language)
        let changed = view.string != content.text.string
        let selectionChanged = view.currentWord != selectedWord
        view.onKey = onKey
        view.onFrames = onFrames
        view.ranges = content.ranges
        view.currentWord = selectedWord
        if view.textStorage?.isEqual(to: content.text) != true {
            view.textStorage?.setAttributedString(content.text)
        }
        view.publishFrames()
        if dictating && changed {
            view.scrollRangeToVisible(NSRange(location: content.text.length, length: 0))
        } else if (changed || selectionChanged), let range = content.ranges[selectedWord] {
            view.scrollRangeToVisible(range)
        }
    }

    final class HighlightLayoutManager: NSLayoutManager {
        private var backgroundOrigin = NSPoint.zero

        override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
            backgroundOrigin = origin
            super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        }

        override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                              forCharacterRange charRange: NSRange, color: NSColor) {
            guard let storage = textStorage else { return }
            let glyphs = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
            color.setFill()
            // TextKit can merge backgrounds across several rows. Intersect each
            // rectangle with the text portion of each row to leave spacing clear.
            enumerateLineFragments(forGlyphRange: glyphs) { line, _, _, range, _ in
                let character = self.characterIndexForGlyph(at: range.location)
                let style = storage.attribute(.paragraphStyle, at: character, effectiveRange: nil) as? NSParagraphStyle
                var band = line.offsetBy(dx: self.backgroundOrigin.x, dy: self.backgroundOrigin.y)
                if let style, band.height >= style.minimumLineHeight + style.lineSpacing {
                    band.size.height -= style.lineSpacing
                }
                for index in 0..<rectCount {
                    let rect = rectArray[index].intersection(band)
                    if !rect.isNull && !rect.isEmpty { rect.fill() }
                }
            }
        }
    }

    final class TextView: NSTextView {
        private var retainedTextStorage: NSTextStorage?

        override init(frame frameRect: NSRect, textContainer container: NSTextContainer? = nil) {
            let storage = NSTextStorage()
            let manager = HighlightLayoutManager()
            let container = container ?? NSTextContainer(size: NSSize(width: frameRect.width, height: .greatestFiniteMagnitude))
            storage.addLayoutManager(manager)
            manager.addTextContainer(container)
            super.init(frame: frameRect, textContainer: container)
            retainedTextStorage = storage
            container.widthTracksTextView = true
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            if let storage = textStorage, let container = textContainer {
                let manager = HighlightLayoutManager()
                storage.addLayoutManager(manager)
                container.replaceLayoutManager(manager)
                retainedTextStorage = storage
            }
        }

        var onKey: ((KeyEvent) -> Void)?
        var onFrames: (([Int: CGRect]) -> Void)?
        var ranges: [Int: NSRange] = [:]
        var currentWord = -1
        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) { onKey?(KeyEvent(nsEvent: event)) }

        override func layout() {
            super.layout()
            publishFrames()
        }

        func publishFrames() {
            guard let manager = layoutManager, let container = textContainer else { return }
            manager.ensureLayout(for: container)
            var frames: [Int: CGRect] = [:]
            for (id, range) in ranges where NSMaxRange(range) <= (string as NSString).length {
                let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                frames[id] = manager.boundingRect(forGlyphRange: glyphs, in: container)
                    .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            }
            onFrames?(frames)
        }
    }
}
