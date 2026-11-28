import AppKit
import Foundation

@MainActor
func runMarkdownHighlighterTests() -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ name: String) { if !condition { failures.append("markdown: " + name) } }

    func substring(_ text: String, _ range: NSRange) -> String {
        (text as NSString).substring(with: range)
    }

    // 1. Headings, blockquotes, horizontal rules, lists, checkboxes, tables.
    let doc = """
    # Heading One
    ### Heading Three
    > Quoted *note*
    ---
    - Bullet item
    2. [x] Checked item
    | Col A | Col B |
    | --- | :---: |
    | **bold** | `a | b` |
    """
    let docTokens = TaskMarkdownHighlighter.tokens(in: doc, highlightTaskTags: true)
    check(docTokens.contains { $0.kind == .heading(1) && substring(doc, $0.range) == "# Heading One" }, "highlights H1")
    check(docTokens.contains { $0.kind == .heading(3) && substring(doc, $0.range) == "### Heading Three" }, "highlights H3")
    check(docTokens.contains { $0.kind == .blockquote && substring(doc, $0.range) == "> Quoted *note*" }, "highlights blockquote")
    check(!docTokens.contains { $0.kind == .syntaxDelimiter && substring(doc, $0.range).hasPrefix(">") },
          "blockquote > shares style with quoted text like Veda")
    check(docTokens.contains { $0.kind == .italic && substring(doc, $0.range) == "*note*" }, "highlights italic inside blockquote")
    check(docTokens.contains { $0.kind == .horizontalRule && substring(doc, $0.range) == "---" }, "highlights horizontal rule")
    check(docTokens.contains { $0.kind == .listMarker && substring(doc, $0.range) == "-" }, "highlights unordered list marker")
    check(docTokens.contains { $0.kind == .listMarker && substring(doc, $0.range) == "2." }, "highlights ordered list marker")
    check(docTokens.contains { $0.kind == .listMarker && substring(doc, $0.range) == "[x]" }, "highlights task checkbox")
    check(docTokens.contains { $0.kind == .tableBorder && substring(doc, $0.range) == "| --- | :---: |" }, "highlights table separator row")
    check(docTokens.contains { $0.kind == .bold && substring(doc, $0.range) == "**bold**" }, "highlights bold inside table cell")
    check(docTokens.contains { $0.kind == .inlineCode && substring(doc, $0.range) == "`a | b`" }, "highlights inline code with pipe inside table")
    let codeRange = (doc as NSString).range(of: "`a | b`")
    check(!docTokens.contains { $0.kind == .tableBorder && NSIntersectionRange($0.range, codeRange).length > 0 },
          "pipe inside inline code is not treated as table border")

    // 2. Emphasis, strikethrough, flanking rules, adjacent runs, and escapes.
    let inline = "Plain **bold** *italic* ***both*** ~~gone~~ snake_case_var 2 * 3 * 4 \\*literal\\* `_raw_`"
    let inlineTokens = TaskMarkdownHighlighter.tokens(in: inline, highlightTaskTags: true)
    check(inlineTokens.contains { $0.kind == .bold && substring(inline, $0.range) == "**bold**" }, "highlights **bold** including delimiters")
    check(inlineTokens.contains { $0.kind == .italic && substring(inline, $0.range) == "*italic*" }, "highlights *italic* including delimiters")
    check(inlineTokens.contains { $0.kind == .boldItalic && substring(inline, $0.range) == "***both***" }, "highlights ***bold italic*** including delimiters")
    check(inlineTokens.contains { $0.kind == .strikethrough && substring(inline, $0.range) == "~~gone~~" }, "highlights ~~strikethrough~~ including delimiters")
    check(!inlineTokens.contains { $0.kind == .italic && substring(inline, $0.range).contains("case") },
          "intraword snake_case_var is not italic")
    check(!inlineTokens.contains { $0.kind == .italic && substring(inline, $0.range).contains("3") },
          "spaced multiplication 2 * 3 * 4 is not italic")
    check(!inlineTokens.contains { $0.kind == .italic && substring(inline, $0.range).contains("literal") },
          "escaped \\*literal\\* is not italic")
    check(inlineTokens.contains { $0.kind == .inlineCode && substring(inline, $0.range) == "`_raw_`" },
          "inline code preserves underscores")
    check(!inlineTokens.contains { $0.kind == .italic && substring(inline, $0.range).contains("raw") },
          "underscores inside inline code do not trigger italic")

    let adjacent = "2. **[Link](doc-a.md)****[Another](index.md)** - Adjacent"
    let adjTokens = TaskMarkdownHighlighter.tokens(in: adjacent, highlightTaskTags: false)
    check(adjTokens.contains { $0.kind == .bold && substring(adjacent, $0.range) == "**[Link](doc-a.md)**" },
          "splits adjacent **** boundary for first bold link")
    check(adjTokens.contains { $0.kind == .bold && substring(adjacent, $0.range) == "**[Another](index.md)**" },
          "splits adjacent **** boundary for second bold link")

    // 3. Links, multi-line links, images, and bare URLs.
    let links = "See [PA3 Docs](https://example.com/a_b_(c)) and ![Icon](icon.png) or https://example.com/foo_bar."
    let linkTokens = TaskMarkdownHighlighter.tokens(in: links, highlightTaskTags: true)
    check(linkTokens.contains { $0.kind == .linkText && substring(links, $0.range) == "PA3 Docs" }, "highlights link text")
    check(linkTokens.contains { $0.kind == .linkURL && substring(links, $0.range) == "https://example.com/a_b_(c)" },
          "highlights link URL with balanced parens")
    check(linkTokens.contains { $0.kind == .image && substring(links, $0.range) == "Icon" }, "highlights image alt text")
    check(linkTokens.contains { $0.kind == .linkURL && substring(links, $0.range) == "https://example.com/foo_bar" },
          "highlights bare URL without trailing period")
    check(!linkTokens.contains { $0.kind == .italic }, "underscores inside URLs do not trigger italic")

    let multiLine = "3. [Multi\n   line](doc-a.md) - Link with newline"
    let multiTokens = TaskMarkdownHighlighter.tokens(in: multiLine, highlightTaskTags: false)
    check(multiTokens.contains { $0.kind == .linkText && substring(multiLine, $0.range) == "Multi" },
          "highlights first line of multi-line link")
    check(multiTokens.contains { $0.kind == .linkText && substring(multiLine, $0.range) == "line" },
          "highlights second line of multi-line link")
    check(multiTokens.contains { $0.kind == .linkURL && substring(multiLine, $0.range) == "doc-a.md" },
          "highlights URL of multi-line link")

    // 4. Fenced code blocks suppress inner Markdown and tags.
    let fenced = """
    Title
    ```swift
    # Not a heading
    let x = **not bold** // #due:2026-12-01 #done
    ```
    After #due:tomorrow, #pri:1 #done #status:open #due:bad #pri:9 #random
    """
    let fencedTaskTokens = TaskMarkdownHighlighter.tokens(in: fenced, highlightTaskTags: true)
    check(fencedTaskTokens.contains { $0.kind == .codeFence && substring(fenced, $0.range) == "```swift" }, "highlights opening fence")
    check(fencedTaskTokens.contains { $0.kind == .codeBlock && substring(fenced, $0.range) == "# Not a heading" }, "highlights code block line")
    check(!fencedTaskTokens.contains { if case .heading = $0.kind { return true }; return false },
          "headings inside fenced code block are ignored")
    check(!fencedTaskTokens.contains { $0.kind == .bold }, "emphasis inside fenced code block is ignored")
    let tagTexts = fencedTaskTokens.compactMap { token -> String? in
        if case .taskTag = token.kind { return substring(fenced, token.range) }
        return nil
    }
    check(tagTexts == ["#due:tomorrow", "#pri:1", "#done", "#status:open"],
          "highlights only valid task tags outside code blocks (got \(tagTexts))")

    // Notes mode disables task tag highlighting while keeping Markdown highlighting.
    let fencedNoteTokens = TaskMarkdownHighlighter.tokens(in: fenced, highlightTaskTags: false)
    check(!fencedNoteTokens.contains { if case .taskTag = $0.kind { return true }; return false },
          "notes mode does not highlight task tags")
    check(fencedNoteTokens.contains { $0.kind == .codeBlock }, "notes mode still highlights Markdown")

    // Inline code suppresses task tags too.
    let inlineTag = "Keep `#done` literal and highlight #done"
    let inlineTagTokens = TaskMarkdownHighlighter.tokens(in: inlineTag, highlightTaskTags: true)
    let inlineMatchedTags = inlineTagTokens.filter { if case .taskTag = $0.kind { return true }; return false }
    check(inlineMatchedTags.count == 1 && substring(inlineTag, inlineMatchedTags[0].range) == "#done"
          && inlineMatchedTags[0].range.location > 20, "task tags inside inline code are not highlighted")

    // 5. UTF-16 safety with Cyrillic and emoji.
    let unicode = "Назначил 👨‍👩‍👧‍👦 **важно** и `#due:2026-12-01` #pri:0"
    let unicodeTokens = TaskMarkdownHighlighter.tokens(in: unicode, highlightTaskTags: true)
    check(unicodeTokens.contains { $0.kind == .bold && substring(unicode, $0.range) == "**важно**" },
          "Cyrillic + emoji UTF-16 bold range is exact")
    check(unicodeTokens.contains { $0.kind == .taskTag(.priority(0)) && substring(unicode, $0.range) == "#pri:0" },
          "Cyrillic + emoji UTF-16 task tag range is exact")

    // 6. Editor integration: attributes apply & reset cleanly without polluting undo.
    let editor = TaskModalTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 320))
    editor.isRichText = false
    editor.allowsUndo = true
    editor.highlightTaskTags = true
    let initial = "Subject line\nBody with `code` and #due:2026-12-01"
    editor.display(documentID: "md-editor", body: initial)
    let storage = editor.textStorage!
    let codeLoc = (initial as NSString).range(of: "code").location
    let tagLoc = (initial as NSString).range(of: "#due:2026-12-01").location
    let subjectFont = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    check(subjectFont.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true,
          "editor keeps line 1 subject bold")
    check(storage.attribute(.backgroundColor, at: codeLoc, effectiveRange: nil) != nil,
          "editor applies subtle background to inline code")
    check(storage.attribute(.backgroundColor, at: tagLoc, effectiveRange: nil) != nil,
          "editor applies subtle background to valid task tag")
    check(editor.undoManager?.canUndo == false, "initial highlighting adds no undo step")

    // Removing syntax clears stale attributes cleanly.
    editor.display(documentID: "md-editor", body: "Subject line\nBody with code and plain")
    let plainLoc = (editor.string as NSString).range(of: "code").location
    check(storage.attribute(.backgroundColor, at: plainLoc, effectiveRange: nil) == nil,
          "removing inline code clears stale background attribute")
    check(editor.string == "Subject line\nBody with code and plain", "highlighting never alters plain text")

    // Blockquote > and text share the exact same color and obliqueness.
    editor.display(documentID: "md-quote", body: "Subject\n> quoted text")
    let gtLoc = (editor.string as NSString).range(of: ">").location
    let qLoc = (editor.string as NSString).range(of: "quoted").location
    let gtColor = storage.attribute(.foregroundColor, at: gtLoc, effectiveRange: nil) as? NSColor
    let qColor = storage.attribute(.foregroundColor, at: qLoc, effectiveRange: nil) as? NSColor
    let gtOblique = storage.attribute(.obliqueness, at: gtLoc, effectiveRange: nil) as? CGFloat
    let qOblique = storage.attribute(.obliqueness, at: qLoc, effectiveRange: nil) as? CGFloat
    check(gtColor == qColor && gtOblique == qOblique && gtOblique != nil,
          "blockquote > and quoted text share identical style")

    return failures
}
