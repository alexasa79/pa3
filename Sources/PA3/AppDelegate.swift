import AppKit
import Carbon
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var controller: DictationController?
    private var hotKey: GlobalHotKey?
    private var previousApp: NSRunningApplication?
    private var lastExternalApp: NSRunningApplication?
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

        setupWorkspaceTracking()
        setupStatusItem()
        Logger.info("status item set up")
        setupWindow(controller: controller)
        Logger.info("window set up")
        setupHotKey()
        Logger.info("launch complete; waiting for activation")
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        controller?.shutdown()
        hotKey?.unregister()
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
        menu.addItem(NSMenuItem(title: "Show", action: #selector(showFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Start Dictation", action: #selector(startFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Stop Dictation", action: #selector(stopFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Restart Dictation", action: #selector(restartFromMenu), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitFromMenu), keyEquivalent: "q"))
        for item in menu.items {
            item.target = self
        }
        item.menu = menu
        statusItem = item
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
        Logger.info("remembered external app pid=\(app.processIdentifier) name=\(app.localizedName ?? "?")")
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
    }

    @objc private func statusButtonClicked() {
        showWindow()
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
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != NSRunningApplication.current.processIdentifier {
            previousApp = frontmost
            rememberExternalApp(frontmost)
        } else {
            previousApp = lastExternalApp
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        controller?.beginNewSession()
        controller?.startDictation()
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
        guard let app else {
            Logger.warn("No previous app to restore")
            afterRestore?()
            return
        }
        Logger.info("restoring previous app pid=\(app.processIdentifier) name=\(app.localizedName ?? "?")")
        app.activate(options: [.activateAllWindows])
        activateApplicationBundle(app)
        activateProcessWithSystemEvents(pid: app.processIdentifier)
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

    private func activateApplicationBundle(_ app: NSRunningApplication) {
        guard let bundleURL = app.bundleURL else {
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
            if let error {
                Logger.warn("NSWorkspace focus restore failed: \(error)")
            }
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
