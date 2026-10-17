import AppKit

@MainActor
final class ShortcutSettingsWindowController: NSWindowController, NSWindowDelegate {
    private let shortcuts: GlobalShortcutManager
    private let onSave: () -> Void
    private var draft: GlobalShortcutConfiguration
    private var buttons: [GlobalShortcutAction: NSButton] = [:]
    private let message = NSTextField(wrappingLabelWithString: "")
    private var recording: GlobalShortcutAction?

    init(shortcuts: GlobalShortcutManager, error: String? = nil, onSave: @escaping () -> Void) {
        self.shortcuts = shortcuts
        self.onSave = onSave
        draft = shortcuts.configuration
        let window = ShortcutRecordingWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 330),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "PA3 Keyboard shortcuts"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self
        window.onKey = { [weak self] event in self?.capture(event) ?? false }
        buildContent(in: window)
        message.stringValue = error ?? ""
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildContent(in window: NSWindow) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
        ])

        let instructions = NSTextField(wrappingLabelWithString:
            "Click a shortcut, then press a key with Control, Option, or Command. Press Escape to cancel recording. Changes apply after saving.")
        instructions.textColor = .secondaryLabelColor
        stack.addArrangedSubview(instructions)
        instructions.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        for action in GlobalShortcutAction.allCases {
            let label = NSTextField(labelWithString: action.title)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let button = NSButton(title: draft[action].display, target: self, action: #selector(recordShortcut(_:)))
            button.bezelStyle = .rounded
            button.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
            button.tag = action.rawValue
            button.setAccessibilityLabel(action.title + " shortcut")
            button.toolTip = "Click to record a keyboard shortcut"
            buttons[action] = button
            let row = NSStackView(views: [label, button])
            row.spacing = 16
            row.alignment = .centerY
            row.distribution = .fill
            stack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: stack.widthAnchor),
                button.widthAnchor.constraint(equalToConstant: 190)
            ])
        }

        message.textColor = .systemRed
        message.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(message)
        message.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        message.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true

        let defaults = NSButton(title: "Restore defaults", target: self, action: #selector(restoreDefaults))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        for button in [defaults, cancel, save] { button.bezelStyle = .rounded }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [defaults, spacer, cancel, save])
        footer.spacing = 8
        stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    @objc private func recordShortcut(_ sender: NSButton) {
        guard let action = GlobalShortcutAction(rawValue: sender.tag) else { return }
        if recording == action { stopRecording(); return }
        stopRecording()
        recording = action
        shortcuts.unregister()
        sender.title = "Press shortcut…"
        sender.setAccessibilityValue("Recording")
        message.stringValue = ""
    }

    // The window intercepts key equivalents too, so Command combinations and
    // the currently registered global shortcuts can be recorded normally.
    @discardableResult
    func capture(_ event: NSEvent) -> Bool {
        guard let action = recording else { return false }
        if event.keyCode == 53 { stopRecording(); return true }
        if event.isARepeat { return true }
        let binding = GlobalShortcutBinding(event: event)
        guard binding.isValid else {
            message.stringValue = "Include Control, Option, or Command with the key."
            return true
        }
        draft[action] = binding
        stopRecording()
        message.stringValue = draft.validationError ?? ""
        return true
    }

    private func stopRecording() {
        guard recording != nil else { return }
        recording = nil
        refreshButtons()
        if let error = shortcuts.register() { message.stringValue = error }
    }

    private func refreshButtons() {
        for action in GlobalShortcutAction.allCases {
            buttons[action]?.title = draft[action].display
            buttons[action]?.setAccessibilityValue(draft[action].display)
        }
    }

    @objc private func restoreDefaults() {
        stopRecording()
        draft = GlobalShortcutConfiguration()
        refreshButtons()
        message.stringValue = ""
    }

    @objc private func cancel() { close() }

    @objc private func save() {
        stopRecording()
        if let error = shortcuts.apply(draft) {
            message.stringValue = error
            return
        }
        onSave()
        close()
    }

    func windowWillClose(_ notification: Notification) { stopRecording() }
    func windowDidResignKey(_ notification: Notification) { stopRecording() }
}

@MainActor
private final class ShortcutRecordingWindow: NSWindow {
    var onKey: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }
}
