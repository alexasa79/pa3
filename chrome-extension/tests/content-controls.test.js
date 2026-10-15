const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

test("content controls avoid local name collisions with skip handlers", () => {
  const contentPath = path.join(__dirname, "..", "content.js");
  const source = fs.readFileSync(contentPath, "utf8");

  assert.match(source, /const skipSentenceButton = document\.createElement\("button"\);/);
  assert.match(source, /const skipParagraphButton = document\.createElement\("button"\);/);

  assert.doesNotMatch(source, /const skipSentence = document\.createElement\("button"\);/);
  assert.doesNotMatch(source, /const skipParagraph = document\.createElement\("button"\);/);
});
