import AppKit
import Foundation
import SwiftUI

enum TranscriptionLanguage: String {
    case english = "en"
    case russian = "ru"
    case hebrew = "he"

    var tag: String {
        switch self {
        case .english: "[EN]"
        case .russian: "[RU]"
        case .hebrew: "[HE]"
        }
    }

    var name: String {
        switch self {
        case .english: "English"
        case .russian: "Russian"
        case .hebrew: "Hebrew"
        }
    }
}

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
    @Published var status = ""
    @Published var dictating = false
    @Published var muted = false
    @Published var spellChecking = false
    @Published var words: [String] = []
    @Published var wordParagraphs: [Int] = []
    @Published var selectedWord = -1
    @Published var selectionStart = -1
    @Published var selectionEnd = -1
    @Published var pendingWordStart = -1
    @Published var editMode = false
    @Published var editText = ""
    @Published var language: TranscriptionLanguage = .english
    @Published var lastReplace = ""
    @Published var lastReplaceSet = false
    @Published var lastUpdate: Date?
    @Published var debugMessage = "Ready"
    @Published var serviceMessage = ""

    var onPasteAndHide: ((String) -> Void)?
    var onHide: (() -> Void)?
    var onQuit: (() -> Void)?

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

    init(transcriber: TranscriberService) {
        self.transcriber = transcriber
        self.vocabulary = Vocabulary(path: installationDirectory().appendingPathComponent("vocabulary.txt"))
        transcriber.setSystemPrompt(vocabulary.systemPrompt())
        transcriber.setLanguage(language.rawValue)
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

    func beginNewSession() {
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
        transcriber.close()
    }

    func pasteAndHide() {
        stopDictation()
        onPasteAndHide?(text)
    }

    func discardAndHide() {
        stopDictation()
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
            if !dictating { moveSelection(-1, extend: event.shift) }
        case (.right, _):
            if !dictating { moveSelection(1, extend: event.shift) }
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
        case "1":
            setLanguage(.english)
        case "2":
            setLanguage(.russian)
        case "3":
            setLanguage(.hebrew)
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
        case "m", "M":
            SystemHelpers.toggleOutputMute()
            muted.toggle()
            updateStatusFor(combineText())
        case "c":
            if !dictating { startEditMode(.replace) }
        case "C":
            if !dictating { startEditMode(.replaceAll) }
        case "a":
            if !dictating { startEditMode(.insertAfter) }
        case "A":
            addSelectedWordToVocabulary()
        case "i", "I":
            if !dictating { startEditMode(.insertBefore) }
        case "x", "X":
            if !dictating { deleteSelection() }
        default:
            break
        }
    }

    private func setLanguage(_ newLanguage: TranscriptionLanguage) {
        if language == newLanguage {
            return
        }
        language = newLanguage
        transcriber.setLanguage(newLanguage.rawValue)
        updateStatusFor(combineText())
    }

    func keyBindings() -> [String] {
        if editMode {
            return ["enter: apply edit", "esc: cancel edit", "arrows: move cursor", "home/end: jump", "alt+backspace: delete word", "backspace: delete char", "delete: delete ahead"]
        }
        if dictating {
            return ["space: pause dictation", "enter: paste result", "v: insert clipboard", "s: spell check transcript", "R: restart dictation", "q: discard", "ctrl+c: abort", "m: mute output", "o: new paragraph"]
        }
        var bindings = ["space: resume dictation", "enter: paste result", "v: insert clipboard", "s: spell check transcript", "R: restart dictation", "q: discard", "ctrl+c: abort", "m: mute output", "o: new paragraph", "J: join paragraph", "S: split paragraph", "arrows: navigate", "shift+arrows: expand selection"]
        if lastReplaceSet && hasSelection() {
            bindings.append(".: repeat change")
        }
        if hasSelection() {
            bindings += ["c: edit selection", "C: change all", "a: append after", "i: insert before", "x: delete selection", "A: add vocab"]
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
        var label = dictating ? "DICTATING \(language.tag)" : "PAUSED \(language.tag)"
        if dictating, !serviceMessage.isEmpty {
            label = "\(serviceMessage) \(language.tag)"
        }
        if spellChecking {
            label = "SPELL CHECKING"
        }
        if muted {
            label += " muted"
        }
        let count = value.count
        status = count > 0 ? "\(label) | \(count) chars" : label
    }

    private func handleTranscription(_ raw: String) {
        serviceMessage = ""
        debugMessage = "Dictation active"
        segment = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        updateDisplay()
    }

    func startDictation() {
        Logger.info("startDictation requested")
        if dictating { return }
        if editMode { cancelEditMode() }
        segment = ""
        dictating = true
        serviceMessage = ""
        debugMessage = "Starting microphone..."
        clearSelection()
        transcriber.startTranscribe { [weak self] value in
            Task { @MainActor in self?.handleTranscription(value) }
        }
        updateDisplay()
        debugMessage = "Dictation active"
    }

    func stopDictation() {
        Logger.info("stopDictation requested")
        if !dictating { return }
        dictating = false
        serviceMessage = ""
        debugMessage = "Stopping dictation..."
        let transcriber = transcriber
        DispatchQueue.global(qos: .userInitiated).async {
            transcriber.stopTranscribe()
            DispatchQueue.main.async {
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
        stopDictation()
        let input = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty { return }
        spellChecking = true
        updateStatusFor(input)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try OllamaClient().spellCheckTranscript(input) }
            DispatchQueue.main.async {
                self.spellChecking = false
                switch result {
                case .success(let output):
                    if self.committed.trimmingCharacters(in: .whitespacesAndNewlines) == input {
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
            transcriber.setSystemPrompt(vocabulary.systemPrompt())
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

    private func deleteSelection() {
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
        words = newWords
        wordParagraphs = normalizeParagraphs(newParagraphs)
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
        guard !words.isEmpty else {
            cancelEditMode()
            return
        }
        let start = validSelectionStart()
        let end = validSelectionEnd(start)
        let pattern = words[start...end].joined(separator: " ")
        let replacement = editText.trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard !words.isEmpty else {
            cancelEditMode()
            return
        }
        let start = validSelectionStart()
        let end = validSelectionEnd(start)
        if remember {
            lastReplace = joinParagraphWords(replacementWords)
            lastReplaceSet = true
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

    private func joinNextParagraph() {
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
