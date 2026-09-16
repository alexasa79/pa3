const assert = require("node:assert/strict");
const test = require("node:test");
const { normalizeNarrationText } = require("../narration_text");

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
