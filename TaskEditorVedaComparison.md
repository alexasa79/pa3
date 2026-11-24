# PA3 and Veda text editing

Reviewed November 13, 2026 against the current `/Users/sasha/hobbies/veda/main` checkout, HEAD `a256012`. The Veda column is based on its default bindings, implementation, and existing tests. This is a source comparison, not a claim that every Veda command was executed. Veda was not modified.

The scope is editing one task description. PA3 keeps AppKit text storage, Unicode composition, the character grid, and the shared dictation controller. Matching editing behavior does not require replacing its buffer with Veda's rope.

## Existing commands corrected in this pass

| Behavior | Veda rule | PA3 before | PA3 now |
| --- | --- | --- | --- |
| `dd` on the final line | Remove the preceding newline along with the line's contents. | Left an empty numbered final line. | Removes the actual logical line; gutter count follows the resulting text. |
| `dd` on a trailing empty line | Remove its preceding newline. | Selected a zero-length range and did nothing. | Removes that newline. An entirely empty document still has one editable row. |
| Counted `dd` | Whole-line operation. | Could leave a final empty row when deleting through EOF. | Handles EOF, including a selected trailing empty line. PA3 applies the whole-line rule consistently to counted ranges too. |
| `cc` / counted `cc` | Keep one empty first line for replacement; remove additional selected lines. | Deleted the first line's separator and could merge the replacement into the next line. | Keeps one replacement line and enters Insert mode. |
| `yy` on the final text line | Copy a newline-terminated, linewise value without changing the document. | Copied only the characters, so paste became characterwise. | Copies a linewise value; cursor and document stay unchanged. |
| `p` / `P` | Newline-terminated clipboard text pastes below/above the logical line; other text pastes after/before the character. | Always inserted at a character position. | Distinguishes the two kinds, supports counts, and handles empty lines and EOF. |
| Paste cursor | Characterwise paste ends on the last pasted character. Veda's interior linewise paste retains the original logical line; EOF append ends on the final empty row. | Always left the caret after the inserted span. | Follows those modal paste rules. Native Command-V and dictation still end after inserted text. |
| `J` | Remove the next line's indentation; add a separator only if needed. | Replaced only the newline, leaving indentation and duplicate spaces. | Removes leading spaces/tabs and unnecessary separators; counted joins undo together. |
| `w` / `W` | Advance over one punctuation character at a time. `W` treats underscore as a boundary. Stop on the final character of a word ending a nonempty line before crossing to the next content line. | Grouped punctuation runs, treated `W` as `w`, and skipped that final-character stop. | Uses those navigation rules, stepping by composed Unicode characters. |
| `b` / `B` | Search backward for the preceding word, skipping punctuation; `B` splits underscores. | Could stop at punctuation and treated `B` as `b`. | Applies Veda's boundary distinction. |
| `dw` / `cw` / `yw` | Operate on the whole current word, even from its middle. Deletion/yank can include following horizontal whitespace; change leaves that separator. | Could consume a newline after the word or act on an entire punctuation run. | Preserves line breaks for a single word operation, treats punctuation individually, and supports counted words. |
| `dW` / `cW` / `yW` | Start at the cursor and stop at word end, without trailing whitespace. | Uppercase deletion/yank included trailing whitespace. | Uses the partial-word range. Operator `W` still treats underscore as part of the word, unlike navigation `W`. |
| Operator counts | Prefix and infix counts multiply, such as `2d3w`. | Concatenated the digits or retained an ambiguous count. | Multiplies the two counts. |
| `h` / `l`, plain Normal Left/Right | Stay within the current logical line; Right stops on its last character. | Could cross the newline using native insertion-caret movement. | Stays in that logical line. Shift-selection and Insert arrows retain native behavior. |
| `0` / `$` / `A` | Refer to the logical line, including across visual wrapping. `$` selects its last character; `A` selects the insertion point after it. | Used native visual-row movement and insertion positions. | Uses logical boundaries. PA3's additional `I` also uses logical line start. |
| `a` on an empty line | Enter Insert on that line. | Could move across its newline first. | Stays on the empty line. |
| `G` | Select the last character of the last text line, skipping the implicit empty row after a terminal newline. | Selected the insertion position at absolute EOF. | Follows Veda's Normal-mode target. |
| Escape from Insert | Move back one character and enter Normal. | Kept the insertion position. | Moves back one composed character, without crossing line start; remains in the description pane. |
| `o` / `O` / Insert Return | Carry indentation into a new plain-text line; `O` uses the preceding line's context. | Inserted an unindented newline. | Carries plain leading spaces/tabs. Language-aware and deeper empty-line context remain a gap below. |
| `u` / `U` | Counted undo/redo is repeated by Veda's command dispatcher. | Ignored counts. | Supports counted undo/redo. |
| Unimplemented Option chords | A modified command is distinct from its plain key. | Could interpret an unsupported Option-U as undo. | Unbound Option chords are ignored in Normal mode; supported Option navigation remains native. |

`dd` now matches Veda's cursor placement: deleting an interior line stays on the same line number (the following surviving line, column 0), and deleting the final line moves up to the new last line (column 0). Pressing `Escape` in Normal mode while a pending operator or count (`d`, `c`, `y`, `g`, `3`, `d3`) is active cancels it instead of leaving the description pane. `dw` / `dW` / `d$` and whitespace-only `J` also clamp the Normal cursor to the last surviving character of the line.

PA3 now groups a change command and its typed replacement into one undo step. This is an atomic-edit improvement, not an assertion of identical Veda history: Veda's single-cursor change paths can record the initial deletion before starting the Insert session. Veda also groups some counted edits as separate repeated history entries; PA3 groups counted paste, deletion, and joins into one action.

## Remaining differences and missing features

| Area | Veda | PA3 today | Suggested priority |
| --- | --- | --- | --- |
| Repeat last change | `.` repeats the operation, inserted text, and count. | Missing. Undo/redo is not a substitute. | High |
| Registers and clipboard | Named registers and the delete register, including `'dp`; deletes need not overwrite the system clipboard. | No register prefix parser. Operator deletes/changes still share the clipboard with yanks; `x` and `D` do not populate a consistent delete register. | High |
| Visual selection | `v` / `V`, selection operators, visual indentation and case conversion. | Native Shift-selection and Command-C/X/V; `x` and paste handle explicit selections. No Veda visual modes. | High |
| Text objects and operator motions | `iw` / `aw`, bracket objects, arguments, blocks, functions, whole-buffer objects; character and line motions after an operator. | Only doubled line operators, `w`, `W`, and `$` are parsed. For example, `diw`, `dA`, and `d` + Down are not implemented. | High |
| Character search | `f` / `t` and their operator forms. | Missing. | Medium |
| Modal search | Forward `/`, backward `?`, `n` / `N`, and `*` for current word. | `/` and Command-F open the native Find bar. No modal search state or `n` / `N` / `*`. `?` is deliberately reserved for shortcut help. | Medium |
| Indentation | Configurable tabs/spaces, `>>` / `<<`, `==`, brace/parenthesis/Python rules, and nearest significant-line context for blank lines. | Basic leading whitespace is carried by `o` / `O` / Return. Tab and other Insert deletion shortcuts otherwise use AppKit. No coding-language engine or shift/reindent operators. | Medium |
| Line reordering | Ctrl/Option-Up/Down moves lines. | Those keys navigate paragraphs. Changing that would replace established native shortcuts. | Medium; shortcut decision needed |
| Case conversion | Option-U / Option-L in Normal and Visual modes. | Missing; unsupported Option chords no longer fall through to undo/movement. | Medium |
| Paragraph rewrap | Option-Q reflows a paragraph. | Only visual wrapping; stored text is not reflowed. | Medium |
| Temporary Normal mode | Ctrl-O performs a Normal command and returns to Insert. | Missing. | Low |
| Multiple cursors | Cursor mode, virtual cursors, synchronized edits/alignment. | One native selection. | Low |
| Pending-command feedback | Key hints and command state feedback. | A pending `d` / `c` / `y` has no visible hint. Unsupported sequences are cancelled. | Low |
| Vertical cursor details | Veda owns desired-column tracking and Normal-mode end-of-line clamping. | AppKit owns visual-row movement, preferred column, bidi movement, paging, and selection. These edge cases are not claimed identical. | Further focused comparison |
| Undo cursor restoration | Veda's command history restores buffer positions. | AppKit's undo manager restores text and native selection state. Exact selection/cursor history is not claimed identical. | Further focused comparison |
| Counts on Insert entry | Veda dispatches counts by repeating commands, including commands that enter Insert mode. | `o` / `O` / `i` / `a` / `A` do not replay an Insert-entry command multiple times. | Low; define desired interaction first |

## Deliberate PA3 choices retained

| Behavior | PA3 choice |
| --- | --- |
| Dictation | Space in Normal and Control-Space in Insert start the shared PA3 dictation session. Finishing dictation leaves the insertion point after its inserted passage. Veda has no equivalent mode. |
| Append dictation after the `G` correction | Use `G`, then `A`, then Control-Space. The former `G`, `$`, Space recipe would now insert before the last character, so the help and README were updated. |
| Pane navigation and closing | Escape in Normal returns to tasks; `q` closes Tasks outside Insert. Command-Q/W close this window and keep PA3 running. |
| Saving | Insert and Dictation keep a draft; returning to Normal commits it. Normal edits autosave. No file-command mode. |
| Whitespace | Preserve exact prose and hashtag text. Unlike Veda's Insert exit, PA3 does not automatically trim trailing spaces from changed lines. |
| Native navigation | Home/End, Command/Control/Option navigation, Shift-selection, Find, and Command clipboard shortcuts retain their documented native behavior. On wrapped lines or at line ends, these can differ from Veda's Normal-mode keys; `0` / `$` / `A` use the Veda logical-line rules. |
| Additional shortcuts | `I` remains available. Control-R remains a redo alias; Veda binds Control-R to file reload. |
| Unicode and separators | Preserve AppKit input composition and composed graphemes. Whole-line deletion handles CRLF and Unicode separators as complete boundaries. New inserted line breaks use LF. Veda's rope and several editing paths operate on UTF-8 bytes/runes and LF. |

## Evidence and verification

The PA3 command matrix is in `Sources/PA3/Tasks/TaskEditorParityTests.swift`. It sends key events to the real `TaskModalTextView` and checks resulting text, line counts, visible gutter numbers, cursor positions, and undo/redo. It includes the reported five-line deletion, final empty lines, counted operations through EOF, CRLF, Unicode, wrapped logical lines, indentation, and clipboard paste. Native navigation and grid rendering also run in the focused suite.

Run focused editing checks with:

```sh
swift build
.build/debug/pa3 --task-manager-test --editing-only
```

Run Task Manager integration checks with `make task-manager-test`. Final verification in this pass: both the focused editing suite and the complete Task Manager suite pass, with no checks skipped. Earlier key-window-dependent cursor failures were also reproduced in the previous unchanged app build; those checks depend on desktop window activation.

Veda references, under `internal/editor/` unless specified:

- `operator.go:64`: final-line deletion; `operator.go:210`: line changes; `operator.go:374`: yanks.
- `delete_last_empty_line_test.go`: trailing-empty-line regressions; `delete_test.go`: ordinary line/word deletion.
- `textobject.go:199`: counted line objects; `word_utils.go:193`: current-word ranges.
- `movement.go:150`: forward-word end-of-line stop; `movement.go:206`: underscore-sensitive `W`; `movement.go:369`: `G`.
- `paste.go:214`: paste after a line; `paste.go:284`: paste before; `paste.go:351`: paste cursor positioning.
- `edit_operations.go:18`: `o`; `edit_operations.go:81`: `O`; `edit_operations.go:173`: joins.
- `mode_management.go:586`: leaving Insert, cursor adjustment, whitespace cleanup.
- `editor.go:1801`: command-count dispatch; `keybindings.go`: default bindings and commands absent from PA3.
- `internal/buffer/buffer_meta.go:14`: line count; `internal/buffer/auto_indent.go:31`: indentation analysis.

These are behavior references, not Go source transplanted into Swift. Counted EOF deletion follows the consistent whole-line rule even where Veda's multi-line source branch does not explicitly include the preceding separator. Veda's empty-line yank and byte-oriented Unicode edge cases are not compatibility requirements.
