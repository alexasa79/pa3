import AppKit
import SwiftUI

struct DictationView: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            mainContent
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(KeyCatcher { event in
            controller.handleKey(event)
        }.frame(width: 0, height: 0))
        .sheet(isPresented: Binding(
            get: { controller.editMode },
            set: { _ in }
        )) {
            editSheet
        }

    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(controller.dictating ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
            Text("pa dictation")
                .font(.system(.body, design: .monospaced).weight(.semibold))
            Text(controller.status)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Text(controller.debugMessage)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.secondary)
            if !controller.vocabularyNotice.isEmpty {
                Text(controller.vocabularyNotice)
                    .font(.system(size: 13, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Color.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(controller.dictating ? Color.green.opacity(0.12) : Color.orange.opacity(0.12))
    }

    private var mainContent: some View {
        ZStack(alignment: .trailing) {
            transcript
            if controller.showingShortcuts {
                shortcutsOverlay
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    private var transcript: some View {
        TranscriptTextView(tokens: controller.tokens(), language: controller.detectedLanguage,
                           dictating: controller.dictating, selectedWord: controller.selectedWord,
                           onKey: controller.handleKey, onFrames: controller.setWordFrames)
    }

    private var shortcutsOverlay: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Shortcuts")
                    .font(.system(size: 13, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        controller.toggleShortcuts()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Hide keyboard shortcuts")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Text("Dictation is paused. Close with ? or Esc to return; dictation resumes if it was active. Scroll for the full reference.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(controller.shortcutSections(), id: \.title) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title)
                                .font(.system(size: 13, weight: .semibold))
                            ForEach(shortcutRows(section.bindings), id: \.key) { row in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(row.key)
                                        .font(.system(size: 13, design: .monospaced).weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .frame(width: 112, alignment: .leading)
                                    Text(row.description)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.visible)
        }
        .frame(width: 380)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 12, x: -3, y: 0)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    controller.toggleShortcuts()
                }
            } label: {
                Label("Shortcuts", systemImage: "keyboard")
            }
            .help(controller.showingShortcuts ? "Hide keyboard shortcuts" : "Show keyboard shortcuts")
            .accessibilityValue(controller.showingShortcuts ? "Shown" : "Hidden")

            Button {
                controller.startDictation()
            } label: {
                Label("Start", systemImage: "record.circle")
            }
            .disabled(!controller.canStartDictation)

            Button {
                controller.stopDictation()
            } label: {
                Label("Stop", systemImage: "stop.circle")
            }
            .disabled(!controller.dictating)

            Button {
                controller.pasteAndHide()
            } label: {
                Label("Paste", systemImage: "arrowshape.turn.up.right")
            }

            Button {
                controller.discardAndHide()
            } label: {
                Label("Hide", systemImage: "eye.slash")
            }

            Button {
                controller.openVocabularyEditor()
            } label: {
                Label("Dictionary", systemImage: "book.closed")
            }

            contextControl

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Duration limit for the audio clip sent to Whisper.
    private var contextControl: some View {
        HStack(spacing: 4) {
            Text("Context")
                .foregroundStyle(.secondary)
            Button {
                controller.adjustContextSeconds(by: -1)
            } label: {
                Image(systemName: "minus")
            }
            .disabled(controller.contextSeconds <= DictationController.contextSecondsRange.lowerBound)
            Text("\(controller.contextSeconds)s")
                .font(.system(size: 14, design: .monospaced))
                .frame(minWidth: 36)
            Button {
                controller.adjustContextSeconds(by: 1)
            } label: {
                Image(systemName: "plus")
            }
            .disabled(controller.contextSeconds >= DictationController.contextSecondsRange.upperBound)
        }
        .help("Maximum audio context in seconds. When exceeded, trim at the earliest suitable sentence boundary and retain the rest.")
    }

    private var editSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit")
                .font(.system(.headline, design: .monospaced))
            EditTextField(text: Binding(
                get: { controller.editText },
                set: { controller.editText = $0 }
            ), onSubmit: {
                controller.applyCurrentEdit()
            }, onCancel: {
                controller.cancelCurrentEdit()
            })
            .frame(height: 30)
            Text("enter: apply edit   esc: cancel edit")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 560)
    }

    private func shortcutRows(_ bindings: [String]) -> [ShortcutRow] {
        bindings.map { binding in
            let parts = binding.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                return ShortcutRow(key: binding, description: "")
            }
            return ShortcutRow(
                key: parts[0].trimmingCharacters(in: .whitespaces),
                description: parts[1].trimmingCharacters(in: .whitespaces)
            )
        }
    }


}

private struct ShortcutRow {
    let key: String
    let description: String
}

private struct EditTextField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @MainActor func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onCancel: onCancel)
    }

    @MainActor func makeNSView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator
        field.onSubmit = onSubmit
        field.onCancel = onCancel
        field.stringValue = text
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byTruncatingHead
        return field
    }

    @MainActor func updateNSView(_ field: Field, context: Context) {
        context.coordinator.text = $text
        field.onSubmit = onSubmit
        field.onCancel = onCancel
        if field.stringValue != text {
            field.stringValue = text
            field.currentEditor()?.scrollRangeToVisible(NSRange(location: field.stringValue.utf16.count, length: 0))
        }
        guard !context.coordinator.didFocus else {
            return
        }
        context.coordinator.didFocus = true
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.selectText(nil)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        let onSubmit: () -> Void
        let onCancel: () -> Void
        var didFocus = false

        init(text: Binding<String>, onSubmit: @escaping () -> Void, onCancel: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
            self.onCancel = onCancel
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else {
                return
            }
            text.wrappedValue = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                text.wrappedValue = textView.string
                onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                onCancel()
                return true
            default:
                return false
            }
        }
    }

    final class Field: NSTextField {
        var onSubmit: (() -> Void)?
        var onCancel: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 36, 76:
                onSubmit?()
            case 53:
                onCancel?()
            default:
                super.keyDown(with: event)
            }
        }
    }
}
