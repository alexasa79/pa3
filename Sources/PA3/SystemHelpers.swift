import AppKit
import ApplicationServices
import Carbon
import Foundation
import IOKit.hidsystem

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
    static func paste(eventInterval: TimeInterval = 0) -> Bool {
        Logger.info("paste requested accessibilityTrusted=\(AXIsProcessTrusted())")
        guard AXIsProcessTrusted() else {
            Logger.warn("CGEvent paste skipped because Accessibility is not trusted")
            return false
        }
        guard let events = makePasteEvents() else {
            Logger.warn("unable to create paste CGEvents")
            return false
        }
        for (index, event) in events.enumerated() {
            if index > 0 && eventInterval > 0 { Thread.sleep(forTimeInterval: eventInterval) }
            event.post(tap: .cghidEventTap)
        }
        Logger.info("paste sent with explicit left Command down, V down/up, Command up CGEvents")
        return true
    }

    // Remote desktop clients can track modifier transitions separately from the
    // flags on V. Send a complete chord, including release, before returning.
    // Build every event before posting so allocation failure cannot strand Command.
    static func makePasteEvents() -> [CGEvent]? {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let commandDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: true),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: false) else {
            return nil
        }
        commandDown.type = .flagsChanged
        // Include the side-specific bit carried by a physical left Command key.
        // Consumers that distinguish left/right modifiers need more than maskCommand.
        let commandFlags = CGEventFlags.maskCommand.union(CGEventFlags(rawValue: UInt64(NX_DEVICELCMDKEYMASK)))
        commandDown.flags = commandFlags
        keyDown.flags = commandFlags
        keyUp.flags = commandFlags
        commandUp.type = .flagsChanged
        commandUp.flags = []
        return [commandDown, keyDown, keyUp, commandUp]
    }
}

final class GlobalHotKey: GlobalHotKeyRegistration {
    private let keyCode: UInt32
    private let modifiers: UInt32
    private let identifier: UInt32
    private let handler: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    init(keyCode: UInt32, modifiers: UInt32, identifier: UInt32, handler: @escaping () -> Void) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.identifier = identifier
        self.handler = handler
    }

    @discardableResult
    func register() -> OSStatus {
        unregister()
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x50413348, identifier.id == hotKey.identifier else {
                return OSStatus(eventNotHandledErr)
            }
            hotKey.handler()
            return noErr
        }
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard handlerStatus == noErr else { return handlerStatus }

        let hotKeyID = EventHotKeyID(signature: OSType(0x50413348), id: identifier)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            unregister()
            Logger.warn("RegisterEventHotKey failed: \(status)")
        } else {
            Logger.info("RegisterEventHotKey succeeded keyCode=\(keyCode)")
        }
        return status
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
