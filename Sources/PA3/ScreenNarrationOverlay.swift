import AppKit

private final class ScreenOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private func overlayPanel(frame: CGRect, interactive: Bool) -> NSPanel {
    let style: NSWindow.StyleMask = interactive ? [.borderless] : [.borderless, .nonactivatingPanel]
    let panel = ScreenOverlayPanel(contentRect: frame, styleMask: style,
                                   backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.isReleasedWhenClosed = false
    panel.level = .screenSaver
    panel.ignoresMouseEvents = !interactive
    panel.acceptsMouseMovedEvents = interactive
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.sharingType = interactive ? .readOnly : .none
    return panel
}

@MainActor
final class ScreenRectanglePicker {
    private var panels: [NSPanel] = []
    private var completion: (@MainActor (CGRect?) -> Void)?
    private var anchor: CGPoint?
    private var selection: CGRect?
    private var cursorPushed = false
    private var previousCursor: NSCursor?
    private var previousApp: NSRunningApplication?

    nonisolated static func captureRect(_ frame: CGRect, desktopTop: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: desktopTop - frame.maxY, width: frame.width, height: frame.height)
    }

    func start(completion: @escaping @MainActor (CGRect?) -> Void) {
        cancel()
        previousCursor = NSCursor.current
        previousApp = NSWorkspace.shared.frontmostApplication
        self.completion = completion
        // AppKit can only reliably own the visible cursor while PA3 is active.
        NSApp.activate(ignoringOtherApps: true)
        for screen in NSScreen.screens {
            let panel = overlayPanel(frame: screen.frame, interactive: true)
            let view = RectanglePickerView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.onDown = { [weak self] in self?.anchor = NSEvent.mouseLocation; self?.updateSelection() }
            view.onDrag = { [weak self] in self?.updateSelection() }
            view.onUp = { [weak self] in
                guard let self else { return }
                self.updateSelection()
                let rect = self.selection
                self.finish(rect.flatMap { $0.width >= 4 && $0.height >= 4 ? $0 : nil })
            }
            view.onCancel = { [weak self] in self?.finish(nil) }
            panel.title = "Select text to narrate"
            view.setAccessibilityElement(true)
            view.setAccessibilityRole(.group)
            view.setAccessibilityLabel("Drag to select text. Press Escape to cancel.")
            panel.contentView = view
            panels.append(panel)
            panel.orderFrontRegardless()
        }
        if let panel = panels.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? panels.first {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(panel.contentView)
        }
        NSCursor.crosshair.push()
        cursorPushed = true
    }

    private func updateSelection() {
        guard let anchor else { return }
        let point = NSEvent.mouseLocation
        selection = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                           width: abs(anchor.x - point.x), height: abs(anchor.y - point.y)).integral
        for panel in panels {
            (panel.contentView as? RectanglePickerView)?.selection = selection.map {
                $0.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
            }
        }
    }

    private func finish(_ rectangle: CGRect?) {
        let callback = completion
        cancel()
        callback?(rectangle)
    }

    func cancel() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        anchor = nil
        selection = nil
        completion = nil
        if cursorPushed { NSCursor.pop(); cursorPushed = false }
        previousCursor?.set()
        previousCursor = nil
        if let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier, NSApp.isActive {
            previousApp.activate()
        }
        previousApp = nil
    }
}

private final class RectanglePickerView: NSView {
    var onDown: (() -> Void)?
    var onDrag: (() -> Void)?
    var onUp: (() -> Void)?
    var onCancel: (() -> Void)?
    var selection: CGRect? { didSet { needsDisplay = true } }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // Keep the crosshair while moving between displays and during a drag.
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .enabledDuringMouseDrag],
            owner: self))
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { updatePointer() }
    override func mouseEntered(with event: NSEvent) { updatePointer() }
    override func mouseExited(with event: NSEvent) { needsDisplay = true }
    override func mouseMoved(with event: NSEvent) { updatePointer() }
    override func mouseDown(with event: NSEvent) { updatePointer(); onDown?() }
    override func mouseDragged(with event: NSEvent) { updatePointer(); onDrag?() }
    private func updatePointer() {
        guard window?.isVisible == true else { return }
        NSCursor.crosshair.set()
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { onUp?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.18).setFill()
        bounds.fill()
        if let selection {
            NSColor.clear.setFill()
            selection.fill(using: .copy)
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 2
            path.stroke()
        }
        let hint = "Drag to select text · Esc to cancel"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white]
        let size = (hint as NSString).size(withAttributes: attributes)
        let badge = CGRect(x: bounds.midX - ceil(size.width) / 2 - 18, y: bounds.maxY - 100,
                           width: ceil(size.width) + 36, height: ceil(size.height) + 24)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 8, yRadius: 8).fill()
        (hint as NSString).draw(at: CGPoint(x: badge.minX + 18, y: badge.minY + 12), withAttributes: attributes)
    }
}

/// Click-through windows leave the underlying app focused and usable during playback.
@MainActor
final class ScreenNarrationOverlay {
    private var panels: [NSPanel] = []
    private var document: ScreenTextDocument?
    private var range: NSRange?
    private var tracker: ScreenHighlightTracker?
    private var relocation: ScreenTextRelocation?
    private var snapshot: ScreenHighlightSnapshot?
    private var artwork: ScreenHighlightArtwork?
    private var artworkHash: Data?
    var trackingStatus: String { tracker?.status ?? "not tracking" }
    var visibleFocusRects: [CGRect] {
        panels.filter(\.isVisible).flatMap { panel in
            (panel.contentView as? NarrationHighlightView)?.focus.map { $0.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY) } ?? []
        }
    }

    func show(_ document: ScreenTextDocument, range: NSRange?) {
        if self.document?.frame != document.frame || self.document?.text != document.text || self.document?.sourceWindow != document.sourceWindow {
            clear()
            self.document = document
            if document.sourceWindow != nil {
                let tracker = ScreenHighlightTracker(source: document) { [weak self] relocation, snapshot in
                    guard let self else { return }
                    self.relocation = relocation
                    self.snapshot = snapshot
                    if let relocation, !relocation.document.spans.isEmpty, let snapshot {
                        let hash = snapshot.fingerprint(in: relocation.document.rectangles(for: NSRange(location: 0, length: document.text.utf16.count)))
                        if self.artworkHash != hash || self.artwork?.frame != snapshot.frame {
                            self.artwork = ScreenHighlightArtwork(snapshot: snapshot,
                                sampleRects: relocation.document.rectangles(for: NSRange(location: 0, length: document.text.utf16.count)))
                            self.artworkHash = hash
                        }
                    }
                    self.render()
                }
                self.tracker = tracker
                tracker.start()
            } else { Logger.warn("Screen highlight hidden: selection has no single source window") }
        }
        guard self.range != range else { return }
        self.range = range
        tracker?.focusRange = range
        render()
    }

    private func render() {
        guard let range, let relocation, relocation.contains(range), let snapshot, let artwork else {
            panels.forEach { $0.orderOut(nil) }
            return
        }
        let document = relocation.document
        let sentenceRange = ScreenHighlightGeometry.sentenceRange(in: document.text, containing: range)
        let layout = ScreenHighlightGeometry.layout(sentence: document.rectangles(for: sentenceRange), focus: document.rectangles(for: range))
        let sentence = layout.sentence
        let focus = layout.focus
        if panels.map(\.frame) != NSScreen.screens.map(\.frame) {
            panels.forEach { $0.orderOut(nil) }
            panels = NSScreen.screens.map { screen in
                let panel = overlayPanel(frame: screen.frame, interactive: false)
                panel.contentView = NarrationHighlightView(frame: CGRect(origin: .zero, size: screen.frame.size))
                return panel
            }
        }
        for panel in panels {
            func local(_ rects: [CGRect]) -> [CGRect] {
                rects.flatMap { rect in snapshot.visibleRegions.map { rect.intersection($0).intersection(panel.frame) } }
                    .filter { !$0.isNull && !$0.isEmpty }
                    .map { $0.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY) }
            }
            let view = panel.contentView as! NarrationHighlightView
            view.sentence = local(sentence)
            view.focus = local(focus)
            view.artwork = artwork
            view.imageFrame = artwork.frame.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
            view.needsDisplay = true
            if view.focus.isEmpty { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        }
    }

    func clear() {
        tracker?.stop()
        tracker = nil
        panels.forEach { $0.orderOut(nil) }
        panels = []
        document = nil
        range = nil
        relocation = nil
        snapshot = nil
        artwork = nil
        artworkHash = nil
    }
}

final class NarrationHighlightView: NSView {
    var sentence: [CGRect] = []
    var focus: [CGRect] = []
    var artwork: ScreenHighlightArtwork?
    var imageFrame: CGRect = .zero

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        guard let artwork else { return }
        let background = NSBezierPath()
        for rect in sentence { background.append(NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)) }
        NSGraphicsContext.saveGraphicsState()
        background.addClip()
        artwork.sentence.draw(in: imageFrame)
        let words = NSBezierPath()
        for rect in focus { words.appendRect(rect) }
        words.addClip()
        artwork.focus.draw(in: imageFrame)
        NSGraphicsContext.restoreGraphicsState()
    }
}
