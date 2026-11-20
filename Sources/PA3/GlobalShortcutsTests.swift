import AppKit
import Carbon

@MainActor
func runGlobalShortcutsTests() -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ name: String) {
        if !condition { failures.append("global shortcuts: " + name) }
    }
    let suite = "PA3-shortcut-tests-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let defaults = GlobalShortcutConfiguration()
    check(.load(from: preferences) == defaults, "first launch uses original bindings")
    check(defaults.dictation.display == "⌃⌥⌘P" && defaults.selection.display == "⌃⌥⌘O"
          && defaults.screen.display == "⌃⌥⌘R" && defaults.tasks.display == "⌃⌥⌘T", "default shortcut labels")

    var proposed = defaults
    proposed.dictation = GlobalShortcutBinding(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey))
    proposed.selection = GlobalShortcutBinding(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey))
    check(proposed.validationError == nil, "same physical key with different modifiers is valid")
    proposed.save(to: preferences)
    check(.load(from: preferences) == proposed, "custom shortcuts survive reload")
    func saveLegacy(_ configuration: GlobalShortcutConfiguration) {
        var object = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as! [String: Any]
        object.removeValue(forKey: "tasks")
        preferences.set(try! JSONSerialization.data(withJSONObject: object), forKey: GlobalShortcutConfiguration.preferencesKey)
    }
    saveLegacy(proposed)
    check(.load(from: preferences) == proposed, "upgrading three saved shortcuts preserves custom bindings and adds Tasks")
    var occupied = proposed
    occupied.screen = defaults.tasks
    saveLegacy(occupied)
    let migrated = GlobalShortcutConfiguration.load(from: preferences)
    check(migrated.dictation == occupied.dictation && migrated.selection == occupied.selection && migrated.screen == occupied.screen
          && migrated.tasks != occupied.screen && migrated.validationError == nil,
          "a legacy T binding is preserved and Tasks receives a free combination")
    var duplicate = proposed
    duplicate.screen = proposed.selection
    check(duplicate.validationError != nil, "duplicate combinations are rejected")
    var duplicateTasks = proposed
    duplicateTasks.tasks = proposed.dictation
    check(duplicateTasks.validationError != nil, "Tasks cannot reuse another action's shortcut")
    duplicate.save(to: preferences)
    check(.load(from: preferences) == defaults, "invalid saved bindings fall back to defaults")
    preferences.set(Data("broken".utf8), forKey: GlobalShortcutConfiguration.preferencesKey)
    check(.load(from: preferences) == defaults, "corrupt preferences fall back to defaults")
    check(!GlobalShortcutBinding(keyCode: 35, modifiers: UInt32(shiftKey)).isValid, "shift alone is rejected")
    check(!GlobalShortcutBinding(keyCode: 55, modifiers: UInt32(cmdKey)).isValid, "modifier-only binding is rejected")
    check(!GlobalShortcutBinding(keyCode: 300, modifiers: UInt32(cmdKey)).isValid, "out-of-range key rejected")
    check(!GlobalShortcutBinding(keyCode: 35, modifiers: UInt32(cmdKey | alphaLock)).isValid, "unsupported saved flags rejected")
    defaults.save(to: preferences)

    let registry = ShortcutTestRegistry()
    let manager = GlobalShortcutManager(preferences: preferences) { action, binding in
        ShortcutTestRegistration(registry: registry, action: action, binding: binding)
    }
    let actionCount = GlobalShortcutAction.allCases.count
    check(actionCount == 4, "four independent shortcut actions")
    check(manager.register() == nil && registry.active.count == actionCount, "all defaults register")
    check(manager.apply(proposed) == nil && registry.active.count == actionCount, "changes register immediately")
    check(manager.configuration == proposed && .load(from: preferences) == proposed, "successful registration persists")
    check(manager.apply(duplicate) != nil && registry.active.count == actionCount, "invalid edits leave bindings registered")
    var unavailable = proposed
    unavailable.tasks = GlobalShortcutBinding(keyCode: UInt32(kVK_ANSI_X), modifiers: UInt32(cmdKey | controlKey))
    registry.unavailable = unavailable.tasks
    check(manager.apply(unavailable) != nil, "registration conflict reports an error")
    check(manager.configuration == proposed && .load(from: preferences) == proposed, "failed changes are not saved")
    check(registry.active == Dictionary(uniqueKeysWithValues: GlobalShortcutAction.allCases.map { ($0, proposed[$0]) }),
          "partial registration failure restores every previous binding")

    let controller = DictationController(transcriber: TranscriberService(), preferences: preferences)
    controller.globalShortcuts = proposed
    check(controller.shortcutSections().last?.bindings.first?.hasPrefix("⌃P:") == true,
          "dictation help shows configured shortcuts")
    check(controller.shortcutSections().last?.bindings.contains("⌃⌥⌘T: open task manager") == true,
          "dictation help includes the task-manager shortcut")

    func event(_ key: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                        windowNumber: 0, context: nil, characters: "p", charactersIgnoringModifiers: "p",
                        isARepeat: false, keyCode: key)!
    }
    func buttons(in view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }
    var saves = 0
    let settings = ShortcutSettingsWindowController(shortcuts: manager) { saves += 1 }
    let controls = buttons(in: settings.window!.contentView!)
    let record = controls.first { $0.tag == GlobalShortcutAction.dictation.rawValue }!
    check(controls.contains { $0.tag == GlobalShortcutAction.tasks.rawValue && $0.title == "⌃⌥⌘T" },
          "settings includes an editable task-manager shortcut")
    record.performClick(nil)
    check(registry.active.isEmpty, "recording suspends existing global shortcuts")
    check(settings.capture(event(35)), "unmodified keys stay inside recorder")
    check(registry.active.isEmpty, "invalid key keeps recording")
    check(settings.capture(event(53)) && registry.active.count == actionCount, "Escape cancels recording and restores shortcuts")
    record.performClick(nil)
    check(settings.capture(event(7, [.command, .option])), "Command combination is captured")
    check(manager.configuration == proposed, "recording edits only the draft")
    controls.first { $0.title == "Save" }!.performClick(nil)
    check(saves == 1 && manager.configuration.dictation == GlobalShortcutBinding(event: event(7, [.command, .option])),
          "Save applies recorded combination")

    let saved = manager.configuration
    let cancelSettings = ShortcutSettingsWindowController(shortcuts: manager) { saves += 1 }
    let cancelControls = buttons(in: cancelSettings.window!.contentView!)
    cancelControls.first { $0.title == "Restore defaults" }!.performClick(nil)
    cancelControls.first { $0.title == "Cancel" }!.performClick(nil)
    check(manager.configuration == saved && saves == 1, "Cancel discards restored defaults")
    let defaultsSettings = ShortcutSettingsWindowController(shortcuts: manager) { saves += 1 }
    let defaultsControls = buttons(in: defaultsSettings.window!.contentView!)
    defaultsControls.first { $0.title == "Restore defaults" }!.performClick(nil)
    defaultsControls.first { $0.title == "Save" }!.performClick(nil)
    check(manager.configuration == defaults && .load(from: preferences) == defaults, "Restore defaults saves original combinations")
    manager.unregister()

    // Exercise the actual Carbon handler with two registrations for the same key.
    var first = 0
    var second = 0
    let firstKey = GlobalHotKey(keyCode: UInt32(kVK_F18), modifiers: UInt32(controlKey | optionKey | cmdKey | shiftKey),
                               identifier: 50001) { first += 1 }
    let secondKey = GlobalHotKey(keyCode: UInt32(kVK_F18), modifiers: UInt32(controlKey | optionKey | cmdKey),
                                identifier: 50002) { second += 1 }
    defer { firstKey.unregister(); secondKey.unregister() }
    check(firstKey.register() == noErr && secondKey.register() == noErr, "Carbon allows same key with different modifiers")
    for id: UInt32 in [50001, 50002] {
        var carbonEvent: EventRef?
        let created = CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &carbonEvent)
        guard created == noErr, let carbonEvent else {
            check(false, "create Carbon shortcut event")
            continue
        }
        var identifier = EventHotKeyID(signature: OSType(0x50413348), id: id)
        SetEventParameter(carbonEvent, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          MemoryLayout<EventHotKeyID>.size, &identifier)
        SendEventToEventTarget(carbonEvent, GetApplicationEventTarget())
        ReleaseEvent(carbonEvent)
    }
    check(first == 1 && second == 1, "same-key combinations dispatch only their own action")
    return failures
}

private final class ShortcutTestRegistry {
    var active: [GlobalShortcutAction: GlobalShortcutBinding] = [:]
    var unavailable: GlobalShortcutBinding?
}

private final class ShortcutTestRegistration: GlobalHotKeyRegistration {
    let registry: ShortcutTestRegistry
    let action: GlobalShortcutAction
    let binding: GlobalShortcutBinding
    var registered = false

    init(registry: ShortcutTestRegistry, action: GlobalShortcutAction, binding: GlobalShortcutBinding) {
        self.registry = registry
        self.action = action
        self.binding = binding
    }
    func register() -> OSStatus {
        if registry.unavailable == binding { return OSStatus(eventHotKeyExistsErr) }
        registry.active[action] = binding
        registered = true
        return noErr
    }
    func unregister() {
        if registered { registry.active.removeValue(forKey: action) }
        registered = false
    }
}
