import SwiftUI

struct ModelDownloadView: View {
    @ObservedObject var manager: ModelDownloadManager
    var close: () -> Void

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: manager.ready ? "checkmark.waveform" : "waveform")
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 58, height: 58)
                    .background(Color(nsColor: PaperTheme.ink).opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 7) {
                    Text(manager.ready ? "PA3 is ready" : "Preparing PA3")
                        .font(.system(size: 25, weight: .semibold))
                    Text("Download speech models once. Dictation and narration then work offline.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(manager.models.enumerated()), id: \.element.id) { index, model in
                    HStack(spacing: 12) {
                        Image(systemName: manager.installed.contains(model.id) ? "checkmark.circle.fill" :
                                manager.currentID == model.id ? "arrow.down.circle.fill" : "circle.dashed")
                            .font(.system(size: 20))
                            .foregroundStyle(manager.installed.contains(model.id) ? Color.green :
                                             manager.currentID == model.id ? Color(nsColor: PaperTheme.ink) : Color.secondary.opacity(0.5))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.name).font(.system(size: 13, weight: .medium))
                            Text(model.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(manager.installed.contains(model.id) ? "Ready" : size(model.bytes))
                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(14)
                    if index < manager.models.count - 1 { Divider().padding(.leading, 46) }
                }
            }
            .background(Color(nsColor: PaperTheme.cream), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.07)))

            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(manager.verifying ? "Checking download" : manager.ready ? "All models installed" : "Speech models")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("\(Int(manager.fraction * 100))%")
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                }
                ProgressView(value: manager.fraction)
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Speech model download")
                    .accessibilityValue("\(Int(manager.fraction * 100)) percent")
                if manager.running {
                    Text("\(size(manager.completedBytes + manager.currentBytes)) of \(size(manager.totalBytes))")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
                Text(manager.status)
                    .font(.system(size: 12))
                    .foregroundStyle(manager.error == nil ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if manager.running {
                    Button("Cancel") { manager.cancel() }
                } else if manager.ready {
                    Button("Done", action: close).keyboardShortcut(.defaultAction)
                } else {
                    Button("Close", action: close)
                    Button("Retry") { manager.start() }.keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 500)
        .background(Color(nsColor: PaperTheme.canvas))
        .tint(Color(nsColor: PaperTheme.ink))
    }
}
