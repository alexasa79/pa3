import AppKit
import ApplicationServices
import Carbon
import Foundation

enum SystemHelpers {
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
        guard AXIsProcessTrusted() else {
            Logger.warn("CGEvent paste skipped because Accessibility is not trusted")
            return false
        }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            Logger.warn("unable to create paste CGEvents")
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        Logger.info("paste sent with physical Command+V CGEvents")
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
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x50413348, identifier.id == hotKey.keyCode + 1 else {
                return OSStatus(eventNotHandledErr)
            }
            hotKey.handler()
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x50413348), id: keyCode + 1)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            Logger.warn("RegisterEventHotKey failed: \(status)")
        } else {
            Logger.info("RegisterEventHotKey succeeded keyCode=\(keyCode)")
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
