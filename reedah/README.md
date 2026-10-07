# Reedah

Reedah adds paragraph narration controls to web pages in Chrome. PA3 runs Qwen3-TTS locally and streams audio through Reedah's native messaging bridge. Chrome plays the audio and handles pause, passage navigation, highlighting, and playback speed.

Reedah lives in the PA3 repository so changes to the app, extension, and bridge can ship together. The extension remains separately loaded in Chrome; building PA3 does not install it.

## Setup on macOS

1. From the repository root, build and launch PA3 as described in the [main README](../README.md#build-and-run). Let its speech models finish downloading.
2. Open `chrome://extensions`, enable Developer mode, choose **Load unpacked**, and select this repository's **`reedah/` directory**. Do not select the repository root or `reedah/native/`.
3. Copy Reedah's extension ID and run this command from the repository root:

   ```sh
   make reedah-install EXTENSION_ID=<chrome-extension-id>
   ```

4. Open a web page, press **Alt+X** (Option+X on Mac), and use the paragraph controls. **Alt+D** pauses or resumes playback. **Test Narration** in extension options also checks playback.

The bridge requires Python 3 and uses only its standard library. Chrome launches it on demand. Keep this checkout in place: the installed native host manifest points at `reedah/native/reedah_native_host.py` here. After moving the checkout or changing the extension ID, repeat registration. If PA3 uses a custom port, set `PA3_NARRATION_PORT` in Chrome's launch environment as well.

After changing extension scripts, reload Reedah in `chrome://extensions` and refresh web pages that already contain its content script. Rebuild PA3 with `make app` and restart it after app or native helper changes.

## Existing standalone installations

All future development belongs in this repository's `reedah/` directory. An unpacked extension's ID can change when loaded from a different path; Chrome treats that as a separate installation with separate settings. Save any playback settings before removing the old installation, load this directory, and register the ID Chrome displays. Remove the old extension once the new installation works to avoid duplicate overlays.

## Voice and playback

The voice is PA3's American male (Iowa), VCTK p311. Playback speed is applied in Chrome without changing pitch. Manage the shared narration dictionary in PA3’s menu-bar menu under **Dictionaries… → Narration**, for example `PA3` → `P A three`. Reedah sends original terms to PA3, which applies dictionary substitutions and pronunciation rules. Legacy model-specific voices and phonemes are not used.

Narration skips only parenthesized single file/path references with a colon and line number, such as `(src/file.swift:42)`. Line ranges and optional columns also qualify. Ordinary parenthetical explanations, nested prose, and unmatched parentheses remain spoken. Source text and highlighting positions are unchanged.

Each paragraph is a streaming request; very long paragraphs are divided into bounded passages. PA3 generates up to 600 spoken characters together and uses local Whisper recognition to estimate word timings. The entire paragraph has a subtle tint, with a stronger highlight moving through roughly three source words at a time. Dictionary expansions remain mapped to the original terms. Timings follow the audio clock across pause, replay, and pitch-preserving speed changes. Recognition adds startup buffering and can miss individual words; alignment failures stop narration. Generation can fall behind playback on a busy GPU; the player then shows **Buffering** and resumes when audio is available.

The **Previous sentence** and **Next sentence** buttons navigate actual sentences within a paragraph stream. Reedah maps each sentence to its first recognized word’s audio time and seeks within retained audio, without requesting narration again. If a requested sentence is still being generated, playback pauses and shows **Buffering** until its audio and timings arrive. Further clicks change the pending destination. A sentence button resumes playback when paused; Previous on the first sentence restarts it, and Next on the last advances to the next paragraph.

Sentence navigation also crosses the bounded passages used for very long paragraphs. The current passage and two prior passages are retained for replay; Previous is disabled when its target has been released. Stop or changing paragraphs cancels pending seeks. Missing target word alignment stops narration with a console error rather than estimating an audio position. Word timing quality still determines how closely a jump lands on the spoken sentence boundary.

## Paragraph detection

Reedah recognizes semantic paragraphs, headings, lists, quotations, figure captions, and definitions. Inside article/main landmarks, article-body metadata, `.entry-content`, `.post-body`, and `.prose` containers, it also detects bare text, generic divs, block-styled spans, light-DOM custom elements, and prose in table cells. This includes older Blogger posts. Line breaks and nested blocks separate bare text runs; text before and after existing paragraphs remains readable. Posts stored in a single paragraph with pairs of line breaks, including LinkedIn’s `p > span` format, get a control for each blank-line-separated paragraph; single line breaks stay inside their paragraph. Whole-sentence links and short multilingual paragraphs are supported, as are `display: contents`, columns, and vertical text. Reading order follows the DOM, including in CSS layouts that visually reorder elements.

Complete prose blocks receive a temporary marker class; mixed containers receive inline wrappers around their bare text runs. Disabling Reedah removes both. Inline links retain their original elements. Visibility/class changes, opening disclosures, and inserted or replaced content trigger rescans. Navigation, controls, editors, hidden/inert content, and closed disclosures are excluded. Article headers remain readable; site headers remain excluded. Line breaks within semantic paragraphs supply spoken spaces, and hidden inline duplicates are omitted.

Known boundaries: arbitrary div-only pages without content landmarks, shadow-root content, canvas/image text, and CSS-generated text are not extracted. Virtualized pages expose only currently mounted content. Supporting shadow roots requires coordinated discovery, observers, highlighting, and navigation; image/canvas text requires a separate extraction source. These are not covered by the prose-container rules.

List items used as accordion or card containers give their paragraphs separate controls, including prose mixed with tables and nested lists. Ordinary list items keep their spoken numbering; a multi-paragraph numbered item announces its number only on the first paragraph.

Reedah also runs in ordinary same-origin and cross-origin iframes and eligible inherited-origin frames. Enable/disable is shared across the tab, and starting narration in one frame stops narration in the others. Paragraph navigation stays within the current document. Chrome restrictions and extension site-access settings still apply.

## Confluence live documents

Reedah supports the main live document editor on Confluence Cloud page URLs. Paragraphs, headings, lists, quotations, and table-cell paragraphs receive narration controls. Comment composers, nested inputs, code editors, collaborator cursors, placeholders, and collapsed content are excluded.

In this editor, paragraph and phrase tinting uses CSS Custom Highlights on existing text ranges. It does not split text nodes, insert highlight spans into the document, or change the editing selection. If the active paragraph changes or disappears, narration stops; press Play to read the updated text. Changes to a prefetched paragraph discard its old audio. Collaborator cursor movements and replacement of DOM nodes with identical text do not interrupt playback. Ordinary web pages keep their existing highlighting.

## Mathematical text

Reedah recognizes native MathML, [KaTeX HTML and MathML output](https://katex.org/docs/options), [MathJax HTML/SVG with accessibility metadata](https://docs.mathjax.org/en/v4.0/basic/accessibility.html), and Wikimedia's MathML-backed equation wrappers. It reads each formula once, excluding duplicate visual copies, TeX annotations, and MathJax previews. Standalone formulas receive their own narration control; formulas inside paragraphs belong to that paragraph.

The MathML reader preserves fractions, powers, subscripts, roots, sum/integral limits, fences, and table rows/columns. It names common operators and Greek letters. For example, `x²` becomes “x squared,” and a nested fraction is spoken with explicit “fraction … over … end fraction” boundaries. This is a structural reader for common presentation MathML, not a complete mathematical speech engine.

For MathJax, Reedah reads the whole-expression speech label or the assistive MathML. It understands MathJax 4's plain-text `data-semantic-speech-none` attribute and never sends SSML tags to Qwen. KaTeX uses MathML when present; HTML-only KaTeX retains its rendered text, including the variables on LeetCode. Before sending a sentence to PA3, Reedah also expands `≥`, `≤`, `≠`, and `≈` into spoken comparisons.

Extraction and highlighting share offsets into the narration text, with each formula mapped to one intact DOM element. Hidden surrounding content stays excluded, and highlighting does not modify a renderer's internal markup. All reading and conversion happen locally in the extension, with no new downloads or bridge processing.

Remaining gaps include unrendered TeX/macros, equations stored only as images, and structural interpretation of complex HTML-only KaTeX. MathJax without a speech label or assistive MathML, unsupported MathML constructs/operators, and malformed formulas produce a console error and stop that paragraph; Reedah does not retry by reading misleading layout text or narrate a partial paragraph.

## Development and tests

Run these from the repository root:

```sh
make test              # PA3 plus Reedah unit and decoder checks
make reedah-test       # Only Reedah; Node.js and Python 3 required
make browser-test      # Isolated headless Chrome; Node.js 22+ and Chrome required
make integration-test  # Live bridge and Qwen checks; PA3 must be running and idle
```

The three Reedah targets are also available inside this directory as `make test`, `make browser-test`, and `make integration-test`. Browser tests use a temporary Chrome profile, and integration tests do not play sound.

Math unit tests cover nested powers/roots/fractions, renderer wrappers and annotations, accents versus overscripts, limits, fences, labeled/empty table cells, malformed input, and size/depth limits in `tests/math-narration.test.js`. A square root used as an exponent must never become “squared” just because its flattened text is `2`. Fraction-rule and accent cases follow [MathML Core](https://www.w3.org/TR/mathml-core/). Comparison pronunciation and UTF-16 offsets also have tests in `tests/native-request-builder.test.js`.

Browser regressions cover the reported LeetCode paragraph, native MathML, KaTeX modes, MathJax 2/3/4 HTML/SVG/speech labels, Wikimedia wrappers, standalone controls, duplicate representations, hidden content, adjacent formulas, Unicode/quoted sentence boundaries, ordered-list prefixes, and original-text forwarding to PA3. They check exact sentence jobs, actual Play requests through a stubbed extension port, intact formula markup, repeated light/dark highlight cleanup, renderer updates, and that invalid formulas open no native session. Empty or ambiguous representations and unsupported table spans must stop the paragraph rather than lose content.

The paragraph-style browser matrix adds 26 layout/content cases, including negative controls. It checks exact extracted text, Play requests, paragraph order, stable layout/highlighting, repeated scans, toggle cleanup, dynamic insertion/removal, disclosures, class-based visibility, and leaf blocks that acquire nested paragraphs. Unit tests cover text eligibility, linked prose, run boundaries, and mutation filtering. The original Blogger fixture remains a separate regression.

These are deterministic speech-text and browser fixtures, not a complete MathML conformance suite or tests of every live renderer release. They verify what is sent to Qwen; they cannot guarantee the model's spoken pronunciation. The opt-in integration target checks real audio generation and streaming separately.

Confluence regressions use a synthetic editor fixture with the observed page structure. They verify reading order and request text, exclusion of editor controls and cursors, unchanged DOM nodes and caret during highlighting, phrase progress, light/dark themes, document updates/removal, stale prefetch cancellation, and cleanup. Unit tests cover site scoping, Unicode cursor-marker removal with original DOM offsets, and phrase boundaries.

See the [bridge documentation](native/README.md) for streaming behavior and the [PA3 narration API](../README.md#local-narration) for HTTP endpoints and limits. PA3 targets macOS 14 and later; automated tests do not replace testing on an actual older Mac or a physical sleep/wake cycle.

Sentence-seek regressions cover buffered and pending targets, rapid clicks, pause/resume, cancellation, transport-window release, retained-passage rewind, stale completion timers, and missing alignment. Browser tests exercise the actual controls and compare rendered seek audio sample by sample at 0.5×, 1×, 1.5×, and 2× speed.

The [paragraph coverage matrix](tests/PARAGRAPH_MATRIX.md) documents 2,850 generated cases through five nesting levels, iframe coverage, test oracles, and remaining limits.
