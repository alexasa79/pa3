import AppKit
@preconcurrency import ApplicationServices
import Carbon
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var controller: DictationController?
    private let narration = NarrationService()
    private let downloads = ModelDownloadManager()
    private lazy var narrationDictionary = NarrationDictionary(path: userDataDirectory().appendingPathComponent("narration-dictionary.json"))
    private var dictionariesEditor: DictionariesEditor?
    private var dictionariesWindow: NSWindow?
    private var downloadWindow: NSWindow?
    private var hotKey: GlobalHotKey?
    private var narrationHotKey: GlobalHotKey?
    private var screenHotKey: GlobalHotKey?
    private let screenCapture = ScreenTextCapture()
    private var selectionRequest: UUID?
    private var narrationNotice: NSPanel?
    private var previousApp: NSRunningApplication?
    private var previousWindow: AXUIElement?
    private var lastExternalApp: NSRunningApplication?
    private var lastExternalWindow: AXUIElement?
    private var workspaceObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.setup()
        Logger.info("applicationDidFinishLaunching")

        let transcriber = TranscriberService()
        let controller = DictationController(transcriber: transcriber)
        controller.onPasteAndHide = { [weak self] text in
            self?.pasteAndHide(text)
        }
        controller.onHide = { [weak self] in
            self?.hideWindow()
        }
        controller.onQuit = { [weak self] in
            self?.quit()
        }
        self.controller = controller
        controller.onOpenDictionaries = { [weak self] in self?.openDictionaries(tab: 0) }
        narration.pronunciationDictionary = { [weak self] in try self?.narrationDictionary.pronunciations() ?? [:] }
        downloads.onPresent = { [weak self] in self?.showModelDownloads() }
        controller.prepareModels = { [weak self] in self?.downloads.ensure(["whisper"]) ?? false }
        narration.prepareModels = { [weak self] in self?.downloads.ensure(["qwen", "audio"]) ?? false }
        narration.modelDownloadHealth = { [weak self] in self?.downloads.health ?? [:] }
        narration.isDictationBusy = { [weak controller] in controller?.narrationIsBlocked ?? false }
        controller.onDictationWillStart = { [weak self] in self?.cancelNarration() }
        narration.onSelectionFailure = { [weak self] _ in
            self?.showNarrationNotice("Could not finish narration. Select the text and try again.")
        }
        narration.start()

        setupWorkspaceTracking()
        setupStatusItem()
        Logger.info("status item set up")
        setupWindow(controller: controller)
        Logger.info("window set up")
        setupHotKey()
        Logger.info("launch complete; waiting for activation")
        downloads.ensureModels()
    }

    func applicationWillTerminate(_ notification: Notification) {
        cancelNarration()
        downloads.cancel()
        narration.shutdown()
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        controller?.shutdown()
        hotKey?.unregister()
        narrationHotKey?.unregister()
        screenHotKey?.unregister()
        Logger.close()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = menuBarIcon()
        item.button?.target = self
        item.button?.action = #selector(statusButtonClicked)

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Start dictation", action: #selector(startFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Read selection / Stop   ⌃⌥⌘O", action: #selector(readSelection), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Read screen rectangle / Stop   ⌃⌥⌘R", action: #selector(readScreenRectangle), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Stop narration", action: #selector(stopNarrationFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Dictionaries…", action: #selector(showDictionaries), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Speech models…", action: #selector(showModelDownloads), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitFromMenu), keyEquivalent: "q"))
        for item in menu.items {
            item.target = self
        }
        item.menu = menu
        statusItem = item
    }

    @objc private func showDictionaries() { openDictionaries(tab: 1) }

    private func openDictionaries(tab: Int) {
        guard let controller else { return }
        if let dictionariesWindow, dictionariesWindow.isVisible {
            dictionariesEditor?.tab = tab
            dictionariesWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let editor = DictionariesEditor(controller: controller, dictionary: narrationDictionary, tab: tab)
        dictionariesEditor = editor
        let view = DictionariesView(controller: controller, dictionary: narrationDictionary,
            preview: { [weak self] entry in
                guard let self else { return "PA3 is unavailable." }
                do {
                    let data = try JSONSerialization.data(withJSONObject: ["text": entry.spelling,
                        "mode": "replace", "pronunciations": [entry.spelling: entry.pronunciation]])
                    let response = self.narration.submit(data)
                    guard response.status == 202 else {
                        let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
                        return json?["error"] as? String ?? "Could not start preview."
                    }
                    return nil
                } catch { return error.localizedDescription }
            }, stopPreview: { [weak self] in self?.narration.stopAll() }, editor: editor)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 480),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "PA3 Dictionaries"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        dictionariesWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func menuBarIcon() -> NSImage? {
        let url = Bundle.main.resourceURL?.appendingPathComponent("MenuBarIcon.png")
        let image = url.flatMap { NSImage(contentsOf: $0) } ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "PA3")
        image?.isTemplate = true
        return image
    }

    private func setupWorkspaceTracking() {
        rememberExternalApp(NSWorkspace.shared.frontmostApplication)
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            Task { @MainActor in
                self?.rememberExternalApp(app)
            }
        }
    }

    private func rememberExternalApp(_ app: NSRunningApplication?) {
        guard let app, !app.isTerminated else {
            return
        }
        if app.processIdentifier == NSRunningApplication.current.processIdentifier {
            return
        }
        lastExternalApp = app
        lastExternalWindow = focusedWindow(for: app.processIdentifier)
        Logger.info("remembered external app pid=\(app.processIdentifier) name=\(app.localizedName ?? "?") window=\(lastExternalWindow == nil ? "nil" : "captured")")
    }

    private func focusedWindow(for pid: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value)
        guard status == .success, let value else {
            Logger.info("AX focused window unavailable pid=\(pid) status=\(status.rawValue)")
            return nil
        }
        return (value as! AXUIElement)
    }

    private func raiseAXWindow(_ window: AXUIElement) {
        let raise = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        let main = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        let focused = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        Logger.info("AX window raise=\(raise.rawValue) main=\(main.rawValue) focused=\(focused.rawValue)")
    }

    private func setupWindow(controller: DictationController) {
        let content = DictationView(controller: controller)
        let hosting = NSHostingView(rootView: content)
        let window = KeyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 620),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "PA3"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.contentView = hosting
        window.center()
        window.delegate = self
        self.window = window
    }

    private func setupHotKey() {
        let modifiers = UInt32((1 << 8) | (1 << 11) | (1 << 12))
        hotKey = GlobalHotKey(keyCode: 35, modifiers: modifiers) { [weak self] in
            DispatchQueue.main.async {
                Logger.info("global hotkey pressed")
                self?.showWindow()
            }
        }
        hotKey?.register()
        Logger.info("global hotkey registered Ctrl+Option+Command+P")
        narrationHotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_O), modifiers: modifiers) { [weak self] in
            DispatchQueue.main.async {
                Logger.info("narration hotkey pressed")
                self?.readSelection()
            }
        }
        narrationHotKey?.register()
        Logger.info("narration hotkey registered Ctrl+Option+Command+O")
        screenHotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: modifiers) { [weak self] in
            DispatchQueue.main.async { self?.readScreenRectangle() }
        }
        screenHotKey?.register()
        Logger.info("screen narration hotkey registered Ctrl+Option+Command+R")
    }

    @objc private func readSelection() {
        if selectionRequest != nil || narration.hasNarration {
            stopNarrationFromMenu()
            return
        }
        guard controller?.narrationIsBlocked != true else {
            showNarrationNotice("Stop dictation before narrating a selection.")
            return
        }
        guard AXIsProcessTrusted() else {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            showNarrationNotice("Allow PA3 in System Settings → Privacy & Security → Accessibility.")
            return
        }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let source = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? lastExternalApp : frontmost
        guard let source, !source.isTerminated else { showNarrationNotice("No active app to read from."); return }
        let pid = source.processIdentifier
        Logger.info("Selection read requested pid=\(pid) app=\(source.bundleIdentifier ?? "unknown")")
        let request = UUID()
        selectionRequest = request
        showNarrationNotice("Reading selection…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = SelectedText.read(pid: pid)
            Task { @MainActor in
                guard let self, self.selectionRequest == request else { return }
                self.selectionRequest = nil
                guard let text = result.text else {
                    Logger.warn("Selection read failed pid=\(pid): \(result.message)")
                    self.showNarrationNotice(result.message)
                    return
                }
                let response = self.narration.narrateSelection(result)
                if response.status == 202 {
                    self.showNarrationNotice("Narrating selection · ⌃⌥⌘O to stop")
                    Logger.info("Selection narration accepted pid=\(pid) chars=\(text.count)")
                } else {
                    let error = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
                    self.showNarrationNotice(error?["error"] as? String ?? "Could not start narration.")
                }
            }
        }
    }

    @objc private func readScreenRectangle() {
        if selectionRequest != nil || narration.hasNarration {
            stopNarrationFromMenu()
            return
        }
        guard controller?.narrationIsBlocked != true else {
            showNarrationNotice("Stop dictation before reading screen text.")
            return
        }
        beginScreenCapture()
    }

    private func beginScreenCapture() {
        let request = UUID()
        selectionRequest = request
        // Hide our notice before the system freezes the screen for selection.
        narrationNotice?.orderOut(nil)
        narrationNotice = nil
        Logger.info("Screen rectangle requested; drag to select, Escape to cancel")
        // Allow the menu to dismiss and shortcut modifiers to be released.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.selectionRequest == request else { return }
            self.screenCapture.start(recognizing: { [weak self] in
                self?.showNarrationNotice("Recognizing screen text…")
            }, completion: { [weak self] result in
                guard let self, self.selectionRequest == request else { return }
                self.selectionRequest = nil
                guard let text = result.text else {
                    self.showNarrationNotice(result.message)
                    return
                }
                let response = self.narration.narrateSelection(result)
                if response.status == 202 {
                    Logger.info("Screen narration accepted chars=\(text.count)")
                    self.showNarrationNotice("Narrating screen text · ⌃⌥⌘O to stop")
                } else {
                    let error = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
                    self.showNarrationNotice(error?["error"] as? String ?? "Could not start narration.")
                }
            })
        }
    }

    private func cancelNarration() {
        selectionRequest = nil
        screenCapture.cancel()
        narration.stopAll()
    }

    private func showNarrationNotice(_ message: String) {
        Logger.info("Narration notice: \(message)")
        narrationNotice?.orderOut(nil)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 76),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView:
            HStack(spacing: 12) {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color(nsColor: PaperTheme.ink))
                Text(message).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            }.padding(18).frame(width: 460).background(.regularMaterial))
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 230, y: screen.visibleFrame.maxY - 106))
        }
        panel.orderFrontRegardless()
        narrationNotice = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self, weak panel] in
            guard let self, let panel, self.narrationNotice === panel else { return }
            panel.orderOut(nil)
            self.narrationNotice = nil
        }
    }

    @objc private func statusButtonClicked() {
        showWindow()
    }

    @objc private func stopNarrationFromMenu() {
        cancelNarration()
        showNarrationNotice("Narration stopped")
    }

    @objc private func showFromMenu() {
        showWindow()
    }

    @objc private func restartFromMenu() {
        showWindow()
        controller?.restartDictation()
    }

    @objc private func startFromMenu() {
        showWindow()
        controller?.startDictation()
    }

    @objc private func stopFromMenu() {
        controller?.stopDictation()
    }

    @objc private func quitFromMenu() {
        quit()
    }

    private func showWindow() {
        guard downloads.ensure(["whisper"]) else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != NSRunningApplication.current.processIdentifier {
            previousApp = frontmost
            rememberExternalApp(frontmost)
            previousWindow = lastExternalWindow
        } else {
            previousApp = lastExternalApp
            previousWindow = lastExternalWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        controller?.beginNewSession()
        controller?.startDictation()
    }

    @objc private func showModelDownloads() {
        if downloadWindow == nil {
            let content = ModelDownloadView(manager: downloads) { [weak self] in self?.downloadWindow?.orderOut(nil) }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 556, height: 530),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "PA3 · Speech models"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: content)
            window.center()
            self.downloadWindow = window
        }
        downloads.refresh()
        downloadWindow?.orderFrontRegardless()
    }

    private func hideWindow() {
        dismissPA3AndRestorePreviousApp()
    }

    private func pasteAndHide(_ text: String) {
        Logger.info("pasteAndHide chars=\(text.count)")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let wrotePasteboard = pasteboard.setString(text, forType: .string)
        Logger.info("pasteboard write success=\(wrotePasteboard)")

        dismissPA3AndRestorePreviousApp {
            Logger.info("running paste after focus restore")
            PasteHelper.paste()
        }
    }

    private func dismissPA3AndRestorePreviousApp(afterRestore: (() -> Void)? = nil) {
        window?.orderOut(nil)
        NSApp.hide(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.restorePreviousApp(afterRestore: afterRestore)
        }
    }

    private func restorePreviousApp(afterRestore: (() -> Void)? = nil) {
        let app = previousApp?.isTerminated == false ? previousApp : lastExternalApp
        let window = previousWindow ?? lastExternalWindow
        guard let app else {
            Logger.warn("No previous app to restore")
            afterRestore?()
            return
        }
        Logger.info("restoring previous app pid=\(app.processIdentifier) name=\(app.localizedName ?? "?") window=\(window == nil ? "nil" : "remembered")")
        app.activate()
        activateProcessWithSystemEvents(pid: app.processIdentifier)
        if let window {
            raiseAXWindow(window)
        }
        waitForFocus(app: app, deadline: Date().addingTimeInterval(1.0), afterRestore: afterRestore)
    }

    private func waitForFocus(app: NSRunningApplication, deadline: Date, afterRestore: (() -> Void)?) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier || Date() >= deadline {
            Logger.info("focus restore complete frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
            afterRestore?()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.waitForFocus(app: app, deadline: deadline, afterRestore: afterRestore)
        }
    }

    private func activateProcessWithSystemEvents(pid: pid_t) {
        let script = """
        tell application "System Events"
            set frontmost of first process whose unix id is \(pid) to true
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            Logger.warn("System Events focus restore failed: \(error)")
        }
    }

    private func quit() {
        controller?.shutdown()
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        controller?.discardAndHide()
        return false
    }
}

final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
