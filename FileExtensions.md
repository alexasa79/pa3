# File extension pronunciation

Standalone identifiers also receive explicit pronunciation: `type_name_t` becomes “type underscore name underscore tee”, and `get_type_name()` becomes “get underscore type underscore name”. Single-letter parts use English letter names, including uppercase letters; repeated, leading, and trailing underscores are spoken individually. Function-call punctuation is preserved in the text sent to Qwen. Paths and filenames retain the rules below; URLs, email addresses, and ambiguous dotted names are excluded from the standalone identifier rule.

PA3 and its Chrome extension recognize the following extensions in bare filenames, case-insensitively. Explicit paths can also contain unlisted extensions. Both narrators say `slash`, `dot`, `underscore`, and `dash` for filename separators; `file_name.cpp:888` becomes “file underscore name dot C P P, line 888,”. Line ranges use “lines” and “to”: `file.c:100-200` becomes “file dot C, lines 100 to 200,”. Existing punctuation supplies the pause when it follows a reference.

Short extensions and initialisms are spelled out (`cpp` → “C P P”, `docx` → “D O C X”, `xlsx` → “X L S X”). Word-like extensions retain their names (`go`, `swift`, `bash`, `json`, `zip`). For spelled extensions, digits and plus signs are spoken explicitly: `mp3` → “M P three”, `7z` → “seven Z”, `c++` → “C plus plus”. Every dot in compound extensions is spoken: `archive.tar.gz` → “archive dot tar dot G Z” and `types.d.ts` → “types dot D dot T S”.

Custom vocabulary substitutions run before filename pronunciation, so a full filename can have a user-defined reading. These rules prepare the text sent to Qwen; they do not provide phoneme-level control over the model's audio.

| Category | Spell out | Read as words |
| --- | --- | --- |
| Shell and command scripts | `.sh`, `.zsh`, `.ksh`, `.csh`, `.ps1`, `.psm1`, `.psd1`, `.cmd` | `.bash`, `.fish`, `.bat` |
| C, C++, Objective-C, and CUDA | `.c`, `.h`, `.cc`, `.hh`, `.cpp`, `.hpp`, `.cxx`, `.hxx`, `.c++`, `.h++`, `.inl`, `.ipp`, `.tcc`, `.ixx`, `.cppm`, `.m`, `.mm`, `.cu`, `.cuh` | — |
| Python and notebooks | `.py`, `.pyi`, `.pyw`, `.pyc`, `.pyo`, `.ipynb`, `.whl` | — |
| Go | — | `.go`, `.mod`, `.sum` |
| JavaScript, TypeScript, and web | `.js`, `.mjs`, `.cjs`, `.jsx`, `.ts`, `.mts`, `.cts`, `.tsx`, `.html`, `.htm`, `.xhtml`, `.css`, `.scss`, `.gql` | `.sass`, `.less`, `.vue`, `.svelte`, `.wasm`, `.graphql` |
| Other programming languages | `.rs`, `.kt`, `.kts`, `.cs`, `.csx`, `.csproj`, `.sln`, `.fs`, `.fsx`, `.vb`, `.vbs`, `.rb`, `.php`, `.pl`, `.pm`, `.r`, `.rmd`, `.jl`, `.ex`, `.exs`, `.erl`, `.hrl`, `.hs`, `.ml`, `.mli`, `.clj`, `.cljs`, `.d` | `.swift`, `.java`, `.class`, `.jar`, `.scala`, `.ruby`, `.rake`, `.gem`, `.lua`, `.dart`, `.zig` |
| Configuration, build files, and data | `.yml`, `.cfg`, `.mk`, `.sql`, `.csv`, `.tsv`, `.xml`, `.xsd`, `.xsl`, `.xslt`, `.db` | `.json`, `.jsonc`, `.jsonl`, `.ndjson`, `.yaml`, `.toml`, `.ini`, `.conf`, `.properties`, `.env`, `.lock`, `.cmake`, `.proto`, `.sqlite`, `.sqlite3`, `.parquet`, `.avro`, `.arrow`, `.log`, `.patch`, `.diff` |
| Word documents and templates | `.doc`, `.docx`, `.docm`, `.dot`, `.dotx`, `.dotm` | — |
| Excel workbooks, templates, and add-ins | `.xls`, `.xlsx`, `.xlsm`, `.xlsb`, `.xlt`, `.xltx`, `.xltm`, `.xla`, `.xlam`, `.xlw` | — |
| PowerPoint presentations, shows, templates, and add-ins | `.ppt`, `.pptx`, `.pptm`, `.pps`, `.ppsx`, `.ppsm`, `.pot`, `.potx`, `.potm`, `.ppa`, `.ppam`, `.sldx`, `.sldm`, `.thmx` | — |
| Other Microsoft Office files | `.mdb`, `.mde`, `.accdb`, `.accde`, `.accdt`, `.pst`, `.ost`, `.msg`, `.oft`, `.vsd`, `.vsdx`, `.vss`, `.vssx`, `.vst`, `.vstx`, `.mpp`, `.mpt`, `.pub` | `.one`, `.onepkg` |
| Documents, books, and other office suites | `.txt`, `.md`, `.rst`, `.rtf`, `.pdf`, `.ps`, `.eps`, `.odt`, `.ods`, `.odp`, `.odg`, `.ott`, `.ots`, `.otp`, `.xps` | `.markdown`, `.tex`, `.bib`, `.adoc`, `.epub`, `.mobi`, `.pages`, `.numbers`, `.key` |
| Images and graphics | `.png`, `.jpg`, `.svg`, `.bmp`, `.tif`, `.ico`, `.psd`, `.ai` | `.jpeg`, `.gif`, `.webp`, `.avif`, `.tiff`, `.heic` |
| Audio and video | `.mp3`, `.mp4`, `.m4a`, `.m4v`, `.aac`, `.mkv`, `.avi`, `.mpg`, `.wma`, `.wmv` | `.wav`, `.flac`, `.ogg`, `.opus`, `.aif`, `.aiff`, `.mov`, `.webm`, `.mpeg` |
| Archives and compression | `.gz`, `.tgz`, `.bz2`, `.tbz2`, `.xz`, `.txz`, `.zst`, `.7z`, `.lz4` | `.zip`, `.tar`, `.rar` |
| Applications, packages, and compiled files | `.dmg`, `.pkg`, `.iso`, `.rpm`, `.msi`, `.dll`, `.so`, `.a`, `.o`, `.pdb`, `.apk` | `.deb`, `.exe`, `.dylib`, `.obj`, `.lib`, `.bin`, `.app` |
| Fonts and certificates | `.ttf`, `.otf`, `.woff2`, `.eot`, `.pem`, `.crt`, `.cer`, `.csr`, `.p12`, `.pfx` | `.woff` |

The Word, Excel, and PowerPoint entries include current, legacy, macro-enabled, template, and add-in formats from [Microsoft’s file format reference](https://learn.microsoft.com/en-us/office/compatibility/office-file-format-reference).

The catalogs live in `Sources/PA3/NarrationPath.swift` and `chrome-extension/native_request_builder.js`; update both when adding an extension. URLs with a scheme or `www.` are left intact. Ambiguous bare names are treated as filenames when their extension is listed here.
