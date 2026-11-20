import Foundation

/// Fuzzy word-sequence search over tasks within a project.
/// Ranking order:
/// 1. Exact phrase match (word-boundary subject > substring subject > body)
/// 2. All query words matched in order
/// 3. All query words matched out of order
/// 4. Partial query word matches (more matched words ranked higher)
/// Tasks with zero matching words are filtered out.
enum TaskSearch {
    private struct Token {
        let text: String
        let inSubject: Bool
        let startOffset: Int
    }

    private struct RankedTask {
        let task: PersonalTask
        let tier: Int
        let matchedWords: Int
        let subjectMatches: Int
        let qualityScore: Int
        let spanPenalty: Int
        let originalIndex: Int
    }

    static func filter(_ tasks: [PersonalTask], query: String) -> [PersonalTask] {
        let normalizedQuery = normalizePhrase(query)
        let queryWords = normalizedQuery.split(separator: " ").map(String.init)
        guard !queryWords.isEmpty else { return tasks }

        var ranked: [RankedTask] = []
        ranked.reserveCapacity(tasks.count)

        for (index, task) in tasks.enumerated() {
            guard let entry = evaluate(task: task, normalizedQuery: normalizedQuery, queryWords: queryWords, originalIndex: index) else {
                continue
            }
            ranked.append(entry)
        }

        ranked.sort { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier > rhs.tier }
            if lhs.matchedWords != rhs.matchedWords { return lhs.matchedWords > rhs.matchedWords }
            if lhs.subjectMatches != rhs.subjectMatches { return lhs.subjectMatches > rhs.subjectMatches }
            if lhs.qualityScore != rhs.qualityScore { return lhs.qualityScore > rhs.qualityScore }
            if lhs.spanPenalty != rhs.spanPenalty { return lhs.spanPenalty < rhs.spanPenalty }
            return lhs.originalIndex < rhs.originalIndex
        }
        return ranked.map(\.task)
    }

    private static func evaluate(task: PersonalTask, normalizedQuery: String, queryWords: [String], originalIndex: Int) -> RankedTask? {
        let normalizedSubject = normalizePhrase(task.body.components(separatedBy: .newlines).first ?? "")
        let normalizedBody = normalizePhrase(task.body)
        let tokens = tokenize(subjectLength: normalizedSubject.count, body: normalizedBody)

        let perWordMatches: [[(position: Int, inSubject: Bool, quality: Int)]] = queryWords.map { word in
            matchPositions(for: word, in: tokens, subjectLength: normalizedSubject.count, normalizedBody: normalizedBody)
        }

        let matchedCount = perWordMatches.filter { !$0.isEmpty }.count
        let exactSubjectBoundary = containsWholeWordPhrase(normalizedSubject, phrase: normalizedQuery)
        let exactSubjectSubstring = exactSubjectBoundary || normalizedSubject.contains(normalizedQuery)
        let exactBodyBoundary = containsWholeWordPhrase(normalizedBody, phrase: normalizedQuery)
        let exactBodySubstring = exactBodyBoundary || normalizedBody.contains(normalizedQuery)

        guard matchedCount > 0 || exactSubjectSubstring || exactBodySubstring else { return nil }

        let orderedMatch = bestOrderedMatch(perWordMatches)
        let allMatched = matchedCount == queryWords.count

        let tier: Int
        if exactSubjectBoundary {
            tier = 6
        } else if exactSubjectSubstring {
            tier = 5
        } else if exactBodySubstring {
            tier = 4
        } else if orderedMatch != nil {
            tier = 3
        } else if allMatched {
            tier = 2
        } else {
            tier = 1
        }

        let effectiveMatchedWords = (tier >= 4) ? queryWords.count : matchedCount
        var subjectMatches = 0
        var qualityScore = 0
        var spanPenalty = Int.max

        if let ordered = orderedMatch {
            subjectMatches = ordered.subjectMatches
            qualityScore = ordered.qualityScore
            spanPenalty = ordered.span
        } else {
            var minIndex = Int.max
            var maxIndex = -1
            for candidates in perWordMatches {
                guard let best = candidates.max(by: { lhs, rhs in
                    if lhs.inSubject != rhs.inSubject { return !lhs.inSubject && rhs.inSubject }
                    if lhs.quality != rhs.quality { return lhs.quality < rhs.quality }
                    return lhs.position > rhs.position
                }) else { continue }
                if best.inSubject { subjectMatches += 1 }
                qualityScore += best.quality
                minIndex = min(minIndex, best.position)
                maxIndex = max(maxIndex, best.position)
            }
            if maxIndex >= minIndex { spanPenalty = maxIndex - minIndex }
        }

        if exactSubjectBoundary {
            qualityScore += normalizedSubject == normalizedQuery ? 200 : (normalizedSubject.hasPrefix(normalizedQuery) ? 120 : 60)
        } else if exactSubjectSubstring {
            qualityScore += normalizedSubject.hasPrefix(normalizedQuery) ? 80 : 30
        } else if exactBodyBoundary {
            qualityScore += 40
        }

        return RankedTask(
            task: task,
            tier: tier,
            matchedWords: effectiveMatchedWords,
            subjectMatches: subjectMatches,
            qualityScore: qualityScore,
            spanPenalty: spanPenalty,
            originalIndex: originalIndex
        )
    }

    /// Finds the best strictly increasing position chain for all query words in order.
    private static func bestOrderedMatch(
        _ perWordMatches: [[(position: Int, inSubject: Bool, quality: Int)]]
    ) -> (subjectMatches: Int, qualityScore: Int, span: Int)? {
        guard !perWordMatches.isEmpty, perWordMatches.allSatisfy({ !$0.isEmpty }) else { return nil }
        if perWordMatches.count == 1 {
            guard let best = perWordMatches[0].max(by: { lhs, rhs in
                if lhs.inSubject != rhs.inSubject { return !lhs.inSubject && rhs.inSubject }
                if lhs.quality != rhs.quality { return lhs.quality < rhs.quality }
                return lhs.position > rhs.position
            }) else { return nil }
            return (best.inSubject ? 1 : 0, best.quality, 0)
        }

        // Dynamic programming over query words for best strictly increasing chain.
        struct State {
            let startPosition: Int
            let endPosition: Int
            let subjectMatches: Int
            let qualityScore: Int
        }

        var current: [State] = perWordMatches[0].map {
            State(startPosition: $0.position, endPosition: $0.position, subjectMatches: $0.inSubject ? 1 : 0, qualityScore: $0.quality)
        }

        for wordIndex in 1..<perWordMatches.count {
            let candidates = perWordMatches[wordIndex]
            var next: [State] = []
            for candidate in candidates {
                var bestPrev: State?
                for prev in current where prev.endPosition < candidate.position {
                    let candidateSpan = candidate.position - prev.startPosition
                    if let existing = bestPrev {
                        let existingSpan = candidate.position - existing.startPosition
                        if prev.subjectMatches != existing.subjectMatches {
                            if prev.subjectMatches > existing.subjectMatches { bestPrev = prev }
                        } else if prev.qualityScore != existing.qualityScore {
                            if prev.qualityScore > existing.qualityScore { bestPrev = prev }
                        } else if candidateSpan < existingSpan {
                            bestPrev = prev
                        }
                    } else {
                        bestPrev = prev
                    }
                }
                if let prev = bestPrev {
                    next.append(State(
                        startPosition: prev.startPosition,
                        endPosition: candidate.position,
                        subjectMatches: prev.subjectMatches + (candidate.inSubject ? 1 : 0),
                        qualityScore: prev.qualityScore + candidate.quality
                    ))
                }
            }
            guard !next.isEmpty else { return nil }
            current = next
        }

        guard let best = current.max(by: { lhs, rhs in
            if lhs.subjectMatches != rhs.subjectMatches { return lhs.subjectMatches < rhs.subjectMatches }
            if lhs.qualityScore != rhs.qualityScore { return lhs.qualityScore < rhs.qualityScore }
            return (lhs.endPosition - lhs.startPosition) > (rhs.endPosition - rhs.startPosition)
        }) else { return nil }

        return (best.subjectMatches, best.qualityScore, best.endPosition - best.startPosition)
    }

    private static func matchPositions(
        for queryWord: String,
        in tokens: [Token],
        subjectLength: Int,
        normalizedBody: String
    ) -> [(position: Int, inSubject: Bool, quality: Int)] {
        let isPlainWord = queryWord.allSatisfy { $0.isLetter || $0.isNumber }
        var results: [(position: Int, inSubject: Bool, quality: Int)] = []

        if !isPlainWord {
            // Handle tags or punctuation-bearing IDs like #waiting, #due:2026, JIRA-412.
            var searchStart = normalizedBody.startIndex
            while let range = normalizedBody.range(of: queryWord, range: searchStart..<normalizedBody.endIndex) {
                let offset = normalizedBody.distance(from: normalizedBody.startIndex, to: range.lowerBound)
                results.append((offset, offset < subjectLength, 100))
                searchStart = normalizedBody.index(after: range.lowerBound)
            }
            return results
        }

        for token in tokens {
            if let quality = wordQuality(query: queryWord, token: token.text) {
                results.append((token.startOffset, token.inSubject, quality))
            }
        }
        return results
    }

    private static func wordQuality(query: String, token: String) -> Int? {
        if token == query { return 100 }
        if token.hasPrefix(query) { return 80 }
        if query.count >= 2, token.contains(query) { return 60 }
        if isFuzzySubsequence(query: query, token: token) { return 40 }
        if isSingleTypo(query: query, token: token) { return 30 }
        return nil
    }

    private static func isFuzzySubsequence(query: String, token: String) -> Bool {
        guard query.count >= 2, query.count < token.count, query.first == token.first else { return false }
        guard token.count - query.count <= 4 || query.count * 3 >= token.count else { return false }
        var qi = query.startIndex
        for ch in token {
            if ch == query[qi] {
                qi = query.index(after: qi)
                if qi == query.endIndex { return true }
            }
        }
        return false
    }

    private static func isSingleTypo(query: String, token: String) -> Bool {
        let a = Array(query)
        let b = Array(token)
        guard a.count >= 4, b.count >= 4, abs(a.count - b.count) <= 1 else { return false }

        // Adjacent transposition (e.g. "kithcen" -> "kitchen", "taks" -> "task").
        if a.count == b.count {
            var diffs: [Int] = []
            for i in 0..<a.count where a[i] != b[i] {
                diffs.append(i)
                if diffs.count > 2 { return false }
            }
            if diffs.count == 2, diffs[1] == diffs[0] + 1, a[diffs[0]] == b[diffs[1]], a[diffs[1]] == b[diffs[0]] {
                return true
            }
            // Single substitution only for words of length >= 5 to avoid short-word noise.
            return diffs.count == 1 && a.count >= 5
        }

        // Single insertion or deletion for words of length >= 5.
        guard min(a.count, b.count) >= 5 else { return false }
        let shorter = a.count < b.count ? a : b
        let longer = a.count < b.count ? b : a
        var i = 0, j = 0, skipped = 0
        while i < shorter.count, j < longer.count {
            if shorter[i] == longer[j] {
                i += 1; j += 1
            } else {
                skipped += 1
                if skipped > 1 { return false }
                j += 1
            }
        }
        return true
    }

    private static func normalizePhrase(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        var result = ""
        result.reserveCapacity(folded.count)
        var lastWasSpace = true
        for ch in folded {
            if ch.isWhitespace {
                if !lastWasSpace {
                    result.append(" ")
                    lastWasSpace = true
                }
            } else {
                result.append(ch)
                lastWasSpace = false
            }
        }
        if result.last == " " { result.removeLast() }
        return result
    }

    private static func tokenize(subjectLength: Int, body: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var tokenStart = 0
        var offset = 0

        for ch in body {
            if ch.isLetter || ch.isNumber {
                if current.isEmpty { tokenStart = offset }
                current.append(ch)
            } else if !current.isEmpty {
                tokens.append(Token(text: current, inSubject: tokenStart < subjectLength, startOffset: tokenStart))
                current.removeAll(keepingCapacity: true)
            }
            offset += 1
        }
        if !current.isEmpty {
            tokens.append(Token(text: current, inSubject: tokenStart < subjectLength, startOffset: tokenStart))
        }
        return tokens
    }

    private static func containsWholeWordPhrase(_ text: String, phrase: String) -> Bool {
        guard !phrase.isEmpty else { return false }
        var searchStart = text.startIndex
        while let range = text.range(of: phrase, range: searchStart..<text.endIndex) {
            let leftOK = range.lowerBound == text.startIndex || !isWordChar(text[text.index(before: range.lowerBound)])
            let rightOK = range.upperBound == text.endIndex || !isWordChar(text[range.upperBound])
            if leftOK && rightOK { return true }
            searchStart = text.index(after: range.lowerBound)
        }
        return false
    }

    private static func isWordChar(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber
    }
}
