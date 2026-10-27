import Foundation

enum NarrationPath {
    static let pauseBoundaries = ",;:.!?\"'`”’)]}"
    // Consume URLs whole so their path components cannot be rewritten separately.
    static func tokenRegex() throws -> NSRegularExpression {
        try NSRegularExpression(pattern: #"[\(\[\{“‘]*(?:[a-z][a-z0-9+.-]*://|www\.)[^\s\"'`<>]+|[^\s\"'`<>,;!?]+"#, options: .caseInsensitive)
    }

    // The full list and pronunciation policy are documented in FileExtensions.md.
    private static let spelledExtensions: Set<String> = [
        // Shell and command scripts
        "sh", "zsh", "ksh", "csh", "ps1", "psm1", "psd1", "cmd",
        // C, C++, Objective-C, and CUDA
        "c", "h", "cc", "hh", "cpp", "hpp", "cxx", "hxx", "c++", "h++", "inl",
        "ipp", "tcc", "ixx", "cppm", "m", "mm", "cu", "cuh",
        // Python and notebooks
        "py", "pyi", "pyw", "pyc", "pyo", "ipynb", "whl",
        // JavaScript, TypeScript, and web
        "js", "mjs", "cjs", "jsx", "ts", "mts", "cts", "tsx", "html", "htm", "xhtml",
        "css", "scss", "gql",
        // Other programming languages
        "rs", "kt", "kts", "cs", "csx", "csproj", "sln", "fs", "fsx", "vb", "vbs",
        "rb", "php", "pl", "pm", "r", "rmd", "jl", "ex", "exs", "erl", "hrl",
        "hs", "ml", "mli", "clj", "cljs", "d",
        // Configuration, build files, and data
        "yml", "cfg", "mk", "sql", "csv", "tsv", "xml", "xsd", "xsl", "xslt", "db",
        // Word documents and templates
        "doc", "docx", "docm", "dot", "dotx", "dotm",
        // Excel workbooks, templates, and add-ins
        "xls", "xlsx", "xlsm", "xlsb", "xlt", "xltx", "xltm", "xla", "xlam", "xlw",
        // PowerPoint presentations, shows, templates, and add-ins
        "ppt", "pptx", "pptm", "pps", "ppsx", "ppsm", "pot", "potx", "potm", "ppa", "ppam",
        "sldx", "sldm", "thmx",
        // Other Microsoft Office files
        "mdb", "mde", "accdb", "accde", "accdt", "pst", "ost", "msg", "oft", "vsd", "vsdx",
        "vss", "vssx", "vst", "vstx", "mpp", "mpt", "pub",
        // Documents, books, and other office suites
        "txt", "md", "rst", "rtf", "pdf", "ps", "eps", "odt", "ods", "odp", "odg",
        "ott", "ots", "otp", "xps",
        // Images and graphics
        "png", "jpg", "svg", "bmp", "tif", "ico", "psd", "ai",
        // Audio and video
        "mp3", "mp4", "m4a", "m4v", "aac", "mkv", "avi", "mpg", "wma", "wmv",
        // Archives and compression
        "gz", "tgz", "bz2", "tbz2", "xz", "txz", "zst", "7z", "lz4",
        // Applications, packages, and compiled files
        "dmg", "pkg", "iso", "rpm", "msi", "dll", "so", "a", "o", "pdb", "apk",
        // Fonts and certificates
        "ttf", "otf", "woff2", "eot", "pem", "crt", "cer", "csr", "p12", "pfx"
    ]
    private static let fileExtensions = spelledExtensions.union([
        // Shell and command scripts
        "bash", "fish", "bat",
        // Go
        "go", "mod", "sum",
        // JavaScript, TypeScript, and web
        "sass", "less", "vue", "svelte", "wasm", "graphql",
        // Other programming languages
        "swift", "java", "class", "jar", "scala", "ruby", "rake", "gem", "lua", "dart", "zig",
        // Configuration, build files, and data
        "json", "jsonc", "jsonl", "ndjson", "yaml", "toml", "ini", "conf", "properties", "env", "lock",
        "cmake", "proto", "sqlite", "sqlite3", "parquet", "avro", "arrow", "log", "patch", "diff",
        // Other Microsoft Office files
        "one", "onepkg",
        // Documents, books, and other office suites
        "markdown", "tex", "bib", "adoc", "epub", "mobi", "pages", "numbers", "key",
        // Images and graphics
        "jpeg", "gif", "webp", "avif", "tiff", "heic",
        // Audio and video
        "wav", "flac", "ogg", "opus", "aif", "aiff", "mov", "webm", "mpeg",
        // Archives and compression
        "zip", "tar", "rar",
        // Applications, packages, and compiled files
        "deb", "exe", "dylib", "obj", "lib", "bin", "app",
        // Fonts and certificates
        "woff"
    ])
    private static let spokenCharacters: [Character: String] = [
        "0": "zero", "1": "one", "2": "two", "3": "three", "4": "four",
        "5": "five", "6": "six", "7": "seven", "8": "eight", "9": "nine", "+": "plus"
    ]

    static func pronounce(_ token: String, followedByBoundary: Bool = false) -> String {
        var start = token.startIndex, end = token.endIndex
        while start < end, "([{“‘".contains(token[start]) { start = token.index(after: start) }
        while end > start, ")]}.:!?,”’".contains(token[token.index(before: end)]) { end = token.index(before: end) }
        var path = String(token[start..<end])
        guard path.contains("/") || path.contains("."),
              !path.contains("://"), !path.lowercased().hasPrefix("www.") else { return token }
        // A compiler/editor reference is a path plus a line range, or a line and optional column.
        // Parse that suffix before validating path characters, which exclude colons.
        var location = ""
        if let range = path.range(of: #":[0-9]+(?:-[0-9]+|:[0-9]+)?$"#, options: .regularExpression) {
            let numbers = path[range].dropFirst().split(separator: ":")
            let lines = numbers[0].split(separator: "-")
            location = lines.count == 2 ? ", lines " + lines[0] + " to " + lines[1] : ", line " + lines[0]
            if numbers.count == 2 { location += ", column " + numbers[1] }
            path.removeSubrange(range)
        }
        guard path.range(of: #"^[\p{L}\p{M}\p{N}_./~+\-]+$"#, options: .regularExpression) != nil else { return token }

        let components = path.components(separatedBy: "/")
        let explicitPath = path.hasPrefix("/") || path.hasPrefix("./") || path.hasPrefix("../") || path.hasPrefix("~/")
        let filename = components.last ?? ""
        let suffix = filename.components(separatedBy: ".").last?.lowercased() ?? ""
        let hasExtension = filename.contains(".") && !filename.hasPrefix(".") &&
            (fileExtensions.contains(suffix) || suffix.range(of: #"^[a-z][a-z0-9]*$"#, options: .regularExpression) != nil)
        if !explicitPath {
            // Avoid dates/fractions, prose such as and/or, and bare website URLs.
            guard path.range(of: #"\p{L}"#, options: .regularExpression) != nil else { return token }
            if components.count > 1 {
                guard components[0].range(of: #"^[\p{L}\p{N}-]+(?:\.[\p{L}\p{N}-]+)*\.[a-z]{2,}$"#,
                                         options: [.regularExpression, .caseInsensitive]) == nil,
                      components.count >= 3 || hasExtension else { return token }
            } else {
                guard hasExtension, !filename.contains(".."), fileExtensions.contains(suffix) else { return token }
            }
        }

        let spoken = components.map { component in
            component.components(separatedBy: ".").enumerated().map { index, part in
                index > 0 && spelledExtensions.contains(part.lowercased()) ? part.uppercased().map { spokenCharacters[$0] ?? String($0) }.joined(separator: " ") : part
            }.joined(separator: " dot ")
        }.joined(separator: " slash ")
            .replacingOccurrences(of: "_", with: " underscore ")
            .replacingOccurrences(of: "-", with: " dash ")
            .replacingOccurrences(of: "~", with: "tilde")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let trailing = String(token[end...])
        let hasPause = followedByBoundary || trailing.contains(where: { pauseBoundaries.contains($0) })
        let pause = !location.isEmpty && !hasPause ? "," : ""
        return String(token[..<start]) + spoken + location + trailing + pause
    }
}
