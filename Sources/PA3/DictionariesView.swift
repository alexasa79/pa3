import Combine
import SwiftUI

struct DictionariesView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var dictionary: NarrationDictionary
    let preview: (NarrationDictionaryEntry) -> String?
    let stopPreview: () -> Void
    @ObservedObject var editor: DictionariesEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Dictionary", selection: $editor.tab) {
                Text("Transcription").tag(0)
                Text("Narration").tag(1)
            }.pickerStyle(.segmented)
            if editor.tab == 0 {
                Text("Words and phrases for Whisper to recognize. One per line.")
                    .foregroundStyle(.secondary)
                TextEditor(text: $editor.transcription)
                    .font(.system(size: 14, design: .monospaced))
                    .border(Color.secondary.opacity(0.25))
            } else {
                Text("Pronunciations shared by PA3 and its Chrome extension. Matches whole words and phrases, ignoring case.")
                    .foregroundStyle(.secondary)
                if let error = dictionary.loadError { Text(error).foregroundStyle(.red) }
                HStack {
                    Text("Written text").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Speak as").frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: 116, height: 1)
                }.font(.headline)
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach($editor.entries) { $entry in
                            HStack {
                                TextField("e.g. SQL", text: $entry.spelling)
                                TextField("e.g. sequel", text: $entry.pronunciation)
                                Button("Preview") {
                                    do {
                                        let validated = try NarrationDictionary.validate([entry])[0]
                                        let error = preview(validated)
                                        editor.failed = error != nil
                                        editor.message = error ?? "Preview started."
                                    } catch { editor.failed = true; editor.message = error.localizedDescription }
                                }
                                Button {
                                    editor.entries.removeAll { $0.id == entry.id }
                                } label: { Image(systemName: "minus.circle") }
                                .help("Remove entry")
                            }.textFieldStyle(.roundedBorder)
                        }
                        if editor.entries.isEmpty { Text("No narration entries yet.").foregroundStyle(.secondary).padding() }
                    }
                }
                HStack {
                    Button("Add entry") { editor.entries.append(NarrationDictionaryEntry(spelling: "", pronunciation: "")) }
                    Button("Stop preview", action: stopPreview)
                }
            }
            HStack {
                Text(editor.message).foregroundStyle(editor.failed ? Color.red : Color.secondary)
                    .font(.callout)
                Spacer()
                Button("Save") {
                    do {
                        if editor.tab == 0 {
                            try controller.replaceVocabulary(with: editor.transcription)
                            editor.transcription = controller.vocabularyWords.joined(separator: "\n")
                        } else {
                            try dictionary.save(editor.entries)
                            editor.entries = dictionary.entries
                        }
                        editor.failed = false
                        editor.message = "Saved."
                    } catch { editor.failed = true; editor.message = error.localizedDescription }
                }.keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 420)
        .background(Color(nsColor: PaperTheme.canvas))
        .tint(Color(nsColor: PaperTheme.ink))
        .onChange(of: editor.tab) { _, _ in editor.message = "" }
    }
}

@MainActor
final class DictionariesEditor: ObservableObject {
    @Published var tab: Int
    @Published var transcription: String
    @Published var entries: [NarrationDictionaryEntry]
    @Published var message = ""
    @Published var failed = false

    init(controller: DictationController, dictionary: NarrationDictionary, tab: Int) {
        self.tab = tab
        transcription = controller.vocabularyWords.joined(separator: "\n")
        entries = dictionary.entries
    }
}
