import AppKit

/// Keeps focus ownership across workspace transitions, but releases it after an
/// ordinary app switch. The grace period covers AppKit delivering deactivation
/// before the corresponding Space/occlusion notification.
struct WindowFocusRestoration {
    struct Snapshot {
        var enabled = true
        var visible = true
        var onActiveSpace = true
        var missionControl = false
        var key = false
        var appActive = false
        var otherPA3WindowIsKey = false
    }

    private(set) var ownsFocus = false
    private var leftDesktop = false
    private var enteredMissionControl = false
    private var focusLostAt: TimeInterval?
    private var returnStartedAt: TimeInterval?

    mutating func reset() { self = Self() }

    /// Returns true once per completed transition. Time is monotonic.
    mutating func update(_ s: Snapshot, now: TimeInterval) -> Bool {
        guard s.enabled, s.visible, !s.otherPA3WindowIsKey else {
            reset()
            return false
        }

        if s.key && s.appActive && s.onActiveSpace && !s.missionControl {
            reset()
            ownsFocus = true
            return false
        }
        guard ownsFocus else { return false }

        if !s.onActiveSpace { leftDesktop = true }
        if s.missionControl { enteredMissionControl = true }
        if !s.onActiveSpace || s.missionControl {
            returnStartedAt = nil
            return false
        }

        if leftDesktop || enteredMissionControl {
            // Allow the desktop animation and automatic app activation to settle.
            if returnStartedAt == nil { returnStartedAt = now }
            guard now - returnStartedAt! >= 0.25 else { return false }
            reset()
            return true
        }

        // Mission Control and an interactive Space swipe can resign the key
        // window while PA3 is still active. This alone is not an app switch.
        if s.appActive { focusLostAt = nil; return false }
        if focusLostAt == nil { focusLostAt = now }
        if now - focusLostAt! >= 1.5 { reset() }
        return false
    }
}

@MainActor
final class WindowFocusRestorer: NSObject {
    private weak var window: NSWindow?
    private var state = WindowFocusRestoration()
    private var timer: Timer?
    private var mouseMonitor: Any?
    private var enabled = false

    init(window: NSWindow) {
        self.window = window
        super.init()
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification] {
            center.addObserver(self, selector: #selector(windowChanged), name: name, object: window)
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSApplication.didHideNotification] {
            center.addObserver(self, selector: #selector(windowChanged), name: name, object: NSApp)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(windowChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state.ownsFocus, self.window?.isOnActiveSpace == true,
                      !Self.missionControlIsVisible() else { return }
                // A click in another app is an explicit choice, including during
                // the short interval after returning to this desktop.
                self.cancel()
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled { cancel() }
        else { sample() }
    }

    /// Explicit dismissals must cancel before orderOut/hide can emit notifications.
    func cancel() {
        state.reset()
        timer?.invalidate()
        timer = nil
    }

    func stop() {
        cancel()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func windowChanged(_ notification: Notification) { sample() }

    private func sample() {
        guard let window else { cancel(); return }
        let visible = window.isVisible && !window.isMiniaturized && !NSApp.isHidden
        let onSpace = window.isOnActiveSpace
        // Query the Dock only while a focused/pending pinned window is on this
        // desktop. Window metadata requires no screen-recording permission.
        let missionControl = enabled && visible && onSpace && (state.ownsFocus || window.isKeyWindow)
            && (!window.isKeyWindow || !NSApp.isActive)
            && Self.missionControlIsVisible()
        let shouldRestore = state.update(.init(
            enabled: enabled, visible: visible, onActiveSpace: onSpace,
            missionControl: missionControl, key: window.isKeyWindow,
            appActive: NSApp.isActive,
            otherPA3WindowIsKey: NSApp.keyWindow.map { $0 !== window } ?? false
        ), now: ProcessInfo.processInfo.systemUptime)

        if shouldRestore {
            // Do not use showWindow(): returning must preserve the current
            // dictation session and the app/window remembered as the paste target.
            // Never activate while off-space: moveToActiveSpace would pull PA3
            // onto the desktop the user just switched to.
            Logger.info("Restoring PA3 focus after workspace transition")
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }

        if state.ownsFocus && timer == nil {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !state.ownsFocus {
            timer?.invalidate()
            timer = nil
        }
    }

    private static func missionControlIsVisible() -> Bool {
        let dockPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .map(\.processIdentifier))
        guard !dockPIDs.isEmpty,
              let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        else { return false }
        return windows.contains { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, dockPIDs.contains(pid),
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double,
                  let height = bounds["Height"] as? Double else { return false }
            // The desktop-sized Mission Control/App Exposé backdrop is level
            // 18. The ordinary Dock itself is level 20, so do not treat that
            // level (or a small transient window) as Mission Control.
            return layer == 18 && NSScreen.screens.contains {
                width >= $0.frame.width * 0.8 && height >= $0.frame.height * 0.8
            }
        }
    }
}
