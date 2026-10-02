const assert = require("node:assert/strict");
const test = require("node:test");
const { normalizeNarrationText, maskParentheses, isParenthesizedCodeReference } = require("../narration_text");

function joinChunks(chunks) {
  let text = "";
  for (const chunk of chunks) {
    const normalized = normalizeNarrationText(chunk);
    if (!normalized) continue;
    text += normalized;
  }
  return text;
}

test("normalizeNarrationText replaces CR and LF with spaces", () => {
  assert.equal(normalizeNarrationText("REPL\nworkflow\rtest"), "REPL workflow test");
});

test("joinChunks preserves adjacent chunks without inventing spaces", () => {
  const text = joinChunks(["Aside from compiler, it must support ", "REPL", "workflow as well."]);
  assert.equal(
    text,
    "Aside from compiler, it must support REPLworkflow as well."
  );
});

test("joinChunks preserves punctuation exactly as present in chunks", () => {
  const text = joinChunks(["A set of ", "plugins", ",", " not required."]);
  assert.equal(text, "A set of plugins, not required.");
});

test("only single parenthesized code references are masked", () => {
  assert.equal(isParenthesizedCodeReference("src/file.swift:42"), true);
  assert.equal(isParenthesizedCodeReference("file.c:100-200"), true);
  assert.equal(isParenthesizedCodeReference("file.ts:12:3"), true);
  assert.equal(isParenthesizedCodeReference("src/worker:8"), true);
  assert.equal(isParenthesizedCodeReference("C:\\src\\main.cpp:42"), true);
  assert.equal(isParenthesizedCodeReference("Makefile:9"), true);
  assert.equal(isParenthesizedCodeReference(" src/main.rs:42 "), true);
  assert.equal(isParenthesizedCodeReference("`src/main.rs:42`"), true);
  assert.equal(isParenthesizedCodeReference("источник/файл.py:12"), true);
  assert.equal(isParenthesizedCodeReference("meaningful"), false);
  assert.equal(isParenthesizedCodeReference("an important explanation"), false);
  assert.equal(isParenthesizedCodeReference("ratio:2"), false);
  assert.equal(isParenthesizedCodeReference("12:30"), false);
  assert.equal(isParenthesizedCodeReference("John 3:16"), false);
  assert.equal(isParenthesizedCodeReference("file.swift"), false);
  assert.equal(isParenthesizedCodeReference("file.swift:abc"), false);
  assert.equal(isParenthesizedCodeReference("file.swift:42 extra"), false);
  assert.equal(isParenthesizedCodeReference("file.swift:42,other.swift:5"), false);
  assert.equal(isParenthesizedCodeReference("see file.swift:42"), false);
  assert.equal(isParenthesizedCodeReference("file name.swift:42"), false);
  assert.equal(isParenthesizedCodeReference("https://example.org:443"), false);
  assert.equal(isParenthesizedCodeReference("an aside (nested)"), false);
  assert.equal(isParenthesizedCodeReference("src/file.swift:\n42"), false);
  assert.equal(isParenthesizedCodeReference(""), false);
  const source = "🙂 Keep (useful text) and skip (src/main.swift:42).";
  const masked = maskParentheses(source);
  assert.equal(masked.length, source.length);
  assert.equal(masked, source.replace("(src/main.swift:42)", " ".repeat("(src/main.swift:42)".length)));
  const prose = "Read (an aside (nested). Another sentence!) aloud.";
  assert.equal(maskParentheses(prose), prose);
});
