import AppKit
@preconcurrency import ScreenCaptureKit
import Vision
import CryptoKit

struct ScreenTextWindow: Sendable, Equatable {
    let id: CGWindowID
    let pid: pid_t

    @MainActor
    static func containing(_ selection: CGRect) -> ScreenTextWindow? {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let id = window[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            let frame = CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
            if frame.contains(CGPoint(x: selection.midX, y: selection.midY)) {
                // A selection across unrelated windows has no single surface to follow.
                let overlap = frame.intersection(selection)
                return overlap.width * overlap.height >= selection.width * selection.height * 0.95 ? ScreenTextWindow(id: id, pid: pid) : nil
            }
        }
        return nil
    }
}

struct ScreenHighlightSnapshot: Sendable {
    let image: CGImage
    let frame: CGRect
    let visibleRegions: [CGRect]

    func cropped(to region: CGRect) -> ScreenHighlightSnapshot? {
        let clipped = region.intersection(frame)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        let sx = Double(image.width) / frame.width, sy = Double(image.height) / frame.height
        let pixels = CGRect(x: (clipped.minX - frame.minX) * sx, y: (frame.maxY - clipped.maxY) * sy,
            width: clipped.width * sx, height: clipped.height * sy).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let image = image.cropping(to: pixels) else { return nil }
        let actual = CGRect(x: frame.minX + pixels.minX / sx, y: frame.maxY - pixels.maxY / sy,
                            width: pixels.width / sx, height: pixels.height / sy)
        return ScreenHighlightSnapshot(image: image, frame: actual,
            visibleRegions: visibleRegions.map { $0.intersection(actual) }.filter { !$0.isNull && !$0.isEmpty })
    }

    func fingerprint(in rects: [CGRect]) -> Data {
        guard !rects.isEmpty else {
            guard let data = image.dataProvider?.data else { return Data() }
            return Data(SHA256.hash(data: data as Data))
        }
        var hash = SHA256()
        for rect in ScreenHighlightGeometry.lineRects(rects) {
            let padded = rect.insetBy(dx: -6, dy: -6).intersection(frame)
            guard !padded.isNull && !padded.isEmpty else { continue }
            let pixelRect = CGRect(x: (padded.minX - frame.minX) / frame.width * Double(image.width),
                y: (frame.maxY - padded.maxY) / frame.height * Double(image.height),
                width: padded.width / frame.width * Double(image.width), height: padded.height / frame.height * Double(image.height)).integral
            guard let crop = image.cropping(to: pixelRect),
                  let context = CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            if let bytes = context.data { hash.update(data: Data(bytes: bytes, count: crop.width * crop.height * 4)) }
        }
        return Data(hash.finalize())
    }

    @MainActor
    static func capture(_ source: ScreenTextWindow) async throws -> ScreenHighlightSnapshot? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == source.id && $0.owningApplication?.processID == source.pid }) else { return nil }
        let ownWindows = content.windows.filter {
            $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier && $0.windowID != source.id
        }
        let pieces = content.displays.compactMap { display -> (SCDisplay, CGRect)? in
            let rect = window.frame.intersection(display.frame)
            return rect.isNull || rect.isEmpty ? nil : (display, rect)
        }
        guard !pieces.isEmpty else { return nil }
        let bounds = pieces.dropFirst().reduce(pieces[0].1) { $0.union($1.1) }
        let filters = pieces.map { display, _ in
            // The source may be a self-contained check window. Keep that one window
            // while excluding all of PA3's panels, notices, and highlights.
            SCContentFilter(display: display, excludingWindows: ownWindows)
        }
        let scale = Double(filters.map(\.pointPixelScale).max() ?? 1)
        let width = max(1, Int((bounds.width * scale).rounded()))
        let height = max(1, Int((bounds.height * scale).rounded()))
        guard width * height <= 40_000_000,
              let composite = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NarrationText.Invalid("Source window is too large for live highlighting")
        }
        // Capture only the visible portion of the selected source window. Unlike a
        // window-only capture, this includes real occlusions and cannot reveal text
        // that is behind another app. All pixels remain in memory for this session.
        composite.setFillColor(CGColor(gray: 1, alpha: 1))
        composite.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (index, piece) in pieces.enumerated() {
            let (display, rect) = piece
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            configuration.width = max(1, Int((rect.width * scale).rounded()))
            configuration.height = max(1, Int((rect.height * scale).rounded()))
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filters[index], configuration: configuration)
            composite.draw(image, in: CGRect(x: (rect.minX - bounds.minX) * scale, y: (bounds.maxY - rect.maxY) * scale,
                                            width: rect.width * scale, height: rect.height * scale))
        }
        guard let image = composite.makeImage() else { throw NarrationText.Invalid("Screen highlight capture failed") }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = CGRect(x: bounds.minX, y: top - bounds.maxY, width: bounds.width, height: bounds.height)
        let regions = pieces.map { _, rect in CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height) }
        return ScreenHighlightSnapshot(image: image, frame: frame, visibleRegions: regions)
    }
}

/// Relocate source ranges using unique surrounding words and fresh OCR geometry.
struct ScreenTextRelocation {
    struct Word {
        let text: String
        let range: NSRange
    }
    let sourceWords: [Word]
    let matchedWords: Set<Int>
    let document: ScreenTextDocument

    static func words(_ text: String) -> [Word] {
        let regex = try! NSRegularExpression(pattern: #"[\p{L}\p{N}\p{S}&]+(?:['’][\p{L}\p{N}\p{S}&]+)*"#)
        return regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)).map {
            Word(text: (text as NSString).substring(with: $0.range).lowercased().replacingOccurrences(of: "’", with: "'"), range: $0.range)
        }
    }

    init(source: ScreenTextDocument, current: ScreenTextDocument) {
        let original = Self.words(source.text), visible = Self.words(current.text)
        sourceWords = original
        let width = min(5, original.count)
        var positions: [Int: [Int]] = [:]
        var contradictory = false
        if width >= 3 && visible.count >= width {
            func groups(_ words: [Word]) -> [String: [Int]] {
                var result: [String: [Int]] = [:]
                for i in 0...(words.count - width) {
                    result[words[i..<(i + width)].map(\.text).joined(separator: "\u{1f}"), default: []].append(i)
                }
                return result
            }
            let originals = groups(original), candidates = groups(visible)
            for (key, offsets) in originals where offsets.count == 1 {
                guard let matches = candidates[key], matches.count == 1 else { continue }
                for offset in 0..<width {
                    let index = offsets[0] + offset, position = matches[0] + offset
                    if let existing = positions[index], existing != [position] { contradictory = true }
                    positions[index] = [position]
                }
            }
            // Reordered or contradictory anchors cannot establish reading position.
            let ordered = positions.keys.sorted()
            if contradictory || zip(ordered, ordered.dropFirst()).contains(where: { positions[$0.0]!.last! >= positions[$0.1]!.first! }) { positions = [:] }
        }
        // Five-word anchors locate the passage uniquely. Extend their context to
        // short prefixes/suffixes and words beside a small OCR error instead of
        // requiring every displayed word to belong to its own perfect anchor.
        for anchor in positions.keys.sorted() {
            for direction in [-1, 1] {
                var index = anchor + direction
                var weakMatches = 0
                var position = (direction < 0 ? positions[anchor]!.first! : positions[anchor]!.last!) + direction
                while original.indices.contains(index), visible.indices.contains(position), positions[index] == nil {
                    let reference = original[index].text, candidate = visible[position].text
                    if reference == candidate {
                        weakMatches = 0
                        positions[index] = [position]
                    } else {
                        let next = position + direction
                        let pair = [position, next].sorted()
                        if visible.indices.contains(next), pair.map({ visible[$0].text }).joined() == reference {
                            // A print-hyphenated word can remain two OCR tokens.
                            weakMatches = 0
                            positions[index] = pair
                            position = next
                        } else if candidate.count == 1, visible.indices.contains(next), visible[next].text == reference {
                            // A standalone math glyph may be absent in one OCR pass.
                            position = next
                            continue
                        } else if weakMatches == 0, reference.count == candidate.count, reference.count <= 2 {
                            // Tiny symbol/letter confusions are positionally bounded
                            // by the uniquely matched passage, never searched globally.
                            weakMatches += 1
                            positions[index] = [position]
                        } else { break }
                    }
                    index += direction
                    position += direction
                }
            }
        }
        let ordered = positions.keys.sorted()
        if zip(ordered, ordered.dropFirst()).contains(where: { positions[$0.0]!.last! >= positions[$0.1]!.first! }) { positions = [:] }
        matchedWords = Set(positions.keys)
        var spans: [ScreenTextSpan] = []
        for index in positions.keys.sorted() {
            for position in positions[index]! {
                let range = visible[position].range
                spans += current.spans.filter { NSIntersectionRange($0.range, range).length > 0 }.map {
                    ScreenTextSpan(range: original[index].range, box: $0.box)
                }
            }
        }
        document = ScreenTextDocument(text: source.text, spans: spans, frame: current.frame)
    }

    func contains(_ range: NSRange) -> Bool {
        let indices = sourceWords.indices.filter { NSIntersectionRange(sourceWords[$0].range, range).length > 0 }
        return !indices.isEmpty && indices.allSatisfy { matchedWords.contains($0) }
    }
}

@MainActor
final class ScreenHighlightTracker {
    typealias Capture = @MainActor (ScreenTextWindow) async throws -> ScreenHighlightSnapshot?
    typealias Recognize = @MainActor (CGImage) async throws -> ScreenTextDocument
    private let source: ScreenTextDocument
    private let capture: Capture
    private let recognize: Recognize
    private let onUpdate: (ScreenTextRelocation?, ScreenHighlightSnapshot?) -> Void
    private var task: Task<Void, Never>?
    private var monitors: [Any] = []
    private var activation: NSObjectProtocol?
    private var revision = 0
    private var running = true
    private var lastInput = Date.distantPast
    private var fingerprint: Data?
    private var frame: CGRect?
    private var relocation: ScreenTextRelocation?
    private var loggedFailure = false
    private var needsGlobalSearch = false
    private(set) var status = "waiting"
    var focusRange: NSRange?

    init(source: ScreenTextDocument, capture: @escaping Capture = ScreenHighlightSnapshot.capture,
         recognize: @escaping Recognize = ScreenText.recognizeImage,
         onUpdate: @escaping (ScreenTextRelocation?, ScreenHighlightSnapshot?) -> Void) {
        self.source = source
        self.capture = capture
        self.recognize = recognize
        self.onUpdate = onUpdate
    }

    func start() {
        let mask: NSEvent.EventTypeMask = [.scrollWheel, .leftMouseDown, .leftMouseDragged, .rightMouseDown, .keyDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidate() }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.invalidate() }; return event
        }) { monitors.append(monitor) }
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.invalidate() } }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .milliseconds(400))
                if self == nil { break }
            }
        }
    }

    func invalidate() {
        needsGlobalSearch = true
        revision += 1
        lastInput = Date()
        fingerprint = nil
        onUpdate(nil, nil)
    }

    func refresh() async {
        guard running, let window = source.sourceWindow else { return }
        let started = revision
        do {
            guard let snapshot = try await capture(window) else {
                status = "source unavailable; frontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1), source=\(window.pid)"
                if running { onUpdate(nil, nil) }; return
            }
            guard running, revision == started else { return }
            // Once located, changes outside the selected passage do not invalidate
            // its geometry. A video, clock, or caret elsewhere cannot make it blink.
            let focusMissing = focusRange.map { relocation?.contains($0) != true } ?? false
            let verifiedRects = focusMissing ? [] : relocation.map { $0.document.rectangles(for: NSRange(location: 0, length: source.text.utf16.count)) } ?? []
            let hash = snapshot.fingerprint(in: verifiedRects)
            let changed = hash != fingerprint || frame != snapshot.frame
            if changed { onUpdate(nil, nil) }
            // Wait out wheel momentum and key repeats. A late OCR response can never
            // restore coordinates invalidated by a newer event or cancelled session.
            guard Date().timeIntervalSince(lastInput) >= 0.18 else { return }
            if changed || relocation == nil {
                let match = try await locate(in: snapshot)
                guard running, revision == started else { return }
                relocation = match
                needsGlobalSearch = false
                let missing = focusRange.map { !match.contains($0) } ?? false
                fingerprint = snapshot.fingerprint(in: missing ? [] : match.document.rectangles(for: NSRange(location: 0, length: source.text.utf16.count)))
                frame = snapshot.frame
            }
            guard running, revision == started else { return }
            loggedFailure = false
            status = "matched=\(relocation?.matchedWords.count ?? 0)/\(relocation?.sourceWords.count ?? 0), regions=\(snapshot.visibleRegions.count), frame=\(snapshot.frame)"
            onUpdate(relocation, snapshot)
        } catch {
            guard running, revision == started else { return }
            status = "capture error: \(error)"
            onUpdate(nil, nil)
            if !loggedFailure { Logger.warn("Screen highlight tracking unavailable: \(error)"); loggedFailure = true }
        }
    }

    func locate(in snapshot: ScreenHighlightSnapshot) async throws -> ScreenTextRelocation {
        func read(_ region: ScreenHighlightSnapshot) async throws -> ScreenTextRelocation {
            var doc = try await recognize(region.image)
            doc.frame = region.frame
            return ScreenTextRelocation(source: source, current: doc)
        }
        func complete(_ match: ScreenTextRelocation) -> Bool {
            !match.sourceWords.isEmpty && match.matchedWords.count == match.sourceWords.count
        }
        // At the original or last verified position, use the selected region rather
        // than OCR of unrelated columns, toolbars, and neighboring paragraphs.
        let hint = relocation?.document.frame ?? source.frame
        var local: ScreenTextRelocation?
        if !needsGlobalSearch, let hint, let crop = snapshot.cropped(to: hint) {
            local = try await read(crop)
            if complete(local!) || crop.frame == snapshot.frame { return local! }
        }
        let coarse = try await read(snapshot)
        if complete(coarse) { return coarse }
        guard !coarse.matchedWords.isEmpty, let selection = source.frame else { return coarse }
        // Unique anchors locate a crop after scrolling or resizing. The crop is
        // only a search region: fresh OCR still supplies every returned rectangle.
        var samples: [(before: CGRect, after: CGRect)] = []
        for index in coarse.matchedWords.sorted() {
            let word = coarse.sourceWords[index]
            let before = source.rectangles(for: word.range), after = coarse.document.rectangles(for: word.range)
            if before.count == 1, after.count == 1, before[0].height > 0 { samples.append((before[0], after[0])) }
        }
        guard !samples.isEmpty else { return coarse }
        func median(_ values: [CGFloat]) -> CGFloat { values.sorted()[values.count / 2] }
        let scale = median(samples.map { $0.after.height / $0.before.height })
        let dx = median(samples.map { $0.after.midX - $0.before.midX * scale })
        let dy = median(samples.map { $0.after.midY - $0.before.midY * scale })
        var region = CGRect(x: selection.minX * scale + dx, y: selection.minY * scale + dy,
                            width: selection.width * scale, height: selection.height * scale)
        for sample in samples { region = region.union(sample.after) }
        region = region.insetBy(dx: 0, dy: -median(samples.map { $0.after.height }))
        var best = coarse
        if let crop = snapshot.cropped(to: region) {
            let refined = try await read(crop)
            if refined.matchedWords.count >= best.matchedWords.count { best = refined }
        }
        if let local, local.matchedWords.count > best.matchedWords.count { best = local }
        return best
    }

    func stop() {
        running = false
        revision += 1
        task?.cancel()
        task = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        relocation = nil
        onUpdate(nil, nil)
    }
}
