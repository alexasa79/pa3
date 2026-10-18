import AppKit
import CoreImage

// Mirrors chrome-extension/content.css. Screen coordinates are AppKit points;
// positive Y raises the box without shifting or repainting the source glyphs.
enum ScreenHighlightGeometry {
    static func paintRect(_ box: CGRect) -> CGRect {
        box.offsetBy(dx: 0, dy: 2).insetBy(dx: -1, dy: -2)
    }

    static func lineRects(_ boxes: [CGRect]) -> [CGRect] {
        var lines: [CGRect] = []
        for box in boxes.sorted(by: { abs($0.midY - $1.midY) < min($0.height, $1.height) * 0.3 ? $0.minX < $1.minX : $0.midY > $1.midY }) {
            if let last = lines.last,
               abs(last.midY - box.midY) < max(last.height, box.height) * 0.4,
               box.minX - last.maxX < max(last.height, box.height) * 1.5 {
                lines[lines.count - 1] = last.union(box)
            } else { lines.append(box) }
        }
        return lines
    }

    struct Layout {
        let sentence: [CGRect]
        let focus: [CGRect]
    }

    static func layout(sentence boxes: [CGRect], focus words: [CGRect], formulas: [CGRect] = []) -> Layout {
        let rows = lineRects(boxes.filter { !$0.isEmpty && !$0.isNull })
        guard !rows.isEmpty else { return Layout(sentence: [], focus: words.map(paintRect)) }
        func median(_ values: [CGFloat]) -> CGFloat {
            let sorted = values.sorted()
            let middle = sorted.count / 2
            return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        }
        // OCR describes ink, so descenders and recognition rounding change row
        // heights. Compare nearby, overlapping rows of similar apparent type size.
        let neighbors = rows.map { row in
            rows.indices.filter { index in
                let other = rows[index]
                let overlap = min(row.maxX, other.maxX) - max(row.minX, other.minX)
                let distance = abs(row.midY - other.midY), height = max(row.height, other.height)
                // A short sentence can wrap from the far right to the far left
                // without its two rows overlapping horizontally.
                let wrapped = distance >= height * 0.7 && distance <= height * 2.3
                return min(row.height, other.height) >= height * 0.7
                    && distance < height * 8
                    && (overlap > min(row.width, other.width) * 0.2 || wrapped)
            }
        }
        // A short first or final row need not overlap each other horizontally;
        // full rows between them establish that they belong to the same run.
        var peers = neighbors
        var ungrouped = Set(rows.indices)
        while let first = ungrouped.first {
            var component: Set<Int> = [first], pending = [first]
            while let index = pending.popLast() {
                for neighbor in neighbors[index] where component.insert(neighbor).inserted { pending.append(neighbor) }
            }
            let members = component.sorted()
            for index in members { peers[index] = members; ungrouped.remove(index) }
        }
        var bands = rows.indices.map { index in
            let row = rows[index]
            let similar = peers[index].map { rows[$0] }
            let inkHeight = median(similar.map(\.height))
            var height = inkHeight + 4
            let centers = similar.map(\.midY).sorted()
            let pitches = zip(centers, centers.dropFirst()).map { $0.1 - $0.0 }.filter { $0 > inkHeight * 0.7 }
            if let pitch = pitches.min() {
                // Padding must not overlap an adjacent line, even at small text sizes.
                height = min(height, max(1, pitch - 1))
            }
            return CGRect(x: row.minX - 1, y: row.midY + 2 - height / 2, width: row.width + 2, height: height)
        }
        // Snap only small OCR errors at continuation margins. A sentence can
        // begin halfway through a row; genuine paragraph/list indents stay separate.
        var remaining = Set(rows.indices.dropFirst())
        while let first = remaining.min(by: { rows[$0].minX < rows[$1].minX }) {
            let tolerance = median(peers[first].map { rows[$0].height }) * 0.5
            let cluster = remaining.filter { index in
                abs(rows[index].minX - rows[first].minX) <= tolerance
                    && peers[first].contains(index)
            }
            let margin = median(cluster.map { rows[$0].minX }) - 1
            for index in cluster {
                let right = bands[index].maxX
                bands[index].origin.x = margin
                bands[index].size.width = right - margin
                remaining.remove(index)
            }
        }
        let focused = words.map { word in
            // Fraction numerators and denominators extend beyond a prose row's
            // uniform band. Keep their observed bounds rather than clipping them.
            if formulas.contains(word) { return paintRect(word) }
            let row = rows.indices.max { a, b in
                let aOverlap = rows[a].intersection(word)
                let bOverlap = rows[b].intersection(word)
                return (aOverlap.isNull ? 0 : aOverlap.width * aOverlap.height)
                    < (bOverlap.isNull ? 0 : bOverlap.width * bOverlap.height)
            }!
            guard rows[row].intersects(word) else { return paintRect(word) }
            return CGRect(x: word.minX - 1, y: bands[row].minY, width: word.width + 2, height: bands[row].height)
        }
        return Layout(sentence: bands + lineRects(formulas).map(paintRect), focus: focused)
    }

    static func sentenceRange(in text: String, containing focus: NSRange) -> NSRange {
        let original = text as NSString
        let blocks = try! NSRegularExpression(pattern: #"[^\r\n]+(?:[\r\n](?![\r\n])[^\r\n]+)*"#)
        for block in blocks.matches(in: text, range: NSRange(location: 0, length: original.length)) {
            guard NSIntersectionRange(block.range, focus).length > 0 else { continue }
            // Keep offsets while treating visual wraps as spaces, as narration does.
            let paragraph = original.substring(with: block.range).replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            var result = block.range
            paragraph.enumerateSubstrings(in: paragraph.startIndex..<paragraph.endIndex, options: [.bySentences, .localized]) { _, range, _, stop in
                let local = NSRange(range, in: paragraph)
                let candidate = NSRange(location: block.range.location + local.location, length: local.length)
                if NSIntersectionRange(candidate, focus).length > 0 { result = candidate; stop = true }
            }
            return result
        }
        return focus
    }
}

struct ScreenHighlightPalette: Equatable {
    let dark: Bool
    // sRGB values and opacities match the extension's sentence and word rules.
    var base: (r: Double, g: Double, b: Double, a: Double) {
        if dark { return (55.0 / 255.0, 57.0 / 255.0, 52.0 / 255.0, 0.91) }
        return (221.0 / 255.0, 215.0 / 255.0, 202.0 / 255.0, 0.93)
    }
    var focus: (r: Double, g: Double, b: Double, a: Double) {
        if dark { return (221.0 / 255.0, 215.0 / 255.0, 202.0 / 255.0, 0.30) }
        return (101.0 / 255.0, 100.0 / 255.0, 91.0 / 255.0, 0.26)
    }
    static func luminance(_ color: [Double]) -> Double {
        let linear = color.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
    }
}

/// A native window paints above text. Recolor the verified screenshot's background
/// while preserving its glyphs, instead of obscuring them with an opaque gray fill.
@MainActor
final class ScreenHighlightArtwork {
    let sentence: NSImage
    let focus: NSImage
    let frame: CGRect
    let palette: ScreenHighlightPalette
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    init?(snapshot: ScreenHighlightSnapshot, sampleRects: [CGRect]) {
        let frame = snapshot.frame
        self.frame = frame
        let background = Self.background(in: snapshot, around: sampleRects)
        let palette = ScreenHighlightPalette(dark: ScreenHighlightPalette.luminance(background) < 0.45)
        self.palette = palette
        let base = palette.base, word = palette.focus
        let target = zip(background, [base.r, base.g, base.b]).map { $0 * (1 - base.a) + $1 * base.a }
        let focused = zip(target, [word.r, word.g, word.b]).map { $0 * (1 - word.a) + $1 * word.a }
        func paint(_ target: [Double]) -> NSImage? {
            let input = CIImage(cgImage: snapshot.image)
            // Derive background coverage from all channels. Saturated glyphs and
            // links stay intact, rather than being darkened by a gray rectangle.
            let scale = (0..<3).map { palette.dark ? -1 / max(0.01, 1 - background[$0]) : 1 / max(0.01, background[$0]) }
            let offset = (0..<3).map { palette.dark ? -scale[$0] : 0 }
            let coverage = input.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale[0], y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: scale[1], z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale[2], w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: offset[0], y: offset[1], z: offset[2], w: 0)])
                .applyingFilter("CIMinimumComponent")
                .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0), "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
            let tinted = input.applyingFilter("CIColorMatrix", parameters: [
                "inputBiasVector": CIVector(x: target[0] - background[0], y: target[1] - background[1], z: target[2] - background[2], w: 0)])
            let output = tinted.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: input, kCIInputMaskImageKey: coverage])
            guard let image = Self.context.createCGImage(output, from: input.extent) else { return nil }
            return NSImage(cgImage: image, size: frame.size)
        }
        guard let sentence = paint(target), let focus = paint(focused) else { return nil }
        self.sentence = sentence
        self.focus = focus
    }

    private static func background(in snapshot: ScreenHighlightSnapshot, around rects: [CGRect]) -> [Double] {
        // Sample beside the matched text, not the window toolbar or the system theme.
        let width = snapshot.image.width, height = snapshot.image.height
        var samples: [[Double]] = []
        for rect in rects.prefix(40) {
            let x = Int((rect.midX - snapshot.frame.minX) / snapshot.frame.width * Double(width))
            let y = Int((snapshot.frame.maxY - rect.maxY - 2) / snapshot.frame.height * Double(height))
            guard x >= 0, x < width, y >= 0, y < height,
                  let pixel = snapshot.image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { continue }
            var rgba = [UInt8](repeating: 0, count: 4)
            let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                    bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                return true
            }
            if rendered { samples.append((0..<3).map { Double(rgba[$0]) / 255 }) }
        }
        guard !samples.isEmpty else { return [1, 1, 1] }
        return (0..<3).map { channel in samples.map { $0[channel] }.sorted()[samples.count / 2] }
    }
}
