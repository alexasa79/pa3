const assert = require("node:assert/strict");
const test = require("node:test");
const {
  normalizeNarrationText,
  shouldInsertImplicitSpace,
  shouldInsertImplicitSpaceChars
} = require("../narration_text");

function joinChunks(chunks) {
  let text = "";
  for (const chunk of chunks) {
    const normalized = normalizeNarrationText(chunk);
    if (!normalized) continue;
    if (shouldInsertImplicitSpace(text, normalized)) {
      text += " ";
    }
    text += normalized;
  }
  return text;
}

test("normalizeNarrationText replaces CR and LF with spaces", () => {
  assert.equal(normalizeNarrationText("REPL\nworkflow\rtest"), "REPL workflow test");
});

test("joinChunks inserts implicit spacing between adjacent words", () => {
  const text = joinChunks(["Aside from compiler, it must support ", "REPL", "workflow as well."]);
  assert.equal(
    text,
    "Aside from compiler, it must support REPL workflow as well."
  );
});

test("joinChunks keeps punctuation attached without synthetic spacing", () => {
  const text = joinChunks(["A set of", "plugins", ",", " not required."]);
  assert.equal(text, "A set of plugins, not required.");
});

test("shouldInsertImplicitSpaceChars is false when either side is whitespace", () => {
  assert.equal(shouldInsertImplicitSpaceChars(" ", "p"), false);
  assert.equal(shouldInsertImplicitSpaceChars("p", " "), false);
});
