import AppKit

/// Text and line numbers share character columns, row heights, and baselines.
/// Reserved number columns are presentation only and never enter the document.
@MainActor
final class TaskTextGrid: NSObject, @preconcurrency NSLayoutManagerDelegate {
    let font = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
    var cellWidth: CGFloat { ("M" as NSString).size(withAttributes: [.font: font]).width }
    var rowHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) }
    var baseline: CGFloat { ceil(font.ascender) }
    private(set) var lineStarts = [0]
    var leadingColumns: Int { max(2, String(lineStarts.count).count) + 2 }
    var textStartX: CGFloat { CGFloat(leadingColumns) * cellWidth }

    var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = rowHeight
        style.maximumLineHeight = rowHeight
        style.lineSpacing = 0
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        style.firstLineHeadIndent = textStartX
        style.headIndent = textStartX
        style.defaultTabInterval = cellWidth * 4
        return style
    }

    func update(body: String) {
        let source = body as NSString
        var starts = [0]
        var location = 0
        while location < source.length {
            var end = 0
            var contentsEnd = 0
            source.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            if end > contentsEnd { starts.append(end) }
            location = end
        }
        lineStarts = starts
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        lineFragmentRect.pointee.size.height = rowHeight
        lineFragmentUsedRect.pointee.size.height = rowHeight
        baselineOffset.pointee = baseline
        return true
    }
}

extension TaskModalTextView {
    var visibleLineNumbers: [(number: Int, baseline: CGFloat)] {
        guard let layout = layoutManager, let container = textContainer else { return [] }
        layout.ensureLayout(for: container)
        let origin = textContainerOrigin
        let visible = visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let starts = textGrid.lineStarts
        var lower = 0
        var upper = starts.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if starts[middle] <= characters.location { lower = middle + 1 }
            else { upper = middle }
        }
        let length = (string as NSString).length
        var labels: [(number: Int, baseline: CGFloat)] = []
        for index in max(0, lower - 1)..<starts.count {
            let start = starts[index]
            if start > NSMaxRange(characters) { break }
            let fragment = start == length ? layout.extraLineFragmentRect
                : layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: start), effectiveRange: nil)
            if fragment.maxY <= visible.minY || fragment.minY >= visible.maxY { continue }
            labels.append((index + 1, origin.y + fragment.minY + textGrid.baseline))
        }
        return labels
    }

    func drawLineNumbers(in dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: dirtyRect.intersection(NSRect(x: 0, y: bounds.minY, width: textGrid.textStartX, height: bounds.height))).addClip()
        PaperTheme.paper.withAlphaComponent(0.4).setFill()
        dirtyRect.fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: textGrid.font,
                                                       .foregroundColor: PaperTheme.muted.withAlphaComponent(0.65)]
        for label in visibleLineNumbers {
            let number = String(label.number) as NSString
            let column = textGrid.leadingColumns - 1 - number.length
            number.draw(at: NSPoint(x: CGFloat(column) * textGrid.cellWidth, y: label.baseline - textGrid.font.ascender),
                        withAttributes: attributes)
        }
    }
}
