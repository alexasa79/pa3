import AppKit
import SwiftUI

// Use the property wrapper without requiring the newer SwiftUIMacros plugin.
private typealias LegacyState<Value> = SwiftUI.State<Value>

struct DictationView: View {
    @ObservedObject var controller: DictationController
    @LegacyState private var showingShortcuts = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            mainContent
            Divider()
            footer
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
        .sheet(isPresented: Binding(
            get: { controller.vocabularyEditorPresented },
            set: { presented in
                if !presented {
                    controller.cancelVocabularyEditor()
                }
            }
        )) {
            dictionarySheet
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
            helpTab
            if showingShortcuts {
                shortcutsOverlay
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    private var helpTab: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                showingShortcuts.toggle()
            }
        } label: {
            Image(systemName: "keyboard")
                .font(.system(size: 10, weight: .semibold))
                .rotationEffect(.degrees(270))
                .scaleEffect(x: 1.0, y: 1.85, anchor: .center)
                .frame(width: 12, height: 74)
        }
        .buttonStyle(.plain)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
        )
        .help("Show keyboard shortcuts")
        .padding(.trailing, 4)
        .opacity(showingShortcuts ? 0 : 1)
    }

    private var transcript: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    FlowLayout(spacing: 0, lineSpacing: 2) {
                        ForEach(renderItems()) { item in
                            if item.isBreak {
                                Color.clear
                                    .frame(width: 9000, height: 10)
                            } else if item.selected && !controller.dictating && item.hasTrailingSpace && !item.selectionContinues {
                                HStack(spacing: 0) {
                                    Text(item.textWithoutTrailingSpace)
                                        .font(.system(size: 16, design: .monospaced))
                                        .padding(.horizontal, 2)
                                        .frame(height: 21, alignment: .center)
                                        .background(item.background)
                                        .background(
                                            GeometryReader { proxy in
                                                Color.clear.preference(
                                                    key: WordFramePreferenceKey.self,
                                                    value: item.wordIndex.map { [$0: proxy.frame(in: .named("transcript"))] } ?? [:]
                                                )
                                            }
                                        )
                                        .foregroundStyle(item.foreground)
                                    Text(" ")
                                        .font(.system(size: 16, design: .monospaced))
                                        .frame(height: 21, alignment: .center)
                                }
                                .id(item.id)
                            } else {
                                Text(item.displayText)
                                    .font(.system(size: 16, design: .monospaced))
                                    .padding(.horizontal, 2)
                                    .frame(height: 21, alignment: .center)
                                    .background(item.background)
                                    .background(
                                        GeometryReader { proxy in
                                            Color.clear.preference(
                                                key: WordFramePreferenceKey.self,
                                                value: item.wordIndex.map { [$0: proxy.frame(in: .named("transcript"))] } ?? [:]
                                            )
                                        }
                                    )
                                    .foregroundStyle(item.foreground)
                                    .id(item.id)
                            }
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .onAppear {
                    controller.setTranscriptLayoutWidth(geometry.size.width)
                }
                .onChange(of: geometry.size.width) {
                    controller.setTranscriptLayoutWidth(geometry.size.width)
                }
                .onChange(of: controller.words.count) {
                    if let last = renderItems().last?.id {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
                .onPreferenceChange(WordFramePreferenceKey.self) { frames in
                    controller.setWordFrames(frames)
                }
            }
        }
        .coordinateSpace(name: "transcript")
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
                        showingShortcuts = false
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

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(shortcutRows(), id: \.key) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(row.key)
                                .font(.system(size: 13, design: .monospaced).weight(.semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 62, alignment: .leading)
                            Text(row.description)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.88)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 280)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .leading) {
            Divider()
        }
        .shadow(color: Color.black.opacity(0.18), radius: 12, x: -3, y: 0)
        .onHover { hovering in
            if !hovering {
                withAnimation(.easeInOut(duration: 0.16)) {
                    showingShortcuts = false
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                controller.startDictation()
            } label: {
                Label("Start", systemImage: "record.circle")
            }
            .disabled(controller.dictating)

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

            Text("Dictation starts on launch. Use Stop/Start to test the audio path.")
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.secondary)
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

    private var footer: some View {
        HStack(spacing: 18) {
            Text("Language")
                .font(.system(size: 14, design: .monospaced).weight(.semibold))
                .foregroundStyle(.secondary)
            Text("1 English")
                .font(.system(size: 14, design: .monospaced))
            Text("2 Russian")
                .font(.system(size: 14, design: .monospaced))
            Text("3 Hebrew")
                .font(.system(size: 14, design: .monospaced))
            Spacer()
            Text("Current: \(controller.language.name)")
                .font(.system(size: 14, design: .monospaced).weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color(nsColor: .windowBackgroundColor))
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

    private var dictionarySheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Dictionary")
                    .font(.system(.headline, design: .monospaced))
                Spacer()
                Text("\(dictionaryWordCount()) words")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: Binding(
                get: { controller.vocabularyEditText },
                set: { controller.vocabularyEditText = $0 }
            ))
            .font(.system(size: 14, design: .monospaced))
            .frame(minHeight: 300)
            .border(Color.secondary.opacity(0.25))

            HStack {
                Text("One word or phrase per line.")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    controller.cancelVocabularyEditor()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    controller.saveVocabularyEditor()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 560)
    }

    private func renderItems() -> [RenderItem] {
        let tokens = controller.tokens()
        var items: [RenderItem] = []
        var previousParagraph: Int?
        for token in tokens {
            if let previousParagraph, previousParagraph != token.paragraph {
                items.append(RenderItem(id: "break-\(token.id)", displayText: "", isBreak: true, selected: false, pending: false, selectionContinues: false, wordIndex: nil))
            }
            let nextToken = token.id + 1 < tokens.count ? tokens[token.id + 1] : nil
            let needsTrailingSpace = nextToken.map {
                $0.paragraph == token.paragraph && hasAlphanumeric($0.text)
            } ?? false
            let selectionContinues = nextToken.map {
                token.selected && $0.selected && $0.paragraph == token.paragraph
            } ?? false
            items.append(RenderItem(id: "word-\(token.id)", displayText: token.text + (needsTrailingSpace ? " " : ""), isBreak: false, selected: token.selected, pending: token.pending, selectionContinues: selectionContinues, wordIndex: token.id))
            previousParagraph = token.paragraph
        }
        if items.isEmpty {
            items.append(RenderItem(id: "empty", displayText: "", isBreak: false, selected: false, pending: false, selectionContinues: false, wordIndex: nil))
        }
        return items
    }

    private func shortcutRows() -> [ShortcutRow] {
        controller.keyBindings().map { binding in
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

    private func dictionaryWordCount() -> Int {
        controller.vocabularyEditText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count
    }
}

private struct ShortcutRow {
    let key: String
    let description: String
}

private struct RenderItem: Identifiable {
    let id: String
    let displayText: String
    let isBreak: Bool
    let selected: Bool
    let pending: Bool
    let selectionContinues: Bool
    let wordIndex: Int?

    var highlighted: Bool { selected || pending }
    var hasTrailingSpace: Bool { displayText.hasSuffix(" ") }
    var textWithoutTrailingSpace: String {
        hasTrailingSpace ? String(displayText.dropLast()) : displayText
    }
    var background: Color {
        if selected { return Color.yellow.opacity(0.8) }
        if pending { return Color.gray.opacity(0.25) }
        return Color.clear
    }
    var foreground: Color {
        if selected { return Color.black }
        return Color.primary
    }
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

private struct WordFramePreferenceKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 800
        let rows = rows(width: width, subviews: subviews)
        let height = rows.reduce(CGFloat.zero) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let size = item.size
                item.subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if size.width > width {
                if !current.items.isEmpty {
                    rows.append(current)
                    current = Row()
                }
                rows.append(Row(items: [(subview, CGSize(width: width, height: size.height))], height: size.height))
                continue
            }
            if !current.items.isEmpty && current.width + spacing + size.width > width {
                rows.append(current)
                current = Row()
            }
            current.items.append((subview, size))
            current.width += (current.items.count > 1 ? spacing : 0) + size.width
            current.height = max(current.height, size.height)
        }
        if !current.items.isEmpty {
            rows.append(current)
        }
        return rows
    }

    private struct Row {
        var items: [(subview: LayoutSubview, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }
}
