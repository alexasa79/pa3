const assert = require("node:assert/strict");
const test = require("node:test");
const { buildSentenceRanges } = require("../sentence");

function extractSentences(text, options) {
  return buildSentenceRanges(text, options).map((range) => text.slice(range.start, range.end));
}

test("buildSentenceRanges keeps abbreviations and decimals intact", () => {
  const text = "Use e.g. 3.14 in a sentence that is long enough to stay intact. " +
    "Another sentence that is also long enough to be separate.";
  const sentences = extractSentences(text);

  assert.equal(sentences.length, 2);
  assert.ok(sentences[0].includes("e.g."));
  assert.ok(sentences[0].includes("3.14"));
});

test("buildSentenceRanges does not split on mid-word periods", () => {
  const text = "Vert.x is a reactive toolkit for the JVM. " +
    "It also supports Node.js style APIs and ASP.NET patterns.";
  const sentences = extractSentences(text);

  assert.equal(sentences.length, 2);
  assert.ok(sentences[0].includes("Vert.x"));
  assert.ok(sentences[1].includes("Node.js"));
  assert.ok(sentences[1].includes("ASP.NET"));
});

test("buildSentenceRanges ends a sentence after a decimal number", () => {
  const text = "The ratio was 1.5 for the sample set. " +
    "The following sentence is also long enough to be separate.";
  const sentences = extractSentences(text);

  assert.equal(sentences.length, 2);
  assert.equal(sentences[0], "The ratio was 1.5 for the sample set.");
  assert.equal(sentences[1], "The following sentence is also long enough to be separate.");
});
