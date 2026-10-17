import AppKit
import Carbon

// These IDs identify actions, rather than key codes. Two actions can use the
// same physical key with different modifiers without sharing a Carbon event ID.
enum GlobalShortcutAction: Int, CaseIterable, Codable {
    case dictation = 1, selection, screen

    var title: String {
        switch self {
        case .dictation: "Open dictation"
        case .selection: "Read selection / Stop"
        case .screen: "Read screen rectangle / Stop"
        }
    }

    var defaultBinding: GlobalShortcutBinding {
        let code: Int = switch self {
        case .dictation: kVK_ANSI_P
        case .selection: kVK_ANSI_O
        case .screen: kVK_ANSI_R
        }
        return GlobalShortcutBinding(keyCode: UInt32(code), modifiers: UInt32(controlKey | optionKey | cmdKey))
    }
}

struct GlobalShortcutBinding: Codable, Equatable, Hashable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let allowedModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)
    static let modifierKeyCodes: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    var isValid: Bool {
        keyCode <= 126 && !Self.modifierKeyCodes.contains(keyCode)
            && modifiers & ~Self.allowedModifiers == 0
            && modifiers & UInt32(controlKey | optionKey | cmdKey) != 0
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        var result: UInt32 = 0
        if event.modifierFlags.contains(.control) { result |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { result |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { result |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.command) { result |= UInt32(cmdKey) }
        modifiers = result
    }

    @MainActor var display: String {
        var prefix = ""
        if modifiers & UInt32(controlKey) != 0 { prefix += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { prefix += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { prefix += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { prefix += "⌘" }
        return prefix + keyLabel
    }

    @MainActor private var keyLabel: String {
        let special: [UInt32: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc",
            76: "⌤", 114: "Help", 115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
            100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13",
            107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"]
        if let label = special[keyCode] { return label }
        let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        if let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
            let layout = UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKey: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKey,
                characters.count, &length, &characters)
            if status == noErr, length > 0 {
                let label = String(utf16CodeUnits: characters, count: length).uppercased()
                return (65...92).contains(keyCode) ? "Keypad \(label)" : label
            }
        }
        return "Key \(keyCode)"
    }
}

struct GlobalShortcutConfiguration: Codable, Equatable {
    var dictation = GlobalShortcutAction.dictation.defaultBinding
    var selection = GlobalShortcutAction.selection.defaultBinding
    var screen = GlobalShortcutAction.screen.defaultBinding

    subscript(action: GlobalShortcutAction) -> GlobalShortcutBinding {
        get {
            switch action {
            case .dictation: dictation
            case .selection: selection
            case .screen: screen
            }
        }
        set {
            switch action {
            case .dictation: dictation = newValue
            case .selection: selection = newValue
            case .screen: screen = newValue
            }
        }
    }

    var validationError: String? {
        var seen = Set<GlobalShortcutBinding>()
        for action in GlobalShortcutAction.allCases {
            guard self[action].isValid else { return "Use a key with Control, Option, or Command for \(action.title)." }
            guard seen.insert(self[action]).inserted else { return "Each action needs a different shortcut." }
        }
        return nil
    }

    static let preferencesKey = "globalKeyboardShortcuts"

    static func load(from preferences: UserDefaults) -> Self {
        guard let data = preferences.data(forKey: preferencesKey),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.validationError == nil else {
            return Self()
        }
        return value
    }

    func save(to preferences: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { preferences.set(data, forKey: Self.preferencesKey) }
    }
}

protocol GlobalHotKeyRegistration: AnyObject {
    func register() -> OSStatus
    func unregister()
}

@MainActor
final class GlobalShortcutManager {
    typealias Factory = (GlobalShortcutAction, GlobalShortcutBinding) -> any GlobalHotKeyRegistration
    private(set) var configuration: GlobalShortcutConfiguration
    private var registrations: [any GlobalHotKeyRegistration] = []
    private let preferences: UserDefaults
    private let factory: Factory

    init(preferences: UserDefaults = .standard, factory: @escaping Factory) {
        self.preferences = preferences
        self.factory = factory
        configuration = .load(from: preferences)
    }

    @discardableResult
    func register() -> String? {
        unregister()
        for action in GlobalShortcutAction.allCases {
            let registration = factory(action, configuration[action])
            let status = registration.register()
            guard status == noErr else {
                registration.unregister()
                unregister()
                let error = "Could not register \(action.title). The shortcut may be in use by macOS or another app. Choose a different shortcut."
                Logger.warn("\(error) status=\(status)")
                return error
            }
            registrations.append(registration)
        }
        return nil
    }

    func unregister() {
        registrations.forEach { $0.unregister() }
        registrations.removeAll()
    }

    func apply(_ proposed: GlobalShortcutConfiguration) -> String? {
        if let error = proposed.validationError { return error }
        let previous = configuration
        configuration = proposed
        if let error = register() {
            configuration = previous
            if let rollbackError = register() { Logger.error("Shortcut restore failed: \(rollbackError)") }
            return error
        }
        proposed.save(to: preferences)
        return nil
    }
}
