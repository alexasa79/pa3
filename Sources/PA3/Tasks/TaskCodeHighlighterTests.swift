import AppKit
import Foundation

@MainActor
func runCodeHighlighterTests() -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ name: String) { if !condition { failures.append("code-highlight: " + name) } }

    func fencedTokens(_ lang: String, _ code: String, highlightTaskTags: Bool = true) -> (doc: String, tokens: [MarkdownToken]) {
        let doc = "```\(lang)\n\(code)\n```"
        return (doc, TaskMarkdownHighlighter.tokens(in: doc, highlightTaskTags: highlightTaskTags))
    }

    func hasCode(_ doc: String, _ tokens: [MarkdownToken], _ text: String, _ kind: CodeTokenKind) -> Bool {
        let source = doc as NSString
        return tokens.contains { tok in
            guard tok.kind == .codeSyntax(kind) else { return false }
            return source.substring(with: tok.range) == text
        }
    }

    func hasAnyCode(_ doc: String, _ tokens: [MarkdownToken], _ text: String) -> Bool {
        let source = doc as NSString
        return tokens.contains { tok in
            guard case .codeSyntax = tok.kind else { return false }
            return source.substring(with: tok.range) == text
        }
    }

    // 1. Fence label resolution & aliases (mirrors Veda's fence alias and rejection rules).
    let expectedAliases: [(String, CodeLanguage)] = [
        ("swift", .swift), ("SWIFT", .swift),
        ("go", .go), ("golang", .go),
        ("c", .c), ("h", .c),
        ("cpp", .cpp), ("c++", .cpp), ("cc", .cpp), ("cxx", .cpp), ("objc", .cpp), ("mm", .cpp),
        ("rust", .rust), ("rs", .rust),
        ("python", .python), ("py", .python), ("python3", .python),
        ("javascript", .javascript), ("js", .javascript), ("jsx", .javascript),
        ("typescript", .typescript), ("ts", .typescript), ("tsx", .typescript),
        ("bash", .bash), ("sh", .bash), ("shell", .bash), ("zsh", .bash), ("fish", .bash),
        ("json", .json), ("jsonc", .json),
        ("yaml", .yaml), ("yml", .yaml),
        ("sql", .sql), ("sqlite", .sql), ("postgres", .sql),
        ("make", .make), ("makefile", .make),
    ]
    for (alias, expected) in expectedAliases {
        check(CodeLanguage.forFenceLabel(alias) == expected, "alias '\(alias)' resolves to \(expected.rawValue)")
    }
    for rejected in ["", "   ", "unknownlang", "c extra", "swift\tnotes", "go`bad"] {
        check(CodeLanguage.forFenceLabel(rejected) == nil, "rejects fence label '\(rejected)'")
    }

    // Every CodeLanguage produces syntax tokens when fenced.
    for lang in CodeLanguage.allCases {
        let sample: String
        switch lang {
        case .swift: sample = "func run() { let x = 1 }"
        case .go: sample = "func main() { x := 1 }"
        case .c: sample = "int main(void) { return 0; }"
        case .cpp: sample = "class Box { int x = 1; };"
        case .rust: sample = "fn main() { let x = 1; }"
        case .python: sample = "def run(): return 1"
        case .javascript: sample = "const x = 1;"
        case .typescript: sample = "const x: number = 1;"
        case .bash: sample = "if true; then echo ok; fi"
        case .json: sample = #"{"k": 1}"#
        case .yaml: sample = "key: true"
        case .sql: sample = "SELECT 1;"
        case .make: sample = "all:\n\t@echo ok"
        }
        let (_, toks) = fencedTokens(lang.rawValue, sample)
        check(toks.contains { if case .codeSyntax = $0.kind { return true }; return false },
              "language '\(lang.rawValue)' emits syntax tokens inside fence")
    }

    // 2. Swift: attributes, nested block comments, multi-line strings, numbers, functions, negative checks.
    do {
        let code = """
        @MainActor
        struct Item {
            /* outer /* nested func inside */ still comment */
            func load(count: Int = 1_000) async -> String? {
                let hex = 0xFF_00
                let msg = "escaped \\"func\\" ok"
                let block = \"\"\"
                multiline return inside string
                \"\"\"
                return nil // trailing func comment
            }
        }
        """
        let (doc, toks) = fencedTokens("swift", code)
        check(hasCode(doc, toks, "@MainActor", .preprocessor), "swift: @MainActor attribute")
        check(hasCode(doc, toks, "struct", .keyword), "swift: struct keyword")
        check(hasCode(doc, toks, "Item", .type), "swift: PascalCase type")
        check(hasCode(doc, toks, "/* outer /* nested func inside */ still comment */", .comment), "swift: nested block comment")
        check(hasCode(doc, toks, "func", .keyword), "swift: func keyword")
        check(hasCode(doc, toks, "load", .function), "swift: function declaration")
        check(hasCode(doc, toks, "Int", .type), "swift: Int type")
        check(hasCode(doc, toks, "1_000", .number), "swift: underscore number")
        check(hasCode(doc, toks, "0xFF_00", .number), "swift: hex number")
        check(hasCode(doc, toks, "async", .keyword), "swift: async keyword")
        check(hasCode(doc, toks, "String", .type), "swift: String type")
        check(hasCode(doc, toks, #""escaped \"func\" ok""#, .string), "swift: escaped quote in string")
        check(hasCode(doc, toks, "        multiline return inside string", .string), "swift: multi-line triple string body")
        check(hasCode(doc, toks, "nil", .constant), "swift: nil constant")
        check(hasCode(doc, toks, "// trailing func comment", .comment), "swift: line comment")
        // Negative: keywords inside comments/strings must not become .keyword
        let kwCount = toks.filter { $0.kind == .codeSyntax(.keyword) && (doc as NSString).substring(with: $0.range) == "func" }.count
        check(kwCount == 1, "swift: func inside nested comment/string/line-comment is not a keyword (got \(kwCount))")
        let retCount = toks.filter { $0.kind == .codeSyntax(.keyword) && (doc as NSString).substring(with: $0.range) == "return" }.count
        check(retCount == 1, "swift: return inside triple string is not a keyword (got \(retCount))")
    }

    // 3. Go: raw multi-line backtick strings (backslash does NOT escape `), runes, defer/chan/iota.
    do {
        let code = """
        package main
        func serve(ch chan error) int {
            defer close(ch)
            raw := `raw line\\
        func notKeyword`
            r := '\\''
            return iota
        }
        """
        let (doc, toks) = fencedTokens("golang", code)
        check(hasCode(doc, toks, "package", .keyword), "go: package keyword")
        check(hasCode(doc, toks, "serve", .function), "go: function name")
        check(hasCode(doc, toks, "chan", .keyword), "go: chan keyword")
        check(hasCode(doc, toks, "error", .type), "go: error type")
        check(hasCode(doc, toks, "int", .type), "go: int type")
        check(hasCode(doc, toks, "defer", .keyword), "go: defer keyword")
        check(hasCode(doc, toks, "close", .function), "go: function call")
        check(hasCode(doc, toks, "`raw line\\", .string), "go: raw backtick string line 1")
        check(hasCode(doc, toks, "func notKeyword`", .string), "go: raw backtick string line 2")
        check(hasCode(doc, toks, #"'\\''"#.replacingOccurrences(of: #"\\"#, with: #"\"#), .string)
              || hasCode(doc, toks, "'\\''", .string), "go: escaped rune literal")
        check(hasCode(doc, toks, "iota", .constant), "go: iota constant")
        let funcKeywords = toks.filter { $0.kind == .codeSyntax(.keyword) && (doc as NSString).substring(with: $0.range) == "func" }.count
        check(funcKeywords == 1, "go: func inside raw backtick string is not a keyword")
    }

    // 4. C and C++: preprocessor, angle-bracket include, multi-line comments, types, nullptr.
    do {
        let code = """
        #include <stdio.h>
        #define LIMIT 0x1A
        /* block
           return inside comment */
        int main(void) {
            printf("Hello\\n");
            return NULL == 0;
        }
        """
        let (doc, toks) = fencedTokens("c", code)
        check(hasCode(doc, toks, "#include", .preprocessor), "c: #include preprocessor")
        check(hasCode(doc, toks, "<stdio.h>", .string), "c: angle-bracket header")
        check(hasCode(doc, toks, "#define", .preprocessor), "c: #define preprocessor")
        check(hasCode(doc, toks, "0x1A", .number), "c: hex number")
        check(hasCode(doc, toks, "/* block", .comment), "c: multi-line block comment line 1")
        check(hasCode(doc, toks, "   return inside comment */", .comment), "c: multi-line block comment line 2")
        check(hasCode(doc, toks, "int", .type), "c: int type")
        check(hasCode(doc, toks, "void", .type), "c: void type")
        check(hasCode(doc, toks, "printf", .function), "c: printf call")
        check(hasCode(doc, toks, #""Hello\n""#, .string), "c: string literal")
        check(hasCode(doc, toks, "NULL", .constant), "c: NULL constant")
        let retCount = toks.filter { $0.kind == .codeSyntax(.keyword) && (doc as NSString).substring(with: $0.range) == "return" }.count
        check(retCount == 1, "c: return inside multi-line comment is not a keyword")

        let cppCode = "template <typename T>\nconstexpr uint64_t f(const std::vector<T>& v) { return nullptr == &v; }"
        let (cppDoc, cppToks) = fencedTokens("c++", cppCode)
        check(hasCode(cppDoc, cppToks, "template", .keyword), "cpp: template keyword")
        check(hasCode(cppDoc, cppToks, "constexpr", .keyword), "cpp: constexpr keyword")
        check(hasCode(cppDoc, cppToks, "uint64_t", .type), "cpp: uint64_t type")
        check(hasCode(cppDoc, cppToks, "vector", .type), "cpp: vector type")
        check(hasCode(cppDoc, cppToks, "nullptr", .constant), "cpp: nullptr constant")
    }

    // 5. Rust: lifetimes ('a, 'static) do NOT swallow line as string; char literals, attributes, binary numbers.
    do {
        let code = """
        #[derive(Debug)]
        pub fn pick<'a>(s: &'a str, fallback: &'static str) -> &'a str {
            let ch = 'z';
            let mask = 0b1010_0101u8;
            let raw = b"ok";
            if true { s } else { fallback }
        }
        """
        let (doc, toks) = fencedTokens("rs", code)
        check(hasCode(doc, toks, "#[derive(Debug)]", .preprocessor), "rust: #[derive(Debug)] attribute")
        check(hasCode(doc, toks, "pub", .keyword), "rust: pub keyword")
        check(hasCode(doc, toks, "fn", .keyword), "rust: fn keyword")
        check(hasCode(doc, toks, "'a", .type), "rust: 'a lifetime")
        check(hasCode(doc, toks, "'static", .type), "rust: 'static lifetime")
        check(hasCode(doc, toks, "str", .type), "rust: str type after lifetime (lifetime didn't swallow line)")
        check(hasCode(doc, toks, "'z'", .string), "rust: char literal")
        check(hasCode(doc, toks, "0b1010_0101u8", .number), "rust: binary number with suffix")
        check(hasCode(doc, toks, #"b"ok""#, .string), "rust: byte string literal")
        check(hasCode(doc, toks, "else", .keyword), "rust: else keyword")
    }

    // 6. Python: decorators, f/r strings, triple-quoted docstrings, None/True/False, comments.
    do {
        let code = """
        @dataclass
        def greet(name: str) -> None:
            \"\"\"Docstring with def inside\"\"\"
            msg = f"Hi {name}"
            pat = r'\\d+'
            val = 3.14e-2 # comment with return
            return True
        """
        let (doc, toks) = fencedTokens("py", code)
        check(hasCode(doc, toks, "@dataclass", .preprocessor), "python: @decorator")
        check(hasCode(doc, toks, "def", .keyword), "python: def keyword")
        check(hasCode(doc, toks, "greet", .function), "python: function name")
        check(hasCode(doc, toks, "str", .type), "python: str type")
        check(hasCode(doc, toks, "None", .constant), "python: None constant")
        check(hasCode(doc, toks, #"f"Hi {name}""#, .string), "python: f-string")
        check(hasCode(doc, toks, #"r'\d+'"#, .string), "python: raw single-quoted string")
        check(hasCode(doc, toks, "3.14e-2", .number), "python: scientific float")
        check(hasCode(doc, toks, "# comment with return", .comment), "python: hash comment")
        check(hasCode(doc, toks, "True", .constant), "python: True constant")
        let defCount = toks.filter { $0.kind == .codeSyntax(.keyword) && (doc as NSString).substring(with: $0.range) == "def" }.count
        check(defCount == 1, "python: def inside docstring is not a keyword")
    }

    // 7. JavaScript & TypeScript: template strings, interfaces, types, decorators, undefined.
    do {
        let code = """
        interface User { readonly id: number; }
        const msg = `hello ${name} // not comment`;
        async function fetchUser(): Promise<User | undefined> { return undefined; }
        """
        let (doc, toks) = fencedTokens("ts", code)
        check(hasCode(doc, toks, "interface", .keyword), "ts: interface keyword")
        check(hasCode(doc, toks, "readonly", .keyword), "ts: readonly keyword")
        check(hasCode(doc, toks, "number", .type), "ts: number type")
        check(hasCode(doc, toks, "User", .type), "ts: PascalCase type")
        check(hasCode(doc, toks, "`hello ${name} // not comment`", .string), "ts: template literal protects //")
        check(!toks.contains { $0.kind == .codeSyntax(.comment) }, "ts: // inside template string is not a comment")
        check(hasCode(doc, toks, "async", .keyword), "ts: async keyword")
        check(hasCode(doc, toks, "fetchUser", .function), "ts: function name")
        check(hasCode(doc, toks, "Promise", .type), "ts: Promise type")
        check(hasCode(doc, toks, "undefined", .constant), "ts: undefined constant")
    }

    // 8. Bash / Shell: assignments, $VAR / ${VAR}, double-quote expansion vs single-quote literal, # boundary.
    do {
        let code = """
        # Install script #done
        TOKEN=$(cat "$HOME/token")
        echo "Bearer $TOKEN" 'literal $TOKEN' foo#notcomment
        run --file ~/.cache/pa3/2026-09-06.wav --speed 4
        if true; then echo ${TOKEN}; fi
        """
        let (doc, toks) = fencedTokens("bash", code)
        check(hasCode(doc, toks, "# Install script #done", .comment), "bash: comment line")
        check(hasCode(doc, toks, "TOKEN", .variable), "bash: variable assignment LHS")
        check(hasCode(doc, toks, "$HOME", .variable), "bash: $HOME inside double quotes")
        check(hasCode(doc, toks, "$TOKEN", .variable), "bash: $TOKEN inside double quotes")
        check(hasCode(doc, toks, "'literal $TOKEN'", .string), "bash: single quotes keep $TOKEN literal")
        check(hasCode(doc, toks, "${TOKEN}", .variable), "bash: braced variable")
        check(hasCode(doc, toks, "4", .number), "bash: standalone numeric argument")
        check(!hasCode(doc, toks, "2026", .number), "bash: digits inside file path are not numbers")
        check(hasCode(doc, toks, "if", .keyword) && hasCode(doc, toks, "then", .keyword) && hasCode(doc, toks, "fi", .keyword),
              "bash: if/then/fi keywords")
        check(!toks.contains { $0.kind == .codeSyntax(.comment) && (doc as NSString).substring(with: $0.range).contains("notcomment") },
              "bash: foo#notcomment is not a comment")
        check(!toks.contains { if case .taskTag = $0.kind { return true }; return false },
              "bash: #done inside code comment does not trigger task tag")
    }

    // 9. JSON & YAML: keys vs string values, booleans/null, numbers, comments.
    do {
        let jsonCode = """
        {
          // comment
          "name": "PA3",
          "count": -42.5,
          "active": true,
          "empty": null
        }
        """
        let (jDoc, jToks) = fencedTokens("jsonc", jsonCode)
        check(hasCode(jDoc, jToks, "// comment", .comment), "jsonc: comment")
        check(hasCode(jDoc, jToks, "\"name\"", .variable), "json: property key")
        check(hasCode(jDoc, jToks, "\"PA3\"", .string), "json: string value")
        check(hasCode(jDoc, jToks, "-42.5", .number), "json: negative float")
        check(hasCode(jDoc, jToks, "true", .constant) && hasCode(jDoc, jToks, "null", .constant), "json: constants")

        let yamlCode = """
        # Config
        service:
          port: 8080 # inline comment
          enabled: true
          label: "hello"
        """
        let (yDoc, yToks) = fencedTokens("yml", yamlCode)
        check(hasCode(yDoc, yToks, "# Config", .comment), "yaml: leading comment")
        check(hasCode(yDoc, yToks, "service", .variable), "yaml: top key")
        check(hasCode(yDoc, yToks, "port", .variable), "yaml: nested key")
        check(hasCode(yDoc, yToks, "8080", .number), "yaml: integer value")
        check(hasCode(yDoc, yToks, "# inline comment", .comment), "yaml: inline comment")
        check(hasCode(yDoc, yToks, "true", .constant), "yaml: boolean value")
        check(hasCode(yDoc, yToks, "\"hello\"", .string), "yaml: quoted string")
    }

    // 10. SQL: case-insensitive keywords, -- comments, '' escaped strings, functions.
    do {
        let sqlCode = """
        -- Query active tasks
        select count(id), 'O''Brien' from tasks
        WHERE status IS NOT NULL LIMIT 10;
        """
        let (doc, toks) = fencedTokens("sql", sqlCode)
        check(hasCode(doc, toks, "-- Query active tasks", .comment), "sql: -- comment")
        check(hasCode(doc, toks, "select", .keyword) && hasCode(doc, toks, "from", .keyword)
              && hasCode(doc, toks, "WHERE", .keyword) && hasCode(doc, toks, "LIMIT", .keyword),
              "sql: case-insensitive keywords")
        check(hasCode(doc, toks, "count", .function), "sql: function call")
        check(hasCode(doc, toks, "'O''Brien'", .string), "sql: doubled single-quote escape")
        check(hasCode(doc, toks, "NULL", .constant), "sql: NULL constant")
        check(hasCode(doc, toks, "10", .number), "sql: integer")
    }

    // 11. Makefile: targets, variables, comments.
    do {
        let makeCode = """
        # Build PA3
        BREW ?= /opt/homebrew/bin/brew
        all:
        \t$(BREW) --prefix # check brew
        """
        let (doc, toks) = fencedTokens("makefile", makeCode)
        check(hasCode(doc, toks, "# Build PA3", .comment), "make: comment")
        check(hasCode(doc, toks, "BREW", .variable), "make: variable assignment")
        check(hasCode(doc, toks, "all", .constant), "make: target rule")
        check(hasCode(doc, toks, "$(BREW)", .variable), "make: $(VAR) expansion")
        check(hasCode(doc, toks, "# check brew", .comment), "make: recipe comment")
    }

    // 12. Unlabeled / unsupported fences emit zero codeSyntax tokens.
    for label in ["", "text", "unknownlang", "c extra"] {
        let (doc, toks) = fencedTokens(label, "int main() { return 0; }")
        check(!hasAnyCode(doc, toks, "int") && !hasAnyCode(doc, toks, "return"),
              "fence '\(label)' falls back to uniform codeBlock without syntax tokens")
        check(toks.contains { $0.kind == .codeBlock }, "fence '\(label)' still emits codeBlock")
    }

    // 13. UTF-16 safety with Cyrillic + emoji inside code comments and strings.
    do {
        let code = "let title = \"Привет 👨‍👩‍👧‍👦\" // готово\nreturn title"
        let (doc, toks) = fencedTokens("swift", code)
        check(hasCode(doc, toks, "\"Привет 👨‍👩‍👧‍👦\"", .string), "unicode: Cyrillic + emoji string range")
        check(hasCode(doc, toks, "// готово", .comment), "unicode: Cyrillic comment range")
        check(hasCode(doc, toks, "return", .keyword), "unicode: keyword after emoji line has exact offset")
    }

    // 14. Nested emphasis & multi-line emphasis (token + NSTextStorage verification).
    do {
        let nested = "Subject\n**bold *and italic* end** and *italic **and bold** end*"
        let tokens = TaskMarkdownHighlighter.tokens(in: nested, highlightTaskTags: false)
        let source = nested as NSString
        check(tokens.contains { $0.kind == .bold && source.substring(with: $0.range) == "**bold *and italic* end**" },
              "nested: outer bold span")
        check(tokens.contains { $0.kind == .italic && source.substring(with: $0.range) == "*and italic*" },
              "nested: inner italic inside bold")
        check(tokens.contains { $0.kind == .italic && source.substring(with: $0.range) == "*italic **and bold** end*" },
              "nested: outer italic span")
        check(tokens.contains { $0.kind == .bold && source.substring(with: $0.range) == "**and bold**" },
              "nested: inner bold inside italic")

        let editor = TaskModalTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 320))
        editor.isRichText = false
        editor.highlightTaskTags = false
        editor.display(documentID: "nested-emph", body: nested)
        let storage = editor.textStorage!
        let innerLoc = source.range(of: "and italic").location
        let innerFont = storage.attribute(.font, at: innerLoc, effectiveRange: nil) as? NSFont
        let innerOblique = storage.attribute(.obliqueness, at: innerLoc, effectiveRange: nil) as? CGFloat
        check(innerFont.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true
              && innerOblique != nil,
              "nested: inner *and italic* inside **bold** renders with BOTH bold font and obliqueness")
    }

    do {
        let multi = """
        Title
        Start **bold text
        continues with `code` and *italic* here** end.

        Unclosed *star does not cross blank line

        into next *paragraph* wrongly.
        """
        let tokens = TaskMarkdownHighlighter.tokens(in: multi, highlightTaskTags: false)
        let source = multi as NSString
        check(tokens.contains { $0.kind == .bold && source.substring(with: $0.range) == "**bold text" },
              "multi-line emphasis: line 1 segment")
        check(tokens.contains { $0.kind == .bold && source.substring(with: $0.range) == "continues with `code` and *italic* here**" },
              "multi-line emphasis: line 2 segment")
        check(tokens.contains { $0.kind == .inlineCode && source.substring(with: $0.range) == "`code`" },
              "multi-line emphasis: inline code inside multi-line bold still highlights")
        check(tokens.contains { $0.kind == .italic && source.substring(with: $0.range) == "*italic*" },
              "multi-line emphasis: nested italic inside multi-line bold still highlights")
        check(!tokens.contains { $0.kind == .italic && source.substring(with: $0.range).contains("does not cross") },
              "multi-line emphasis: unclosed * does not swallow text across blank line")
        check(tokens.contains { $0.kind == .italic && source.substring(with: $0.range) == "*paragraph*" },
              "multi-line emphasis: italic in next paragraph still highlights cleanly")
    }

    return failures
}
