# Paragraph boundary exception audit — 2026-10-07

The reported email contains nine ordinary P elements inside one BLOCKQUOTE. Blockquote ownership no longer merges them. The regression uses synthetic text in the same structure and checks nine separate Play requests, highlighting, layout and cleanup. The recursive matrix now includes blockquotes at every position through five levels (7,932 generated cases).

This audit reviews other exceptions without changing their behavior. Passing the regression suite does **not** establish that these exceptions are desirable.

## Remaining grouping decisions

| Rule | Observed behavior / risk | Suggested disposition |
| --- | --- | --- |
| Figure captions (FIGCAPTION) | Two nested P elements produce one narration target. A quotation inside the caption also remains merged because the caption owns it. | Review next. Distinct semantic paragraphs should probably remain separate; a simple inline caption can stay whole. |
| Definition bodies (DD) | Two nested P elements produce one target. | Same review as captions. Preserve term/definition order, but avoid flattening multi-paragraph definitions. |
| P with block-styled spans | Two block spans are read as one paragraph. | Decide whether CSS block layout is enough evidence to split a semantically single P. Explicit paragraph children are stronger evidence than styling. |
| Custom paragraph wrapper with generic DIV children | Two DIV blocks inside role=paragraph produce one target. The wrapper yields only when descendants match the semantic candidate selector. | Review consistency with generic-block detection. A role should not automatically erase established paragraph boundaries. |
| Headings with block spans | A multi-line heading remains one target. | Probably preserve: typographic title lines do not necessarily create separate paragraphs. |
| Visible blank lines represented by text newlines | A white-space:pre-wrap DIV with two newline-separated sections produces one target. | Consider CSS-aware blank-line handling. Ordinary source-code newlines must remain insignificant. |
| BR pairs nested in an inline span with surrounding prose | Introduction followed by SPAN containing Alpha, two BRs, and Beta, followed by Conclusion, remains one target. | Review a range-based split into “Introduction Alpha” and “Beta Conclusion” that preserves inline elements. Current preparation descends only through a single owning SPAN, protecting against dropped surrounding text. |
| Very short bare text runs | Unpunctuated generic “Yes” is omitted, while P containing “Yes” is retained. This threshold also applies to prepared bare runs around structural content. | Review separately from ownership. Lowering it can expose tiny labels and UI text. |

Adjacent DOM blocks sometimes produce “Alpha paragraph.Beta paragraph.” without a separator when grouped. Remaining ownership rules affect both paragraph navigation and extracted spacing.

The old quotation regression's expected merged text has been replaced. Existing expectations for nested blank-line text and aggregate captions/definitions remain review items; they are not evidence that those policies are correct.

## Exclusions with user-visible tradeoffs

| Rule | Observed behavior / purpose | Risk of removing it |
| --- | --- | --- |
| Forms, inputs and ordinary contenteditable | Prose inside a form or ordinary editor is excluded. Supported Confluence and Office contexts have explicit exceptions. | Reading or modifying composition fields, placeholders, collaborator UI and controls. Editor changes need non-mutating range handling. |
| Navigation, toolbars, menus, aside, footer | Candidate elements in these areas are excluded. The audit confirms prose in ASIDE is omitted. | Reading repetitive UI text. Some sites also put useful prose in these containers. |
| Site headers | HEADER inside MAIN is still excluded unless inside a recognized article container. | Removing the rule exposes site chrome, but the current rule can omit legitimate introductions. |
| Disclosure summaries | Bare SUMMARY text is not a generic prose candidate, even when open. | Summary often acts as an interactive label. Visible disclosure titles may nevertheless be useful. |
| Link-only content | Short links and long links without sentence-ending punctuation are omitted. The exception requires a recognized prose root, at least 40 characters and terminal punctuation. | Removing this wholesale makes menus look like paragraphs. It can currently omit genuine linked prose. |
| Short headings | A two-character heading such as “AI” is omitted; headings require three characters. | Relaxing it admits short labels, but the current rule excludes meaningful titles. |
| Hidden, inert, accessibility-hidden and collapsed content | Excluded to avoid invisible text and duplicate representations. | Reading hidden duplicates and inaccessible UI. |
| Math renderers | A formula is atomic; duplicate visual/accessibility representations and metadata are excluded. Legacy MathJax has a scoped visibility exception. | Double narration and broken formula/highlight alignment. Preserve renderer-aware ownership. |
| Nested list items | The parent excludes child LI text; each child owns its narration and numbering. Structural list items yield to their paragraphs. | Duplicate child narration or incorrect list numbers. The ordinary nested-list audit still gives two ordered targets. |

Exclusion and extraction use different selectors. A bare quotation owning a nested NAV or PRE can include that descendant's text even though those descendants are not standalone candidates. This inconsistency deserves a separate fix with negative-content tests; simply deleting ownership rules is insufficient.

## Scope boundaries

- Bare DIV text is scanned only inside recognized prose roots or supported semantic/custom containers.
- Shadow roots, canvas/image text, CSS-generated text and restricted browser/PDF content remain outside the extractor.
- Virtualized documents expose only mounted text; reading order follows DOM order, not CSS visual reordering.
- Editable content uses special policies. Preparation avoids wrapping editor DOM; changing quoted bare runs in editors needs a separate non-mutating design. The static email fix does not remove those protections.
- Frames share a page toolbar; paragraph navigation stays within the narrating document. Known Office authentication/shell frames remain excluded.

## Reproduce and review

Run:

    REEDAH_PARAGRAPH_AUDIT=1 make browser-test

The paragraph-exceptions-audit.mjs script prints actual paragraphs alongside proposed boundary counts. It is informational: differences are **not** accepted regression expectations and do not fail the test command. A two-line heading's proposed count is a comparison to discuss, not an approved requirement to split it.

Agree on the boundary policy for each remaining group, then encode exact per-paragraph assertions. Distinct semantic P elements should be the strongest signal. “Every word is read once” alone is insufficient: a merged target satisfies it while still breaking paragraph navigation.
