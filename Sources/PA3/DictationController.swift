import AppKit
import Foundation
import SwiftUI

enum EditAction {
    case replace
    case replaceAll
    case insertBefore
    case insertAfter
}

struct TranscriptToken: Identifiable {
    let id: Int
    let text: String
    let paragraph: Int
    let selected: Bool
    let pending: Bool
}

@MainActor
final class DictationController: ObservableObject {
    @Published var text = ""
    @Published private(set) var detectedLanguage: String?
    @Published var status = ""
    @Published var dictating = false
    @Published var spellChecking = false
    @Published var words: [String] = []
    @Published var wordParagraphs: [Int] = []
    @Published var selectedWord = -1
    @Published var selectionStart = -1
    @Published var selectionEnd = -1
    @Published var pendingWordStart = -1
    @Published var editMode = false
    @Published var editText = ""
    @Published var lastReplace = ""
    @Published var lastReplaceSet = false
    @Published var lastUpdate: Date?
    @Published var debugMessage = "Ready"
    @Published var serviceMessage = ""
    @Published var vocabularyWords: [String] = []
    @Published var vocabularyEditText = ""
    @Published var vocabularyEditorPresented = false
    @Published var vocabularyNotice = ""
    /// Audio duration limit in seconds. Stored separately from the old sentence preference.
    @Published private(set) var contextSeconds = Int(SegmentationConfig.default.maxBuffer)
    static let contextSecondsKey = "contextSeconds"
    static let contextSecondsRange = SegmentationConfig.contextSecondsRange

    var onPasteAndHide: ((String) -> Void)?
    var onHide: (() -> Void)?
    var onQuit: (() -> Void)?
    var onDictationWillStart: (() -> Void)?
    var prepareModels: (() -> Bool)?
    var narrationIsBlocked: Bool { dictating || runningStop || muter.isActive || transcriber.captureIsBusy }

    private let transcriber: TranscriberService
    private let vocabulary: Vocabulary
    private var committed = ""
    private var segment = ""
    private var selectionAnchor = -1
    private var editAction: EditAction = .replace
    private var editSelectAll = false
    private var runningStop = false
    private var transcriptColumnLimit = 100
    private var wordFrames: [Int: CGRect] = [:]
    private struct ReplacementSource {
        let words: [String]
        let paragraphs: [Int]
    }
    private var lastReplaceSource: ReplacementSource?

    private struct EditSnapshot {
        let text: String
        let selectedWord: Int
        let selectionStart: Int
        let selectionEnd: Int
        let selectionAnchor: Int
        let lastReplace: String
        let lastReplaceSet: Bool
        let lastReplaceSource: ReplacementSource?
    }
    private var undoHistory: [(before: EditSnapshot, after: String)] = []

    /// Mutes output while dictating (and re-asserts across the Bluetooth profile switch the
    /// microphone triggers). We mute rather than lower the volume because a Bluetooth headset's
    /// volume control has no audible effect while its mic is open, but its mute control does.
    private let muter = OutputMuter()

    private func duckOutput() {
        muter.start()
    }

    private func restoreOutput() {
        muter.stop()
    }

    init(transcriber: TranscriberService) {
        self.transcriber = transcriber
        self.vocabulary = Vocabulary(path: Self.vocabularyPath())
        self.vocabularyWords = vocabulary.allWords()
        transcriber.setSystemPrompt(vocabulary.systemPrompt())
        if UserDefaults.standard.object(forKey: Self.contextSecondsKey) != nil {
            contextSeconds = Self.contextSecondsRange.clamped(UserDefaults.standard.integer(forKey: Self.contextSecondsKey))
        }
        transcriber.setContextSeconds(contextSeconds)
        transcriber.setStatusHandler { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                self.serviceMessage = message
                self.debugMessage = message
                self.updateStatusFor(self.combineText())
            }
        }
        updateDisplay()
    }

    private static func vocabularyPath() -> URL {
        let path = userDataDirectory().appendingPathComponent("vocabulary.txt")
        let oldPath = appResourceDirectory().appendingPathComponent("vocabulary.txt")
        if !FileManager.default.fileExists(atPath: path.path),
           FileManager.default.fileExists(atPath: oldPath.path) {
            try? FileManager.default.copyItem(at: oldPath, to: path)
        }
        return path
    }

    func beginNewSession() {
        detectedLanguage = nil
        undoHistory.removeAll()
        committed = ""
        segment = ""
        text = ""
        words = []
        wordParagraphs = []
        clearSelection()
        pendingWordStart = -1
        lastUpdate = nil
        editMode = false
        editText = ""
        serviceMessage = ""
        debugMessage = "Ready"
        updateDisplay()
    }

    func shutdown() {
        stopDictation()
        restoreOutput()
        transcriber.close()
    }

    func pasteAndHide() {
        stopDictation()
        restoreOutput()
        onPasteAndHide?(text)
    }

    func discardAndHide() {
        stopDictation()
        restoreOutput()
        onHide?()
    }

    func handleKey(_ event: KeyEvent) {
        if editMode {
            handleEditKey(event)
            return
        }

        switch (event.key, event.characters) {
        case (.enter, _):
            pasteAndHide()
        case (.escape, _):
            discardAndHide()
        case (.space, _):
            toggleDictation()
        case (.left, _):
            if !dictating { moveSelectionHorizontal(-1, extend: event.shift) }
        case (.right, _):
            if !dictating { moveSelectionHorizontal(1, extend: event.shift) }
        case (.up, _):
            if !dictating { moveSelectionVertical(-1, extend: event.shift) }
        case (.down, _):
            if !dictating { moveSelectionVertical(1, extend: event.shift) }
        case (.backspace, _), (.delete, _):
            break
        case (.home, _), (.end, _):
            break
        case (.character, let chars):
            handleCharacter(chars)
        }
    }

    private func handleCharacter(_ chars: String) {
        guard let ch = chars.first else { return }
        switch ch {
        case "\u{3}":
            discardAndHide()
        case " ":
            toggleDictation()
        case "v":
            insertClipboardParagraph()
        case "s":
            startTranscriptSpellCheck()
        case "R":
            restartDictation()
        case "q", "Q":
            discardAndHide()
        case "o", "O":
            startNewParagraph()
        case "J":
            if !dictating { joinNextParagraph() }
        case "S":
            if !dictating { splitCurrentParagraph() }
        case ".":
            if !dictating { applyLastReplace() }
        case ">":
            if !dictating { applyLastReplaceToAll() }
        case "c":
            if !dictating { startEditMode(.replace) }
        case "C":
            if !dictating { startEditMode(.replaceAll) }
        case "a":
            if !dictating { startEditMode(.insertAfter) }
        case "t":
            if !dictating { cycleCurrentWordCapitalization() }
        case "u":
            if !dictating { undoLastEdit() }
        case "A":
            addSelectedWordToVocabulary()
        case "D":
            openVocabularyEditor()
        case "i", "I":
            if !dictating { startEditMode(.insertBefore) }
        case "x", "X":
            if !dictating { deleteSelection() }
        default:
            break
        }
    }

    func keyBindings() -> [String] {
        if editMode {
            return ["enter: apply edit", "esc: cancel edit", "arrows: move cursor", "home/end: jump", "alt+backspace: delete word", "backspace: delete char", "delete: delete ahead"]
        }
        if dictating {
            return ["space: pause dictation", "enter: paste result", "v: insert clipboard", "s: spell check transcript", "R: restart dictation", "q: discard", "ctrl+c: abort", "o: new paragraph", "D: edit dictionary"]
        }
        var bindings = ["space: resume dictation", "enter: paste result", "v: insert clipboard", "s: spell check transcript", "R: restart dictation", "q: discard", "ctrl+c: abort", "o: new paragraph", "D: edit dictionary", "J: join paragraph", "S: split paragraph", "arrows: navigate", "shift+arrows: expand selection"]
        if lastReplaceSet && hasSelection() {
            bindings.append(".: repeat change")
        }
        if lastReplaceSet && lastReplaceSource != nil && !words.isEmpty {
            bindings.append(">: repeat change on all matches")
        }
        if undoHistory.last?.after == text {
            bindings.append("u: undo last change")
        }
        if hasSelection() {
            bindings += ["c: edit selection", "C: change all", "t: cycle capitalization", "a: append after", "i: insert before", "x: delete selection", "A: add vocab"]
        }
        return bindings
    }

    func applyCurrentEdit() {
        if editAction == .replaceAll {
            commitEditModeReplaceAll()
        } else {
            commitEditMode()
        }
    }

    func cancelCurrentEdit() {
        cancelEditMode()
    }

    func openVocabularyEditor() {
        vocabularyEditText = vocabularyWords.joined(separator: "\n")
        vocabularyEditorPresented = true
    }

    func saveVocabularyEditor() {
        vocabularyWords = vocabulary.replace(with: vocabularyEditText)
        transcriber.setSystemPrompt(vocabulary.systemPrompt())
        vocabularyEditText = vocabularyWords.joined(separator: "\n")
        vocabularyEditorPresented = false
        showVocabularyNotice("\(vocabularyWords.count) dictionary words saved")
    }

    func cancelVocabularyEditor() {
        vocabularyEditText = ""
        vocabularyEditorPresented = false
    }

    func setTranscriptLayoutWidth(_ width: CGFloat) {
        let contentWidth = max(0, width - 36)
        let estimatedMonospaceCharacterWidth = 9.65
        transcriptColumnLimit = max(20, Int(contentWidth / estimatedMonospaceCharacterWidth))
    }

    func setWordFrames(_ frames: [Int: CGRect]) {
        wordFrames = frames
    }

    func tokens() -> [TranscriptToken] {
        words.enumerated().map { index, word in
            TranscriptToken(
                id: index,
                text: word,
                paragraph: index < wordParagraphs.count ? wordParagraphs[index] : 0,
                selected: selectionStart >= 0 && selectionEnd >= selectionStart && index >= selectionStart && index <= selectionEnd,
                pending: pendingWordStart >= 0 && index >= pendingWordStart
            )
        }
    }

    private func hasSelection() -> Bool {
        !dictating && !words.isEmpty && selectionStart >= 0 && selectionEnd >= selectionStart && selectionEnd < words.count
    }

    private func combineText() -> String {
        let c = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !c.isEmpty && !s.isEmpty { return c + "\n\n" + s }
        if !c.isEmpty { return c }
        return s
    }

    private func updateDisplay() {
        let combined = combineText()
        let split = splitWordsAndParagraphs(combined)
        let filtered = filterBlankAudioWords(words: split.0, paragraphs: split.1)
        var normalized = combined.replacingOccurrences(of: blankAudioToken, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !filtered.0.isEmpty {
            normalized = buildTextFromWordData(words: filtered.0, paragraphs: filtered.1)
        }

        text = normalized
        words = split.0
        wordParagraphs = split.1
        pendingWordStart = -1

        if dictating, !segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let stableRunes = max(0, transcriber.stablePrefixRunes())
            let committedWords = splitWords(committed.trimmingCharacters(in: .whitespacesAndNewlines))
            let segmentWords = splitWords(segment.trimmingCharacters(in: .whitespacesAndNewlines))
            if !segmentWords.isEmpty {
                let segmentPending = wordIndexForRunes(words: segmentWords, stableRunes: stableRunes)
                if segmentPending < segmentWords.count {
                    pendingWordStart = committedWords.count + segmentPending
                }
            }
        }

        if words.isEmpty || dictating {
            clearSelection()
        } else {
            let maxIdx = words.count - 1
            if selectedWord < 0 {
                setSelection(maxIdx)
            } else {
                selectedWord = min(selectedWord, maxIdx)
                if selectionStart < 0 || selectionStart > maxIdx { selectionStart = selectedWord }
                if selectionEnd < selectionStart { selectionEnd = selectionStart }
                if selectionEnd > maxIdx { selectionEnd = maxIdx }
                if selectionAnchor < 0 || selectionAnchor > maxIdx { selectionAnchor = selectedWord }
            }
        }
        lastUpdate = Date()
        updateStatusFor(combined)
    }

    private func updateStatusFor(_ value: String) {
        var label = dictating ? "DICTATING" : "PAUSED"
        if dictating, !serviceMessage.isEmpty {
            label = serviceMessage
        }
        if spellChecking {
            label = "SPELL CHECKING"
        }
        let count = value.count
        status = count > 0 ? "\(label) | \(count) chars" : label
    }

    func handleTranscription(_ update: TranscriptionUpdate) {
        detectedLanguage = update.language
        serviceMessage = ""
        debugMessage = "Dictation active"
        segment = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        updateDisplay()
    }

    func adjustContextSeconds(by delta: Int) {
        let value = Self.contextSecondsRange.clamped(contextSeconds + delta)
        guard value != contextSeconds else { return }
        contextSeconds = value
        UserDefaults.standard.set(value, forKey: Self.contextSecondsKey)
        transcriber.setContextSeconds(value)
        Logger.info("contextSeconds=\(value)")
    }

    func startDictation() {
        Logger.info("startDictation requested")
        if dictating { return }
        guard prepareModels?() ?? true else {
            serviceMessage = "Downloading speech models. Start dictation when the download finishes."
            debugMessage = serviceMessage
            return
        }
        undoHistory.removeAll()
        onDictationWillStart?()
        if editMode { cancelEditMode() }
        segment = ""
        dictating = true
        duckOutput()
        serviceMessage = ""
        debugMessage = "Starting microphone..."
        clearSelection()
        transcriber.startTranscribeUpdates { [weak self] value in
            Task { @MainActor in self?.handleTranscription(value) }
        }
        updateDisplay()
        debugMessage = "Dictation active"
    }

    func stopDictation() {
        Logger.info("stopDictation requested")
        if !dictating { return }
        runningStop = true
        dictating = false
        restoreOutput()
        serviceMessage = ""
        debugMessage = "Stopping dictation..."
        let transcriber = transcriber
        DispatchQueue.global(qos: .userInitiated).async {
            transcriber.stopTranscribe()
            DispatchQueue.main.async {
                self.runningStop = false
                self.commitSegment()
                self.updateDisplay()
                self.debugMessage = "Dictation stopped"
            }
        }
    }

    private func toggleDictation() {
        dictating ? stopDictation() : startDictation()
    }

    func restartDictation() {
        undoHistory.removeAll()
        let wasDictating = dictating
        if wasDictating {
            dictating = false
            serviceMessage = ""
            debugMessage = "Restarting dictation..."
        }
        committed = ""
        segment = ""
        clearSelection()
        updateDisplay()
        guard wasDictating else {
            startDictation()
            return
        }
        let transcriber = transcriber
        DispatchQueue.global(qos: .userInitiated).async {
            transcriber.stopTranscribe()
            DispatchQueue.main.async {
                self.startDictation()
            }
        }
    }

    private func startNewParagraph() {
        if dictating {
            dictating = false
            serviceMessage = ""
            debugMessage = "Starting new paragraph..."
            commitSegment()
            updateDisplay()
            let transcriber = transcriber
            DispatchQueue.global(qos: .userInitiated).async {
                transcriber.stopTranscribe()
                DispatchQueue.main.async {
                    self.startDictation()
                }
            }
            return
        }
        startDictation()
    }

    private func insertClipboardParagraph() {
        let before = editSnapshot()
        defer { recordEdit(before) }
        let pasteboard = NSPasteboard.general
        let normalized = joinParagraphWords(splitWords(pasteboard.string(forType: .string) ?? ""))
        if normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        let wasDictating = dictating
        if wasDictating {
            dictating = false
            serviceMessage = ""
            debugMessage = "Inserting clipboard..."
        }
        commitSegment()
        let trimmedCommitted = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        committed = trimmedCommitted.isEmpty ? normalized : trimmedCommitted + "\n\n" + normalized
        segment = ""
        updateDisplay()
        guard wasDictating else {
            return
        }
        let transcriber = transcriber
        DispatchQueue.global(qos: .userInitiated).async {
            transcriber.stopTranscribe()
            DispatchQueue.main.async {
                self.startDictation()
            }
        }
    }

    private func startTranscriptSpellCheck() {
        if spellChecking { return }
        let wasDictating = dictating
        if wasDictating {
            dictating = false
            restoreOutput()
            serviceMessage = ""
            debugMessage = "Preparing spell check..."
        }
        commitSegment()
        let input = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty { return }
        spellChecking = true
        updateStatusFor(input)
        let transcriber = transcriber
        DispatchQueue.global(qos: .userInitiated).async {
            if wasDictating {
                transcriber.stopTranscribe()
            }
            let result = Result { try OllamaClient().spellCheckTranscript(input) }
            DispatchQueue.main.async {
                self.spellChecking = false
                switch result {
                case .success(let output):
                    if self.committed.trimmingCharacters(in: .whitespacesAndNewlines) == input {
                        let before = self.editSnapshot()
                        defer { self.recordEdit(before) }
                        self.committed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.segment = ""
                        self.updateDisplay()
                    }
                case .failure(let error):
                    Logger.warn("transcript spell check failed: \(error)")
                    self.updateStatusFor(self.combineText())
                }
            }
        }
    }

    private func addSelectedWordToVocabulary() {
        guard selectedWord >= 0, selectedWord < words.count else { return }
        let word = words[selectedWord].trimmingCharacters(in: .whitespacesAndNewlines)
        if word.isEmpty || word.caseInsensitiveCompare(blankAudioToken) == .orderedSame {
            return
        }
        let result = vocabulary.add(word)
        if result.added {
            vocabularyWords = vocabulary.allWords()
            transcriber.setSystemPrompt(vocabulary.systemPrompt())
            showVocabularyNotice("Added \"\(result.normalized)\"")
        } else if !result.normalized.isEmpty {
            debugMessage = "\"\(result.normalized)\" is already in dictionary"
        }
    }

    private func showVocabularyNotice(_ message: String) {
        vocabularyNotice = message
        debugMessage = message
        let expected = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if self.vocabularyNotice == expected {
                self.vocabularyNotice = ""
            }
        }
    }

    private func commitSegment() {
        let seg = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        if seg.isEmpty {
            segment = ""
            return
        }
        let c = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        committed = c.isEmpty ? seg : c + "\n\n" + seg
        segment = ""
    }

    private func clearSelection() {
        selectedWord = -1
        selectionStart = -1
        selectionEnd = -1
        selectionAnchor = -1
    }

    private func setSelection(_ idx: Int) {
        if words.isEmpty {
            clearSelection()
            return
        }
        let clamped = max(0, min(idx, words.count - 1))
        selectedWord = clamped
        selectionStart = clamped
        selectionEnd = clamped
        selectionAnchor = clamped
    }

    private func moveSelectionHorizontal(_ direction: Int, extend: Bool) {
        let paragraph = words.indices.filter { wordParagraphs.indices.contains($0) &&
            wordParagraphs.indices.contains(selectedWord) && wordParagraphs[$0] == wordParagraphs[selectedWord] }
            .map { words[$0] }.joined(separator: " ")
        let rtl = TranscriptLayout.writingDirection(for: paragraph, language: detectedLanguage) == .rightToLeft
        if let current = wordFrames[selectedWord] {
            let candidates = wordFrames.filter { index, frame in
                words.indices.contains(index) && abs(frame.midY - current.midY) < 4 &&
                    (direction < 0 ? frame.midX < current.midX : frame.midX > current.midX)
            }
            if let next = candidates.min(by: { abs($0.value.midX - current.midX) < abs($1.value.midX - current.midX) })?.key {
                moveSelection(next - selectedWord, extend: extend)
                return
            }
            let down = rtl ? direction < 0 : direction > 0
            let otherRows = wordFrames.filter { index, frame in
                words.indices.contains(index) && (down ? frame.midY > current.midY + 4 : frame.midY < current.midY - 4)
            }
            if let distance = otherRows.values.map({ abs($0.midY - current.midY) }).min() {
                let row = otherRows.filter { abs(abs($0.value.midY - current.midY) - distance) < 4 }
                if let next = row.min(by: { direction < 0 ? $0.value.midX > $1.value.midX : $0.value.midX < $1.value.midX })?.key {
                    moveSelection(next - selectedWord, extend: extend)
                }
            }
            return
        }
        moveSelection(rtl ? -direction : direction, extend: extend)
    }

    private func moveSelection(_ delta: Int, extend: Bool) {
        if words.isEmpty {
            clearSelection()
            return
        }
        if selectedWord < 0 {
            setSelection(delta >= 0 ? 0 : words.count - 1)
            return
        }
        if !extend {
            setSelection(max(0, min(words.count - 1, selectedWord + delta)))
            return
        }
        if selectionAnchor < 0 { selectionAnchor = selectedWord }
        let next = max(0, min(words.count - 1, selectedWord + delta))
        selectedWord = next
        selectionStart = min(next, selectionAnchor)
        selectionEnd = max(next, selectionAnchor)
    }

    private func moveSelectionVertical(_ direction: Int, extend: Bool) {
        if moveSelectionUsingRenderedFrames(direction: direction, extend: extend) {
            return
        }
        let columns = layoutColumns(maxWidth: transcriptColumnLimit)
        guard selectedWord >= 0, selectedWord < columns.count else {
            setSelection(direction > 0 ? 0 : words.count - 1)
            return
        }
        let current = columns[selectedWord]
        var best: Int?
        var bestDistance = Int.max
        for (idx, candidate) in columns.enumerated() where direction < 0 ? candidate.line < current.line : candidate.line > current.line {
            let lineDistance = abs(candidate.line - current.line)
            let colDistance = abs(candidate.column - current.column)
            let score = lineDistance * 10_000 + colDistance
            if score < bestDistance {
                bestDistance = score
                best = idx
            }
        }
        if let best {
            if extend {
                if selectionAnchor < 0 { selectionAnchor = selectedWord }
                selectedWord = best
                selectionStart = min(best, selectionAnchor)
                selectionEnd = max(best, selectionAnchor)
            } else {
                setSelection(best)
            }
        }
    }

    private func moveSelectionUsingRenderedFrames(direction: Int, extend: Bool) -> Bool {
        guard selectedWord >= 0,
              let current = wordFrames[selectedWord],
              !wordFrames.isEmpty else {
            return false
        }
        let verticalTolerance: CGFloat = 4
        let candidates = wordFrames.filter { index, frame in
            index >= 0 && index < words.count &&
                (direction < 0 ? frame.midY < current.midY - verticalTolerance : frame.midY > current.midY + verticalTolerance)
        }
        guard !candidates.isEmpty else {
            return false
        }

        let nearestYDistance = candidates.values
            .map { abs($0.midY - current.midY) }
            .min() ?? 0
        let sameVisualRowTolerance: CGFloat = 6
        let nearestRow = candidates.filter { _, frame in
            abs(abs(frame.midY - current.midY) - nearestYDistance) <= sameVisualRowTolerance
        }

        let currentX = current.midX
        let best = nearestRow.min { lhs, rhs in
            let leftDistance = abs(lhs.value.midX - currentX)
            let rightDistance = abs(rhs.value.midX - currentX)
            if leftDistance == rightDistance {
                return lhs.key < rhs.key
            }
            return leftDistance < rightDistance
        }
        guard let best else {
            return false
        }
        if extend {
            if selectionAnchor < 0 { selectionAnchor = selectedWord }
            selectedWord = best.key
            selectionStart = min(best.key, selectionAnchor)
            selectionEnd = max(best.key, selectionAnchor)
        } else {
            setSelection(best.key)
        }
        return true
    }

    private func layoutColumns(maxWidth: Int) -> [(line: Int, column: Int)] {
        var result = Array(repeating: (line: 0, column: 0), count: words.count)
        var line = 0
        var column = 0
        for (index, word) in words.enumerated() {
            if index > 0, index < wordParagraphs.count, wordParagraphs[index] != wordParagraphs[index - 1] {
                line += 2
                column = 0
            }
            let needsSpace = column > 0 && hasAlphanumeric(word)
            let width = word.count + (needsSpace ? 1 : 0)
            if column > 0 && column + width > maxWidth {
                line += 1
                column = 0
            }
            if column > 0 && needsSpace {
                column += 1
            }
            result[index] = (line, column)
            column += word.count
        }
        return result
    }

    private func cycleCurrentWordCapitalization() {
        let before = editSnapshot()
        defer { recordEdit(before) }
        guard words.indices.contains(selectedWord) else { return }
        let replacement = nextWordCapitalization(words[selectedWord])
        guard replacement != words[selectedWord] else { return }
        words[selectedWord] = replacement
        committed = buildTextFromWordData(words: words, paragraphs: wordParagraphs)
        segment = ""
        updateDisplay()
    }

    private func editSnapshot() -> EditSnapshot {
        EditSnapshot(text: text, selectedWord: selectedWord, selectionStart: selectionStart,
                     selectionEnd: selectionEnd, selectionAnchor: selectionAnchor,
                     lastReplace: lastReplace, lastReplaceSet: lastReplaceSet,
                     lastReplaceSource: lastReplaceSource)
    }

    private func recordEdit(_ before: EditSnapshot) {
        guard before.text != text, !dictating, !runningStop else { return }
        undoHistory.append((before, text))
        if undoHistory.count > 100 { undoHistory.removeFirst() }
        objectWillChange.send()
    }

    private func undoLastEdit() {
        guard !runningStop, let undo = undoHistory.last else { return }
        guard text == undo.after else {
            undoHistory.removeAll()
            return
        }
        undoHistory.removeLast()
        committed = undo.before.text
        segment = ""
        selectedWord = undo.before.selectedWord
        selectionStart = undo.before.selectionStart
        selectionEnd = undo.before.selectionEnd
        selectionAnchor = undo.before.selectionAnchor
        lastReplace = undo.before.lastReplace
        lastReplaceSet = undo.before.lastReplaceSet
        lastReplaceSource = undo.before.lastReplaceSource
        updateDisplay()
    }

    private func deleteSelection() {
        let before = editSnapshot()
        defer { recordEdit(before) }
        if words.isEmpty {
            clearSelection()
            committed = ""
            segment = ""
            updateDisplay()
            return
        }
        let start = validSelectionStart()
        let end = validSelectionEnd(start)
        var newWords = Array(words[..<start])
        if end + 1 < words.count {
            newWords += words[(end + 1)...]
        }
        var newParagraphs: [Int] = []
        if wordParagraphs.count == words.count {
            newParagraphs = Array(wordParagraphs[..<start])
            if end + 1 < wordParagraphs.count {
                newParagraphs += wordParagraphs[(end + 1)...]
            }
        } else {
            newParagraphs = Array(repeating: 0, count: newWords.count)
        }
        let cleaned = cleanupDeletion(words: newWords, paragraphs: newParagraphs, at: start,
                                      deletedParagraph: wordParagraphs.count == words.count ? wordParagraphs[end] : 0)
        words = cleaned.words
        wordParagraphs = cleaned.paragraphs
        committed = buildTextFromWordData(words: words, paragraphs: wordParagraphs)
        segment = ""
        if words.isEmpty {
            clearSelection()
        } else {
            setSelection(min(start, words.count - 1))
        }
        updateDisplay()
    }

    private func startEditMode(_ action: EditAction) {
        if editMode || dictating { return }
        if words.isEmpty, action == .replace || action == .replaceAll { return }
        if words.isEmpty {
            selectionStart = 0
            selectionEnd = -1
        } else if selectionStart < 0 || selectionStart >= words.count {
            setSelection(max(0, min(selectedWord, words.count - 1)))
        }
        editAction = action
        if action == .replace || action == .replaceAll {
            let start = validSelectionStart()
            let end = validSelectionEnd(start)
            editText = words[start...end].joined(separator: " ")
            editSelectAll = true
        } else {
            editText = ""
            editSelectAll = false
        }
        editMode = true
    }

    private func cancelEditMode() {
        editMode = false
        editText = ""
        editSelectAll = false
        editAction = .replace
    }

    private func handleEditKey(_ event: KeyEvent) {
        switch event.key {
        case .enter:
            if editAction == .replaceAll {
                commitEditModeReplaceAll()
            } else {
                commitEditMode()
            }
        case .escape:
            cancelEditMode()
        case .backspace:
            if event.option {
                editText = editText.trimmingCharacters(in: .whitespaces)
                if let idx = editText.lastIndex(where: { $0.isWhitespace }) {
                    editText = String(editText[..<idx]).trimmingCharacters(in: .whitespaces)
                } else {
                    editText = ""
                }
            } else if !editText.isEmpty {
                editText.removeLast()
            }
        case .delete:
            break
        case .character:
            if let first = event.characters.first, first.isNewline == false, first.unicodeScalars.first?.value ?? 0 >= 32 {
                if editSelectAll {
                    editText = ""
                    editSelectAll = false
                }
                editText.append(first)
            }
        default:
            break
        }
    }

    private func commitEditMode() {
        let replacementWords = splitWords(editText.trimmingCharacters(in: .whitespacesAndNewlines))
        let oldCount = words.count
        switch editAction {
        case .insertBefore, .insertAfter:
            let before = editSnapshot()
            defer { recordEdit(before) }
            if replacementWords.isEmpty {
                cancelEditMode()
                return
            }
            let insertPos: Int
            if oldCount == 0 {
                insertPos = 0
            } else if editAction == .insertBefore {
                insertPos = max(0, min(selectionStart, oldCount))
            } else {
                insertPos = max(0, min(selectionEnd + 1, oldCount))
            }
            let para = paragraphForInsert(insertPos, action: editAction)
            words = Array(words[..<insertPos]) + replacementWords + Array(words[insertPos...])
            wordParagraphs = normalizeParagraphs(Array(wordParagraphs.prefix(insertPos)) + Array(repeating: para, count: replacementWords.count) + Array(wordParagraphs.dropFirst(insertPos)))
            committed = buildTextFromWordData(words: words, paragraphs: wordParagraphs)
            segment = ""
            cancelEditMode()
            selectionStart = insertPos
            selectionEnd = insertPos + replacementWords.count - 1
            selectionAnchor = selectionStart
            selectedWord = selectionEnd
            updateDisplay()
        case .replace:
            replaceSelection(with: replacementWords, remember: true)
        case .replaceAll:
            commitEditModeReplaceAll()
        }
    }

    private func commitEditModeReplaceAll() {
        let before = editSnapshot()
        defer { recordEdit(before) }
        guard !words.isEmpty else {
            cancelEditMode()
            return
        }
        let start = validSelectionStart()
        let end = validSelectionEnd(start)
        let pattern = words[start...end].joined(separator: " ")
        let replacement = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        rememberReplacement(from: start...end, replacement: splitWords(replacement))
        committed = committed.replacingOccurrences(of: pattern, with: replacement)
        segment = ""
        let split = splitWordsAndParagraphs(committed)
        words = split.0
        wordParagraphs = split.1
        cancelEditMode()
        clearSelection()
        updateDisplay()
    }

    private func replaceSelection(with replacementWords: [String], remember: Bool) {
        let before = editSnapshot()
        defer { recordEdit(before) }
        guard !words.isEmpty else {
            cancelEditMode()
            return
        }
        let start = validSelectionStart()
        let end = validSelectionEnd(start)
        if remember {
            rememberReplacement(from: start...end, replacement: replacementWords)
        }
        let para = paragraphForReplacement(start)
        words = Array(words[..<start]) + replacementWords + (end + 1 < words.count ? Array(words[(end + 1)...]) : [])
        wordParagraphs = normalizeParagraphs(Array(wordParagraphs.prefix(start)) + Array(repeating: para, count: replacementWords.count) + (end + 1 < wordParagraphs.count ? Array(wordParagraphs[(end + 1)...]) : []))
        committed = buildTextFromWordData(words: words, paragraphs: wordParagraphs)
        segment = ""
        cancelEditMode()
        if replacementWords.isEmpty {
            if words.isEmpty { clearSelection() } else { setSelection(min(start, words.count - 1)) }
        } else {
            selectionStart = min(start, words.count - 1)
            selectionEnd = min(selectionStart + replacementWords.count - 1, words.count - 1)
            selectedWord = selectionEnd
            selectionAnchor = selectionStart
        }
        updateDisplay()
    }

    private func applyLastReplace() {
        if dictating || !lastReplaceSet { return }
        replaceSelection(with: splitWords(lastReplace), remember: false)
    }

    private func rememberReplacement(from range: ClosedRange<Int>, replacement: [String]) {
        lastReplaceSource = ReplacementSource(
            words: Array(words[range]),
            paragraphs: normalizeParagraphs(Array(wordParagraphs[range])))
        lastReplace = joinParagraphWords(replacement)
        lastReplaceSet = true
    }

    private func applyLastReplaceToAll() {
        guard !dictating, lastReplaceSet, let source = lastReplaceSource,
              !source.words.isEmpty, wordParagraphs.count == words.count else { return }
        let before = editSnapshot()
        defer { recordEdit(before) }
        let replacement = splitWords(lastReplace)
        var matches: [Range<Int>] = []
        var index = 0
        // Find non-overlapping whole-token matches in the original transcript.
        // Inserted replacement text is never searched again during this edit.
        while index + source.words.count <= words.count {
            let range = index..<(index + source.words.count)
            if Array(words[range]) == source.words &&
                normalizeParagraphs(Array(wordParagraphs[range])) == source.paragraphs {
                matches.append(range)
                index = range.upperBound
            } else {
                index += 1
            }
        }
        guard !matches.isEmpty else { return }
        for range in matches.reversed() {
            let paragraph = wordParagraphs[range.lowerBound]
            words.replaceSubrange(range, with: replacement)
            wordParagraphs.replaceSubrange(range, with: Array(repeating: paragraph, count: replacement.count))
            func adjusted(_ index: Int) -> Int {
                if index >= range.upperBound { return index + replacement.count - range.count }
                if index >= range.lowerBound {
                    return range.lowerBound + min(index - range.lowerBound, max(0, replacement.count - 1))
                }
                return index
            }
            selectedWord = adjusted(selectedWord)
            selectionStart = adjusted(selectionStart)
            selectionEnd = adjusted(selectionEnd)
            selectionAnchor = adjusted(selectionAnchor)
        }
        wordParagraphs = normalizeParagraphs(wordParagraphs)
        committed = buildTextFromWordData(words: words, paragraphs: wordParagraphs)
        segment = ""
        updateDisplay()
    }

    private func joinNextParagraph() {
        let before = editSnapshot()
        defer { recordEdit(before) }
        guard !words.isEmpty, wordParagraphs.count == words.count else { return }
        let idx = max(0, min(selectedWord, words.count - 1))
        let current = wordParagraphs[idx]
        let next = current + 1
        if !wordParagraphs.contains(next) { return }
        for i in wordParagraphs.indices {
            if wordParagraphs[i] == next { wordParagraphs[i] = current }
            else if wordParagraphs[i] > next { wordParagraphs[i] -= 1 }
        }
        wordParagraphs = normalizeParagraphs(wordParagraphs)
        committed = buildTextFromWordData(words: words, paragraphs: wordParagraphs)
        updateDisplay()
        setSelection(min(idx, words.count - 1))
    }

    private func splitCurrentParagraph() {
        let before = editSnapshot()
        defer { recordEdit(before) }
        guard !words.isEmpty, wordParagraphs.count == words.count else { return }
        let idx = max(0, min(selectedWord, words.count - 1))
        let current = wordParagraphs[idx]
        var hasTail = false
        for i in (idx + 1)..<wordParagraphs.count {
            if wordParagraphs[i] == current {
                hasTail = true
                break
            }
            if wordParagraphs[i] > current { break }
        }
        if !hasTail { return }
        for i in wordParagraphs.indices {
            if wordParagraphs[i] == current && i > idx { wordParagraphs[i] = current + 1 }
            else if wordParagraphs[i] > current { wordParagraphs[i] += 1 }
        }
        wordParagraphs = normalizeParagraphs(wordParagraphs)
        committed = buildTextFromWordData(words: words, paragraphs: wordParagraphs)
        updateDisplay()
        setSelection(idx)
    }

    private func validSelectionStart() -> Int {
        if selectionStart >= 0, selectionStart < words.count {
            return selectionStart
        }
        return max(0, min(selectedWord, max(0, words.count - 1)))
    }

    private func validSelectionEnd(_ start: Int) -> Int {
        if selectionEnd >= start, selectionEnd < words.count {
            return selectionEnd
        }
        return start
    }

    private func paragraphForInsert(_ insertPos: Int, action: EditAction) -> Int {
        if wordParagraphs.isEmpty { return 0 }
        if action == .insertBefore {
            return insertPos < wordParagraphs.count ? wordParagraphs[insertPos] : wordParagraphs.last ?? 0
        }
        if insertPos <= 0 { return wordParagraphs[0] }
        return wordParagraphs[min(insertPos - 1, wordParagraphs.count - 1)]
    }

    private func paragraphForReplacement(_ start: Int) -> Int {
        if wordParagraphs.isEmpty { return 0 }
        return wordParagraphs[min(start, wordParagraphs.count - 1)]
    }
}
