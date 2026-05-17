import SwiftUI

struct DictationView: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            transcript
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
            Text("Language: 1 English   2 Russian   3 Hebrew | Current: \(controller.language.name)")
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(controller.dictating ? Color.green.opacity(0.12) : Color.orange.opacity(0.12))
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                FlowLayout(spacing: 0, lineSpacing: 8) {
                    ForEach(renderItems()) { item in
                        if item.isBreak {
                            Color.clear
                                .frame(width: 9000, height: 18)
                        } else {
                            Text(item.displayText)
                                .font(.system(size: 18, design: .monospaced))
                                .padding(.horizontal, item.highlighted ? 3 : 0)
                                .padding(.vertical, item.highlighted ? 2 : 0)
                                .background(item.background)
                                .foregroundStyle(item.foreground)
                                .id(item.id)
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onChange(of: controller.words.count) {
                if let last = renderItems().last?.id {
                    proxy.scrollTo(last, anchor: .bottom)
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

            Spacer()

            Text("Dictation starts on launch. Use Stop/Start to test the audio path.")
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var footer: some View {
        FlowLayout(spacing: 14, lineSpacing: 6) {
            Text(controller.debugMessage)
                .font(.system(size: 14, design: .monospaced).weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(controller.keyBindings(), id: \.self) { binding in
                Text(binding)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var editSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit")
                .font(.system(.headline, design: .monospaced))
            TextField("", text: Binding(
                get: { controller.editText },
                set: { controller.editText = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            Text("enter: apply edit   esc: cancel edit")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 560)
        .overlay(KeyCatcher { event in
            controller.handleKey(event)
        }.frame(width: 0, height: 0))
    }

    private func renderItems() -> [RenderItem] {
        let tokens = controller.tokens()
        var items: [RenderItem] = []
        var previousParagraph: Int?
        for token in tokens {
            if let previousParagraph, previousParagraph != token.paragraph {
                items.append(RenderItem(id: "break-\(token.id)", displayText: "", isBreak: true, selected: false, pending: false))
            }
            let needsSpace = !items.isEmpty && !token.text.isEmpty && hasAlphanumeric(token.text) && items.last?.isBreak == false
            items.append(RenderItem(id: "word-\(token.id)", displayText: (needsSpace ? " " : "") + token.text, isBreak: false, selected: token.selected, pending: token.pending))
            previousParagraph = token.paragraph
        }
        if items.isEmpty {
            items.append(RenderItem(id: "empty", displayText: "", isBreak: false, selected: false, pending: false))
        }
        return items
    }
}

private struct RenderItem: Identifiable {
    let id: String
    let displayText: String
    let isBreak: Bool
    let selected: Bool
    let pending: Bool

    var highlighted: Bool { selected || pending }
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
