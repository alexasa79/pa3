import AppKit

@MainActor
private final class HighlightCheckActions: NSObject {
    let scroll: NSScrollView
    var finished = false
    init(_ scroll: NSScrollView) { self.scroll = scroll }
    @objc func down() { move(90) }
    @objc func up() { move(-90) }
    @objc func offscreen() { move(650) }
    @objc func restore() { scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView) }
    @objc func finish() { finished = true }
    private func move(_ amount: CGFloat) {
        let clip = scroll.contentView
        clip.scroll(to: CGPoint(x: clip.bounds.minX, y: max(0, clip.bounds.minY + amount)))
        scroll.reflectScrolledClipView(clip)
    }
}

/// Opt-in, self-contained visual check. It uses no user documents or speech and
/// leaves the production delegate, models, and user preferences untouched.
@MainActor
func runScreenHighlightLiveCheck() async -> Int32 {
    guard CGPreflightScreenCaptureAccess() else { print("FAIL highlight check requires existing Screen Recording permission"); return 1 }
    let window = NSWindow(contentRect: CGRect(x: 200, y: 180, width: 900, height: 650),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "PA3 highlight check"
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.level = .floating
    window.isReleasedWhenClosed = false
    let root = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 650))
    let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
    scroll.hasVerticalScroller = true
    let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 880, height: 3500))
    text.isEditable = false
    text.isSelectable = false
    text.backgroundColor = .white
    text.textColor = .black
    text.font = NSFont(name: "Times-Roman", size: 26)!
    text.textContainerInset = NSSize(width: 25, height: 20)
    text.string = "Screen narration alignment check.\n\nFirst introductory line gives the page some space.\nSecond introductory line establishes the document.\nThird introductory line remains above the passage.\nFourth introductory line completes the introduction.\n\nA quiet garden waits for spring. Another small bird sings beside the window.\n\n" + (1...45).map { "Document row \($0) contains separate material beneath the selected passage.\n" }.joined()
    scroll.documentView = text
    root.addSubview(scroll)
    let actions = HighlightCheckActions(scroll)
    for (i, item) in [("Down 90 pt", #selector(HighlightCheckActions.down)), ("Up 90 pt", #selector(HighlightCheckActions.up)), ("Off screen", #selector(HighlightCheckActions.offscreen)), ("Restore", #selector(HighlightCheckActions.restore)), ("Finish check", #selector(HighlightCheckActions.finish))].enumerated() {
        let button = NSButton(title: item.0, target: actions, action: item.1)
        button.frame = CGRect(x: 12 + i * 175, y: 610, width: 165, height: 30)
        root.addSubview(button)
    }
    window.contentView = root
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    try? await Task.sleep(for: .milliseconds(400))
    let source = ScreenTextWindow(id: CGWindowID(window.windowNumber), pid: ProcessInfo.processInfo.processIdentifier)
    let overlay = ScreenNarrationOverlay()
    defer { overlay.clear(); window.orderOut(nil) }
    do {
        guard let snapshot = try await ScreenHighlightSnapshot.capture(source) else { print("FAIL source window not visible"); return 1 }
        var document = try await ScreenText.recognizeImage(snapshot.image)
        document.frame = snapshot.frame
        document.sourceWindow = source
        let range = (document.text as NSString).range(of: "garden")
        guard range.location != NSNotFound else { print("FAIL initial screen OCR did not find the fixture word"); return 1 }
        overlay.show(document, range: range)
        let deadline = Date().addingTimeInterval(180)
        var baseline: CGRect?, moved = false, hidden = false, restored = false
        var lastStatus = ""
        var lastRect: CGRect?
        while Date() < deadline && !actions.finished {
            if overlay.trackingStatus != lastStatus { lastStatus = overlay.trackingStatus; print(lastStatus) }
            if let rect = overlay.visibleFocusRects.first {
                if rect != lastRect { print("Focus rectangle: \(rect), scroll=\(scroll.contentView.bounds.minY)"); lastRect = rect }
                if baseline == nil { baseline = rect; print("Highlight aligned; use the test controls to move the passage") }
                if let baseline, abs(rect.midY - baseline.midY) > 70 { moved = true }
                if hidden, let baseline, abs(rect.midY - baseline.midY) < 3 { restored = true }
                window.title = "PA3 highlight check · aligned · moved=\(moved) · restored=\(restored)"
            } else if scroll.contentView.bounds.minY > 400 {
                hidden = true
                window.title = "PA3 highlight check · hidden off screen"
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard baseline != nil, moved, hidden, restored else {
            print("FAIL visual check incomplete: moved=\(moved) hidden=\(hidden) restored=\(restored)"); return 1
        }
        print("PASS live window capture, relocation after scrolling, offscreen suppression, and restoration")
        return 0
    } catch { print("FAIL live screen highlight check: \(error)"); return 1 }
}
