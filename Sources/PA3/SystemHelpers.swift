import AppKit
import ApplicationServices
import Carbon
import Foundation

enum SystemHelpers {
    static func toggleOutputMute() {
        let script = """
        set isMuted to output muted of (get volume settings)
        if isMuted is true then
        set volume output muted false
        else
        set volume output muted true
        end if
        """
        runAppleScript(script)
    }

    static func closeWindow() {
        runAppleScript("tell application \"System Events\" to keystroke \"q\" using {command down}")
    }

    private static func runAppleScript(_ source: String) {
        var error: NSDictionary?
        if let script = NSAppleScript(source: source) {
            script.executeAndReturnError(&error)
        }
        if let error {
            Logger.warn("AppleScript failed: \(error)")
        }
    }
}

enum PasteHelper {
    @discardableResult
    static func paste() -> Bool {
        Logger.info("paste requested accessibilityTrusted=\(AXIsProcessTrusted())")
        if pasteWithInProcessSystemEvents() {
            Logger.info("paste sent with in-process System Events")
            return true
        }

        if pasteWithOsascriptProcess() {
            Logger.info("paste sent with osascript process")
            return true
        }

        Logger.warn("System Events paste failed; trying CGEvent fallback")
        if sendCommandVWithCGEvent() {
            Logger.info("paste sent with CGEvent fallback")
            return true
        }
        return false
    }

    private static func pasteWithInProcessSystemEvents() -> Bool {
        let source = "tell application \"System Events\" to keystroke \"v\" using command down"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            Logger.warn("in-process System Events paste failed: \(error)")
            return false
        }
        return true
    }

    private static func pasteWithOsascriptProcess() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "tell application \"System Events\" to keystroke \"v\" using command down"
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return true
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            Logger.warn("osascript paste failed status=\(process.terminationStatus) output=\(text)")
            return false
        } catch {
            Logger.warn("failed to run osascript paste: \(error)")
            return false
        }
    }

    private static func sendCommandVWithCGEvent() -> Bool {
        guard AXIsProcessTrusted() else {
            Logger.warn("CGEvent paste skipped because Accessibility is not trusted")
            return false
        }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            Logger.warn("unable to create paste CGEvents")
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}

final class GlobalHotKey {
    private let keyCode: UInt32
    private let modifiers: UInt32
    private let handler: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.handler = handler
    }

    func register() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            hotKey.handler()
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x50413348), id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            Logger.warn("RegisterEventHotKey failed: \(status)")
        } else {
            Logger.info("RegisterEventHotKey succeeded")
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        hotKeyRef = nil
        eventHandler = nil
    }
}
