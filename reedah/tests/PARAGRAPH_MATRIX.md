# Paragraph detection coverage

Run `make browser-test` from the repository root. All fixtures run in an isolated Chrome profile. `make reedah-test` includes the structural-list unit regressions and frame-routing tests.

## Bounded nesting matrix

The generator in `nesting-matrix-browser.mjs` currently produces **2,850 cases**.

| Dimension | Cases and oracle |
| --- | --- |
| Structural paths | Every sequence of list item, table cell, generic div, and custom paragraph container at depths 1–5: 1,364 paths |
| Pure nesting | Two independent semantic paragraphs at the end of every path: 1,364 cases |
| Mixed nesting | The same paths, with distinct introduction and conclusion text at every level: another 1,364 cases |
| Real-world / parser regressions | Amazon accordion, mixed list/table, block spans, and table/list markup inside a paragraph: 5 cases |
| Leaf representation | Nine container families × eight leaves: 72 cases. Containers add quotations, captions, definitions, display:contents, and open disclosures. Leaves include semantic paragraphs, divs, block spans, custom paragraphs, bare text, contents/inline paragraphs, and sentence links |
| Exclusions | Nine container families × hidden, inert, aria-hidden, display:none, and opacity:0: 45 cases |

Every row compares extracted text with independently constructed expected paragraphs in DOM order. This detects dropped text, merged paragraph boundaries, duplicated narration, and incorrect ordering. It also checks controls exist, rescanning is stable, and disabling restores the original DOM.

Separate assertions hover an Amazon-style paragraph below a long accordion heading and verify its own visible control. A numbered-list check ensures only the first paragraph gets the spoken list number, with the correct highlight offset.

## Existing complementary coverage

The 26-case paragraph-style fixture checks Play requests, sentence highlighting, layout stability, navigation order, cleanup, dynamic insertion/removal, visibility changes, disclosure expansion, and generic blocks that acquire semantic children. Other fixtures cover Blogger, MDX, Confluence editors, quotations, math renderers, sentence seeking, streaming audio and highlight themes.

Quotations, figure captions and definitions retain their existing aggregate ownership: their nested prose is read once as a unit. Ordinary list items retain their numbering and nested-item behavior. List items containing separate prose blocks yield to those paragraphs. Text following a nested list remains after its children in reading order.

## Frames

The manifest injects one shared script bundle into all matching frames, including eligible inherited-origin frames. Browser fixtures exercise top-level, same-origin, cross-origin, srcdoc and nested documents, checking exact text, Play payloads and disable cleanup. These tests run the real content scripts with a stubbed Chrome messaging API; they do not claim to test Chrome's extension installation/permission machinery.

Unit tests separately verify top-document state authority, late-frame synchronization after a service-worker restart, cross-frame playback-stop routing, and the declarative injection configuration. Enabling/disabling applies to the tab; starting narration in one frame stops narration in others. Next/Previous stay within the current document. Known Office authentication and shell frames remain excluded.

## Limits and maintenance

This exhaustively covers the stated finite grammar, not every possible HTML/CSS/JavaScript page. Browsers repair invalid HTML, so the parsed DOM—not an imagined source nesting—is authoritative. Five-level nesting is a test bound, not an implementation limit.

Shadow DOM, canvas/image-only text, built-in PDF viewers, restricted browser pages, and frames denied extension access are outside this coverage. Bare generic text outside recognized prose roots remains intentionally conservative to avoid reading page navigation. Visual order that differs from DOM order is not reconstructed. Very large, rapidly changing documents still need performance testing.

For each new report, retain the smallest sanitized DOM/CSS reproduction, add its missing dimension to the generator when it generalizes, and assert both positive coverage and nearby negative controls. Keep exact paragraph ownership and reading order assertions; checking only that some control appears would have missed the Amazon failure.
